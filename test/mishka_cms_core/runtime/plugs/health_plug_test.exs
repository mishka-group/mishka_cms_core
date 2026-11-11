# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.HealthPlugTest do
  @moduledoc """
  The probe a deploy waits on: 503 while the boot, a site's bundles, an extension or the database is
  not ready, 200 once all are, whatever host or scheme asks.
  """
  use MishkaCmsCore.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.Plugs.HealthPlug
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Test.Plugins.HealthHold
  alias MishkaInstaller.Event.{Event, EventHandler}

  @site "health-site"

  setup do
    SiteState.clear()
    :ok = BootHandler.put_status(:initializing)

    on_exit(fn ->
      BootHandler.put_status(:initializing)
      AssetsState.delete_by_site(@site)
      Helpers.record_asset_build(@site, "css", :ok)
    end)

    :ok =
      SiteState.save(%{
        id: Ecto.UUID.generate(),
        name: @site,
        host: "health.example.com",
        priority: 0,
        active: true
      })

    :ok
  end

  defp probe(opts \\ []) do
    method = Keyword.get(opts, :method, :get)
    host = Keyword.get(opts, :host, "localhost")
    scheme = Keyword.get(opts, :scheme, :http)

    method
    |> conn("#{scheme}://#{host}:4000/_health")
    |> HealthPlug.call(HealthPlug.init([]))
  end

  # What the compilers store when a site's bundle is built (`TailwindCompiler.compile_and_store/1`,
  # `JavaScriptCompiler.compile_and_store/1`).
  defp built(type) do
    AssetsState.save_batch([
      %{id: @site, type: type, value: "/* #{type} */", hash: "h", updated_at: DateTime.utc_now()}
    ])
  end

  defp warm do
    :ok = BootHandler.put_status(:ready)
    built("css")
    built("js")
  end

  describe "not ready" do
    test "503 while the boot runs, for any host and scheme" do
      for host <- ["localhost", "mishka.tools", "10.0.1.7"], scheme <- [:http, :https] do
        conn = probe(host: host, scheme: scheme)

        assert conn.halted
        assert conn.status == 503
        assert conn.resp_body == "booting"
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
      end
    end

    test "503 when the boot failed" do
      :ok = BootHandler.put_status({:failed, {:boot_tasks_failed, [:tailwind]}})
      assert %{status: 503, resp_body: "boot failed"} = probe()
    end

    test "503 naming each bundle an active site is still waiting for" do
      :ok = BootHandler.put_status(:ready)

      assert %{status: 503, resp_body: "building assets: health-site css, health-site js"} =
               probe()

      built("css")
      assert %{status: 503, resp_body: "building assets: health-site js"} = probe()
    end

    test "503 naming a bundle whose build failed" do
      :ok = BootHandler.put_status(:ready)
      built("js")
      :ok = Helpers.record_asset_build(@site, "css", {:error, "tailwind exited 1", :nothing})

      assert %{status: 503, resp_body: "building assets: health-site css failed"} = probe()
    end

    test "an inactive site's bundles are not waited for" do
      warm()

      :ok =
        SiteState.save(%{
          id: Ecto.UUID.generate(),
          name: "health-closed",
          host: "closed.example.com",
          priority: 0,
          active: false
        })

      assert %{status: 200} = probe()
    end

    test "503 while an extension holds readiness on runtime:health:ready" do
      warm()

      {:ok, _} =
        Event.write(%{
          name: HealthHold,
          event: "runtime:health:ready",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("runtime:health:ready", :start, false)
      on_exit(fn -> Event.unregister(:name, HealthHold, false) end)

      assert %{status: 503, resp_body: "search index loading"} = probe()
    end

    test "503 when the database does not answer" do
      warm()
      Ecto.Adapters.SQL.Sandbox.mode(MishkaCmsCore.Repo, :manual)

      assert %{status: 503, resp_body: "database unavailable"} = probe()
    end
  end

  describe "ready" do
    test "200 ok once booted, every active site's CSS and JS built and the database answers" do
      warm()

      for host <- ["localhost", "mishka.tools"], scheme <- [:http, :https] do
        conn = probe(host: host, scheme: scheme)

        assert conn.halted
        assert conn.status == 200
        assert conn.resp_body == "ok"
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end
    end

    test "HEAD answers the same status" do
      warm()
      assert %{status: 200} = probe(method: :head)
    end
  end

  describe "other requests" do
    test "pass through untouched" do
      for {method, path} <- [get: "/", get: "/_health/x", get: "/health", post: "/_health"] do
        conn = method |> conn(path) |> HealthPlug.call([])

        refute conn.halted
        assert conn.status == nil
      end
    end
  end
end
