# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Web.ShareCardRedrawTest do
  @moduledoc """
  An extension's "on this site" modal (`ExtensionInstallerPanel.doctor_modal/1`, through
  `MishkaCmsCore.Test.KitUpgradeHostLive`, whose extension is `:mishka_kit_host`) ends with a Redraw
  button for that extension's own share cards when it answers `runtime:share_card:targets` under
  its app's name, and a click queues a forced planner for that producer on the site the modal is
  about. `async: false` — the plugin registry is process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import MishkaCmsCore.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.ShareCardPlanWorker
  alias MishkaCmsCore.Test.KitUpgradeHostLive
  alias MishkaCmsCore.Test.Plugins.ShareCardProducer
  alias MishkaInstaller.Event.{Event, EventHandler}

  setup do
    dir = Path.join(System.tmp_dir!(), "redraw_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    bundle = Path.join(dir, "kit.json")

    File.write!(
      bundle,
      Jason.encode!(%{
        "$schema" => "mishka.ui_kit.bundle.v3",
        "name" => "redrawkit",
        "version" => "1.0.0",
        "components" => []
      })
    )

    name = "redraw#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))

    on_exit(fn ->
      File.rm_rf(dir)
      SiteState.delete(site.id)
      :persistent_term.erase({ShareCardProducer, :name})
    end)

    %{bundle: bundle, site: site}
  end

  defp produce!(name) do
    :persistent_term.put({ShareCardProducer, :name}, name)
    event = ShareCardProducer.config(:__event__)

    {:ok, _} =
      Event.write(%{
        name: ShareCardProducer,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      Event.unregister(:name, ShareCardProducer, false)
      EventHandler.do_compile(event, :start, false)
    end)
  end

  # The planner is inserted by the button's background task: told when, rather than waited for.
  defp planner_inserts do
    test = self()
    ref = make_ref()
    handler = "share-card-redraw-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:oban, :engine, :insert_job, :stop],
      fn _event, _measure, %{job: %{worker: worker, args: args}}, _config ->
        if worker == inspect(ShareCardPlanWorker), do: send(test, {ref, args})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp host(conn, bundle, site) do
    {:ok, view, _html} =
      live_isolated(conn, KitUpgradeHostLive,
        session: %{"bundle" => bundle, "sites" => [{site.name, site.id}]}
      )

    view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()
    view
  end

  test "an extension that draws share cards gets its own Redraw, for the site chosen", %{
    conn: conn,
    bundle: bundle,
    site: site
  } do
    produce!("mishka_kit_host")
    view = host(conn, bundle, site)

    assert has_element?(view, "#kit-share-cards")
    planned = planner_inserts()
    view |> element("#kit-share-cards-redraw-button") |> render_click()

    assert_receive {^planned, args}
    assert args == %{site_id: site.id, force: true, producer: "mishka_kit_host"}
    assert [_] = all_enqueued(worker: ShareCardPlanWorker, args: %{force: true})
  end

  test "an extension that draws none gets no Redraw", %{conn: conn, bundle: bundle, site: site} do
    produce!("another_extension")
    view = host(conn, bundle, site)

    refute has_element?(view, "#kit-share-cards")
  end
end
