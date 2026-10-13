defmodule MishkaCmsCoreWeb.Test.SettingsShareCardsTest do
  @moduledoc """
  The settings page's SEO tab, Share cards: the Redraw all share cards button, a row for each
  producer that answers `runtime:share_card:targets`, and the Share-card workers setting, which is
  a master's in Global alone. A click queues a forced planner (`ShareCard.redraw_all/2`) for the
  scope in view — every active site in Global, a tenant's own site — and says how many cards it
  queued once the planner ran.
  """
  use MishkaCmsCore.ConnCase

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageShareCardTargets
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.Workers.ShareCardPlanWorker
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.Plugins.ShareCardProducer
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/settings?tab=seo"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    # The settings cache is process-global ETS, not sandboxed, so start each test from a clean one:
    # a sibling test's write outlives its rolled-back transaction and would read back as a real value.
    SettingsState.refresh()
    Settings.load_definitions()

    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      :persistent_term.erase({Settings, :definitions})
      :persistent_term.erase(:mishka_installed)
      SettingsState.restore(snapshot)
    end)

    # `conn.host` feeds the LiveView socket/origin check; the raw `host` header is what SiteLookupPlug
    # reads (Plug forbids `put_req_header("host", …)`, so set it directly like the plug tests do).
    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  defp cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp create_admin(email, site_id, permission \\ "*") do
    attrs = %{email: email, password: @password, password_confirmation: @password}

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:register_with_password, attrs, authorize?: false)
      |> then(fn cs -> if site_id, do: Ash.Changeset.set_tenant(cs, site_id), else: cs end)
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
    |> Ash.create!(authorize?: false)

    user
  end

  # An admin an offline site lets through: the host's pipeline writes the viewer and the socket id on
  # every page load, and the page's own hook reads the one by the other.
  defp let_through(conn, email, site_id) do
    user = email |> create_admin(site_id) |> Ash.load!([:permissions], authorize?: false)
    MishkaCmsCore.Runtime.States.ViewerState.remember(user)
    on_exit(fn -> MishkaCmsCore.Runtime.States.ViewerState.forget(user.id) end)

    conn
    |> log_in(user, is_nil(site_id))
    |> Plug.Conn.put_session(
      :live_socket_id,
      MishkaCmsCore.Accounts.LiveSockets.live_socket_id(user)
    )
  end

  # Who is a master is read from the signed-in user's own token — issued with no site, on the master
  # site's address — so `master_mode` only stands for the choice the sign-in page would have kept, and
  # changes nothing once someone is signed in. A tenant admin's token names their own site.
  defp log_in(conn, user, master_mode \\ true) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, master_mode)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  setup do
    plugins = [PageShareCardTargets, ShareCardProducer]

    for plugin <- plugins do
      {:ok, _} =
        Event.write(%{
          name: plugin,
          event: plugin.config(:__event__),
          extension: :mishka_installer,
          status: :started
        })
    end

    event = PageShareCardTargets.config(:__event__)
    :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      for plugin <- plugins, do: Event.unregister(:name, plugin, false)
      EventHandler.do_compile(event, :start, false)
    end)

    test = self()
    handler = "share-cards-planner-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:oban, :engine, :insert_job, :stop],
      fn _event, _measure, %{job: %{worker: worker, args: args}}, _config ->
        if worker == inspect(ShareCardPlanWorker), do: send(test, {:planner, args})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp planners, do: all_enqueued(worker: ShareCardPlanWorker, args: %{force: true})

  test "a master in Global redraws every active site's cards, and is told how many", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#share-cards-panel")
    assert has_element?(view, "#share-cards-redraw-button")
    assert has_element?(view, "#share-cards-redraw-mishka_cms_core-button")
    assert has_element?(view, "#share-cards-redraw-test_producer-button")
    assert has_element?(view, "#set-share_cards-workers")

    view |> element("#share-cards-redraw-button") |> render_click()

    assert_receive {:planner, %{site_id: site_id, force: true, producer: nil} = args}
    assert site_id == site.id
    assert [_] = planners()

    :ok = perform_job(ShareCardPlanWorker, args)
    render_async(view)

    assert view |> element("#share-cards-redraw-status") |> render() =~ "Queued 4 share cards."
  end

  test "a producer's row redraws that producer's cards alone", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)
    view |> form("#scope-form") |> render_change(%{"scope" => site.id})

    view |> element("#share-cards-redraw-test_producer-button") |> render_click()

    assert_receive {:planner, %{site_id: site_id, force: true, producer: "test_producer"}}
    assert site_id == site.id
    assert [%{args: %{"producer" => "test_producer"}}] = planners()
  end

  test "a site admin redraws their own site's cards, and never sees the share-card workers", %{
    conn: conn,
    site: site
  } do
    conn =
      log_in(
        conn,
        create_admin("settings@example.com", site.id, "admin:dashboard:setting"),
        false
      )

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#share-cards-redraw-button")
    refute has_element?(view, "#set-share_cards-workers")
    refute render(view) =~ "Share-card workers"

    view |> element("#share-cards-redraw-button") |> render_click()

    assert_receive {:planner, %{site_id: site_id, producer: nil}}
    assert site_id == site.id
    assert [_] = planners()
  end

  test "an admin who may not change the site's settings gets no button", %{
    conn: conn,
    site: site
  } do
    user = create_admin("pages@example.com", site.id, "admin:dashboard:runtime:page")
    {:ok, view, _html} = live(log_in(conn, user, false), @path)

    refute has_element?(view, "#share-cards-panel")
    refute has_element?(view, "#share-cards-redraw-button")
  end
end
