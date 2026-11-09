# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.ExtensionGatePlugTest do
  @moduledoc """
  An extension's API routes as `extension_routes(:api)` mounts them, through the test router's
  `:extension_api` pipeline: they answer for the site the host names with no sign-in, CSRF token or
  session cookie, a route naming `accepts: :any` answers any `Accept`, and a site that switched the
  extension off, like an unknown host, does not reach them.

  `async: false`: `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Plugs.ExtensionGatePlug
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  setup do
    snapshot = SettingsState.snapshot()
    host = "api-ext-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    on_exit(fn ->
      SiteState.delete(site.id)
      SettingsState.restore(snapshot)
    end)

    %{site: site}
  end

  defp fetch(site, path, headers \\ []) do
    headers
    |> Enum.reduce(build_conn(), fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
    |> get(path)
  end

  test "answers for the request's site, with no session cookie", %{site: site} do
    conn = fetch(site, "/_api_ext/ping")

    assert %{"site" => site_id, "format" => "json"} = json_response(conn, 200)
    assert site_id == site.id
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "a route naming accepts: :any answers any Accept, the others only theirs", %{site: site} do
    assert fetch(site, "/_api_ext/ping.txt", [{"accept", "application/rss+xml"}]).status == 200

    assert_error_sent 406, fn ->
      fetch(site, "/_api_ext/ping", [{"accept", "application/rss+xml"}])
    end
  end

  test "is a 404 no cache keeps while the site has switched the extension off", %{site: site} do
    {:ok, _} = Settings.put("mishka_cms_core.active", false, site_id: site.id)

    {404, headers, _body} = assert_error_sent 404, fn -> fetch(site, "/_api_ext/ping") end
    assert {"cache-control", "no-store"} in headers
  end

  test "another site's switch leaves this one's routes open", %{site: site} do
    other = create_site!(active: true)
    {:ok, _} = Settings.put("mishka_cms_core.active", false, site_id: other.id)

    assert fetch(site, "/_api_ext/ping").status == 200
  end

  test "a request with no site is refused before it reaches the gate" do
    conn = build_conn() |> Map.put(:host, "nobody-#{System.unique_integer()}.test")
    conn = get(conn, "/_api_ext/ping")

    assert conn.halted
    assert conn.status >= 400
  end

  test "names the OTP app of an extension from its Routes module" do
    assert ExtensionGatePlug.app(MishkaCmsCore.TestApiExtension) == :mishka_cms_core
    assert ExtensionGatePlug.app(MishkaCmsCoreWeb) == :mishka_cms_core
  end
end
