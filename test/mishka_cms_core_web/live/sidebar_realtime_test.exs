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

  require Ash.Query

  @password "Password123!"
  @settings "/admin/dashboard/settings?tab=sidebar"
  @other_page "/admin/dashboard/notifications"
  @media_key "sidebar.runtime.medias.visible"
  @media_link "#admin-sidebar a[href='/admin/dashboard/runtime/medias']"
  @pages_link "#admin-sidebar a[href='/admin/dashboard/runtime/pages']"

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

    {:ok, site: site, other: other}
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

  defp until(view, check, tries \\ 200)
  defp until(_view, _check, 0), do: flunk("the sidebar never reached the expected state")

  defp until(view, check, tries) do
    render(view)

    if check.() do
      :ok
    else
      Process.sleep(10)
      until(view, check, tries - 1)
    end
  end

  defp gone(view, selector), do: until(view, fn -> not shows?(view, selector) end)
  defp back(view, selector), do: until(view, fn -> shows?(view, selector) end)

  describe "a site's admins" do
    test "every open page of the site loses a place switched off, and gets it back when on", %{
      site: site
    } do
      settings = open("localhost", "saver@example.com", site.id, @settings)
      elsewhere = open("localhost", "second@example.com", site.id, @other_page)

      assert shows?(settings, @media_link)
      assert shows?(elsewhere, @media_link)

      save_media(settings, false)

      gone(settings, @media_link)
      gone(elsewhere, @media_link)
      assert shows?(elsewhere, @pages_link)

      save_media(settings, true)

      back(settings, @media_link)
      back(elsewhere, @media_link)
    end

    test "another site's admin keeps the place", %{site: site, other: other} do
      settings = open("localhost", "saver@example.com", site.id, @settings)
      outsider = open("other.test", "outsider@example.com", other.id, @other_page)

      save_media(settings, false)
      gone(settings, @media_link)

      assert shows?(outsider, @media_link)
      refute Settings.get(@media_key, true, other.id) == false
    end

    test "a change made for one site redraws that site only", %{site: site, other: other} do
      here = open("localhost", "here@example.com", site.id, @other_page)
      there = open("other.test", "there@example.com", other.id, @other_page)

      {:ok, _} = Settings.put(@media_key, false, site_id: other.id)

      gone(there, @media_link)
      assert shows?(here, @media_link)
    end
  end

  describe "the global setting" do
    test "reaches the open pages of every site", %{site: site, other: other} do
      master = open("localhost", "boss@example.com", nil, @settings)
      here = open("localhost", "here@example.com", site.id, @other_page)
      there = open("other.test", "there@example.com", other.id, @other_page)

      save_media(master, false)

      gone(master, @media_link)
      gone(here, @media_link)
      gone(there, @media_link)

      save_media(master, true)

      back(here, @media_link)
      back(there, @media_link)
    end
  end

  describe "what is announced" do
    test "only a sidebar setting is, and once its value is in the cache", %{site: site} do
      :sys.get_state(SettingsState)
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "sidebar:#{site.id}")
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "sidebar:all")

      {:ok, _} = Settings.put("site.title", "Unrelated", site_id: site.id)
      refute_receive {:sidebar_changed, _site_id}, 100

      {:ok, _} = Settings.put(@media_key, false, site_id: site.id)
      site_id = site.id
      assert_receive {:sidebar_changed, ^site_id}
      assert Settings.get(@media_key, true, site.id) == false

      {:ok, _} = Settings.put(@media_key, true)
      assert_receive {:sidebar_changed, nil}
    end
  end
end
