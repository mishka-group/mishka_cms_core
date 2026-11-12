# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SidebarRealtimeTest do
  @moduledoc """
  The admin sidebar follows its settings without a reload. Pages already open, on one site or two,
  redraw their nav when a place is switched off or on in Settings → Sidebar: a site's change
  reaches that site's admins, the global one reaches every site, and an unrelated setting redraws
  nothing.

  Every page is a real LiveView mounted through the router, and the change is saved through the
  settings form the admin uses.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Sidebar.Counts
  alias MishkaCmsCore.Test.Plugins.{ExtensionMenu, NestedMenu}
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @password "Password123!"
  @settings "/admin/dashboard/settings?tab=sidebar"
  @other_page "/admin/dashboard/notifications"
  @media_key "sidebar.runtime.medias.visible"
  @media_link "#admin-sidebar a[href='/admin/dashboard/runtime/medias']"
  @pages_link "#admin-sidebar a[href='/admin/dashboard/runtime/pages']"
  @redrawn [:mishka_cms, :sidebar, :redrawn]

  setup do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    other = create_site!(name: "other", host: "other.test", active: true)
    cache_site(site)
    cache_site(other)

    :persistent_term.put(:mishka_installed, true)
    SettingsState.refresh()
    Settings.load_definitions()
    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      :persistent_term.erase({Settings, :definitions})
      :persistent_term.erase(:mishka_installed)
      SettingsState.restore(snapshot)
    end)

    handler = "sidebar-redrawn-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, @redrawn, &__MODULE__.redrawn/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, site: site, other: other}
  end

  # Runs in the page that redrew its sidebar.
  def redrawn(@redrawn, _measurements, _metadata, test), do: send(test, {:redrawn, self()})

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

  defp create_admin(email, site_id) do
    attrs = %{email: email, password: @password, password_confirmation: @password}

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:register_with_password, attrs, authorize?: false)
      |> then(fn cs -> if site_id, do: Ash.Changeset.set_tenant(cs, site_id), else: cs end)
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!("*").id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp open(host, email, site_id, path) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, host)
      |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(create_admin(email, site_id))

    {:ok, view, _html} = live(conn, path)
    view
  end

  defp save_media(view, shown?) do
    view
    |> form("#settings-form", settings: %{@media_key => to_string(shown?)})
    |> render_submit()
  end

  defp shows?(view, selector), do: has_element?(view, selector)

  # A saved change is one announcement, which each open page draws once, 50ms after it hears it.
  # `has_element?/2` asks the page itself, so after its redraw it reads the redrawn sidebar.
  defp assert_gone(view, selector) do
    redrawn(view)
    refute shows?(view, selector)
  end

  defp assert_back(view, selector) do
    redrawn(view)
    assert shows?(view, selector)
  end

  defp redrawn(%{pid: pid}), do: assert_receive({:redrawn, ^pid})

  describe "a site's admins" do
    test "every open page of the site loses a place switched off, and gets it back when on", %{
      site: site
    } do
      settings = open("localhost", "saver@example.com", site.id, @settings)
      elsewhere = open("localhost", "second@example.com", site.id, @other_page)

      assert shows?(settings, @media_link)
      assert shows?(elsewhere, @media_link)

      save_media(settings, false)

      assert_gone(settings, @media_link)
      assert_gone(elsewhere, @media_link)
      assert shows?(elsewhere, @pages_link)

      save_media(settings, true)

      assert_back(settings, @media_link)
      assert_back(elsewhere, @media_link)
    end

    test "another site's admin keeps the place", %{site: site, other: other} do
      settings = open("localhost", "saver@example.com", site.id, @settings)
      outsider = open("other.test", "outsider@example.com", other.id, @other_page)

      save_media(settings, false)
      assert_gone(settings, @media_link)

      assert shows?(outsider, @media_link)
      refute Settings.get(@media_key, true, other.id) == false
    end

    test "a change made for one site redraws that site only", %{site: site, other: other} do
      here = open("localhost", "here@example.com", site.id, @other_page)
      there = open("other.test", "there@example.com", other.id, @other_page)

      {:ok, _} = Settings.put(@media_key, false, site_id: other.id)

      assert_gone(there, @media_link)
      assert shows?(here, @media_link)
    end
  end

  describe "the global setting" do
    test "reaches the open pages of every site", %{site: site, other: other} do
      master = open("localhost", "boss@example.com", nil, @settings)
      here = open("localhost", "here@example.com", site.id, @other_page)
      there = open("other.test", "there@example.com", other.id, @other_page)

      save_media(master, false)

      assert_gone(master, @media_link)
      assert_gone(here, @media_link)
      assert_gone(there, @media_link)

      save_media(master, true)

      assert_back(here, @media_link)
      assert_back(there, @media_link)
    end
  end

  describe "an extension's switch" do
    @probe_link "#admin-sidebar a[href='#{ExtensionMenu.path()}']"

    setup do
      {:ok, _} =
        Event.write(%{
          name: ExtensionMenu,
          event: "sidebar:menus",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("sidebar:menus", :start, false)
      on_exit(fn -> Event.unregister(:name, ExtensionMenu, false) end)

      # The entry brings sidebar settings of its own, whose defaults the Settings page seeds when it
      # opens, and each seeded one tells every open page to redraw. Seeded here, before any page is
      # open, so the only redraw a page makes is for the change the test saves.
      Settings.load_definitions()
      :ok
    end

    test "draws and drops its entry on the open pages of its site only", %{
      site: site,
      other: other
    } do
      here = open("localhost", "here@example.com", site.id, @other_page)
      second = open("localhost", "second@example.com", site.id, @settings)
      there = open("other.test", "there@example.com", other.id, @other_page)

      assert shows?(here, @probe_link)

      {:ok, _} = Settings.put("mishka_probe.active", false, site_id: site.id)

      assert_gone(here, @probe_link)
      assert_gone(second, @probe_link)
      assert shows?(there, @probe_link)

      {:ok, _} = Settings.put("mishka_probe.active", true, site_id: site.id)

      assert_back(here, @probe_link)
      assert_back(second, @probe_link)
    end

    test "switched off for every site, drops it on all of them", %{site: site, other: other} do
      here = open("localhost", "here@example.com", site.id, @other_page)
      there = open("other.test", "there@example.com", other.id, @other_page)

      {:ok, _} = Settings.put("mishka_probe.active", false)

      assert_gone(here, @probe_link)
      assert_gone(there, @probe_link)
    end
  end

  describe "what is announced" do
    # The write announces from inside `Settings.put/3`; the cache then handles the broadcast of the
    # same row, and a call to it returns once it has.
    test "a write on this node, once, though its broadcast comes back to the cache", %{site: site} do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "sidebar:#{site.id}")
      site_id = site.id

      {:ok, _} = Settings.put(@media_key, false, site_id: site.id)
      assert_received {:sidebar_changed, ^site_id}

      :sys.get_state(SettingsState)
      refute_received {:sidebar_changed, _site_id}
    end

    test "only a sidebar setting is, and once its value is in the cache", %{site: site} do
      :sys.get_state(SettingsState)
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "sidebar:#{site.id}")
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "sidebar:all")

      # The cache applies the write from its own mailbox, and announces it from there: once it has
      # answered a call, it has applied the write and announced whatever it would.
      {:ok, _} = Settings.put("site.title", "Unrelated", site_id: site.id)
      :sys.get_state(SettingsState)
      refute_received {:sidebar_changed, _site_id}

      {:ok, _} = Settings.put(@media_key, false, site_id: site.id)
      site_id = site.id
      assert_receive {:sidebar_changed, ^site_id}
      assert Settings.get(@media_key, true, site.id) == false

      {:ok, _} = Settings.put(@media_key, true)
      assert_receive {:sidebar_changed, nil}
    end
  end

  describe "a count on an entry" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: NestedMenu,
          event: "sidebar:menus",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("sidebar:menus", :start, false)
      on_exit(fn -> Event.unregister(:name, NestedMenu, false) end)
      Settings.load_definitions()
      :ok
    end

    @chip "#admin-sidebar-tree [data-count='nested.inbox']"

    defp shown_count(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(@chip)
      |> LazyHTML.text()
      |> String.trim()
    end

    test "a page that opens after the count was set shows it", %{site: site} do
      Counts.put("nested.inbox", 7)
      on_exit(fn -> Counts.put("nested.inbox", 0) end)

      view = open("localhost", "late@example.com", site.id, @other_page)

      assert shown_count(view) == "7"
    end
  end

  describe "queries of an admin page" do
    # Every query the request and the page it mounts run, counted by the repo's own telemetry.
    defp queries(fun) do
      test = self()
      handler = "sidebar-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:mishka_cms_core, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test or test in (Process.get(:"$callers") || []),
            do: send(test, {:query, handler})
        end,
        nil
      )

      fun.()
      :telemetry.detach(handler)
      count(handler, 0)
    end

    defp count(handler, total) do
      receive do
        {:query, ^handler} -> count(handler, total + 1)
      after
        0 -> total
      end
    end

    defp load(site, email) do
      view = open("localhost", email, site.id, @other_page)
      render(view)
      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :normal)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    end

    test "are as many with nested entries and counts as without", %{site: site} do
      load(site, "warm@example.com")
      plain = queries(fn -> load(site, "plain@example.com") end)

      {:ok, _} =
        Event.write(%{
          name: NestedMenu,
          event: "sidebar:menus",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("sidebar:menus", :start, false)
      on_exit(fn -> Event.unregister(:name, NestedMenu, false) end)
      Settings.load_definitions()

      Counts.put("nested.inbox", 3)
      Counts.put("nested.orders", 9, :attention)
      on_exit(fn -> Enum.each(~w(nested.inbox nested.orders), &Counts.put(&1, 0)) end)

      nested = queries(fn -> load(site, "nested@example.com") end)

      assert plain > 0
      assert nested == plain
    end
  end
end
