# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteAvailabilityTest do
  @moduledoc """
  Who may reach a site that is up, offline or inactive.

  An inactive site is a master's alone; an offline one is its own admins' and the masters'; a site
  the site cache does not know is treated as inactive, so a gate asking about it closes. Users are
  built with their permissions loaded, as signing in loads them, so nothing here reads the database
  to decide.

  `async: false` because `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Helper, Permission, User}
  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, ViewerState}
  alias MishkaCmsCore.Settings

  setup do
    SettingsState.refresh()
    %{site: cached_site!(active: true), other: cached_site!(active: true)}
  end

  # A name and host of its own: the factory's sequence starts again in every test process, so its
  # defaults can collide with a site an earlier test left in the cache, and `save/1` refuses those.
  defp cached_site!(attrs) do
    n = System.unique_integer([:positive])
    site = create_site!([name: "availability-#{n}", host: "availability-#{n}.test"] ++ attrs)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp offline!(site_id) do
    {:ok, _} = Settings.put("cms.offline", true, if(site_id, do: [site_id: site_id], else: []))
    on_exit(fn -> SettingsState.delete(site_id, "cms.offline") end)
  end

  defp user(site_id, permissions),
    do: %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(permissions, &%Permission{name: &1})
    }

  defp master, do: user(nil, ["admin:dashboard:*"])
  defp admin_of(site), do: user(site.id, ["admin:dashboard:*"])

  describe "who is who" do
    test "a master admin has no site and may open the dashboard", %{site: site} do
      assert Helper.master_admin?(master())
      assert Helper.master_admin?(user(nil, ["*"]))

      refute Helper.master_admin?(user(nil, ["probe:role"])),
             "a global user without the dashboard"

      refute Helper.master_admin?(admin_of(site)), "a site admin"
      refute Helper.master_admin?(nil)
    end

    test "a site admin is an admin of their own site only", %{site: site, other: other} do
      assert Helper.site_admin?(admin_of(site), site.id)
      assert Helper.site_admin?(user(site.id, ["*"]), site.id)
      refute Helper.site_admin?(admin_of(other), site.id), "another site's admin"

      refute Helper.site_admin?(user(site.id, ["probe:role"]), site.id),
             "a user without the dashboard"

      refute Helper.site_admin?(master(), site.id), "a master is not a site's admin"
      refute Helper.site_admin?(admin_of(site), nil)
    end
  end

  describe "a site that is up" do
    test "is open to everyone, signed in or not", %{site: site, other: other} do
      assert SiteAvailability.state(site.id) == :open

      for who <- [nil, user(site.id, []), admin_of(other), master()] do
        assert SiteAvailability.allowed?(site.id, who)
      end
    end
  end

  describe "an offline site" do
    test "by its own switch lets through its admins and the masters only", %{
      site: site,
      other: other
    } do
      offline!(site.id)

      assert SiteAvailability.state(site.id) == :offline
      assert SiteAvailability.allowed?(site.id, admin_of(site))
      assert SiteAvailability.allowed?(site.id, master())
      refute SiteAvailability.allowed?(site.id, nil), "a visitor"

      refute SiteAvailability.allowed?(site.id, user(site.id, ["probe:role"])),
             "its non-admin user"

      refute SiteAvailability.allowed?(site.id, admin_of(other)), "another site's admin"

      refute SiteAvailability.allowed?(site.id, user(nil, ["probe:role"])),
             "a global non-admin user"

      assert SiteAvailability.state(other.id) == :open, "another site is untouched"
    end

    test "lets through its admin of a single dashboard area, not its API-only admin", %{
      site: site
    } do
      offline!(site.id)

      assert SiteAvailability.allowed?(site.id, user(site.id, ["admin:dashboard:runtime:page"]))
      refute SiteAvailability.allowed?(site.id, user(site.id, ["admin:api:*"])), "API-only"
    end

    test "lets through the admins of the surface asked about", %{site: site} do
      offline!(site.id)
      api_admin = user(site.id, ["admin:api:runtime:page"])
      dashboard_admin = user(site.id, ["admin:dashboard:runtime:page"])

      assert SiteAvailability.allowed?(site.id, api_admin, :api)
      refute SiteAvailability.allowed?(site.id, api_admin, :dashboard)
      refute SiteAvailability.allowed?(site.id, dashboard_admin, :api)
      assert SiteAvailability.allowed?(site.id, dashboard_admin, :dashboard)
      assert SiteAvailability.allowed?(site.id, api_admin, :any)
      assert SiteAvailability.allowed?(site.id, dashboard_admin, :any)
      refute SiteAvailability.allowed?(site.id, user(site.id, ["probe:role"]), :any)
    end

    test "lets through a master admin of the surface asked about", %{site: site} do
      offline!(site.id)
      api_master = user(nil, ["admin:api:*"])

      assert SiteAvailability.allowed_in?(:offline, site.id, api_master, :api)
      refute SiteAvailability.allowed_in?(:offline, site.id, api_master, :dashboard)
      refute SiteAvailability.allowed_in?(:offline, site.id, api_master)
      refute SiteAvailability.allowed_in?(:offline, site.id, master(), :api)
    end

    test "by the global switch holds every site offline", %{site: site, other: other} do
      offline!(nil)

      assert SiteAvailability.state(site.id) == :offline
      assert SiteAvailability.state(other.id) == :offline
      assert SiteAvailability.allowed?(other.id, admin_of(other))
      refute SiteAvailability.allowed?(other.id, admin_of(site))
    end
  end

  describe "an inactive site" do
    test "lets through the masters only, not even its own admins" do
      site = cached_site!(active: false)

      assert SiteAvailability.state(site.id) == :inactive
      assert SiteAvailability.allowed?(site.id, master())
      refute SiteAvailability.allowed?(site.id, admin_of(site)), "its own admin"
      refute SiteAvailability.allowed?(site.id, nil), "a visitor"
    end

    test "lets through a master admin of the surface asked about only" do
      site = cached_site!(active: false)
      api_master = user(nil, ["admin:api:*"])

      assert SiteAvailability.allowed?(site.id, api_master, :api)
      refute SiteAvailability.allowed?(site.id, api_master, :dashboard)
      refute SiteAvailability.allowed?(site.id, api_master)
    end

    test "stays inactive while also switched offline" do
      site = cached_site!(active: false)
      offline!(site.id)

      assert SiteAvailability.state(site.id) == :inactive
      refute SiteAvailability.allowed?(site.id, admin_of(site))
    end
  end

  describe "a site the site cache does not know" do
    test "is closed like an inactive one, as after archiving or deleting it", %{site: site} do
      SiteState.delete(site.id)

      assert SiteAvailability.state(site.id) == :inactive
      assert SiteAvailability.state(Ecto.UUID.generate()) == :inactive
      assert SiteAvailability.state(nil) == :inactive
      refute SiteAvailability.allowed?(site.id, admin_of(site))
      assert SiteAvailability.allowed?(site.id, master())
    end
  end

  # WHO A SIGN-IN EMAIL MAY GO TO — a magic link, a password reset, a confirmation — for the site the
  # request is for. An inactive site sends none at all, not even to its own admin.
  describe "Helper.may_email?/2" do
    test "a site that is up emails anyone, a new address included", %{site: site} do
      assert Helper.may_email?(user(site.id, []), tenant: site.id)
      assert Helper.may_email?("new@example.com", tenant: site.id)
    end

    test "an offline site emails its admins and the masters only", %{site: site} do
      offline!(site.id)

      assert Helper.may_email?(admin_of(site), tenant: site.id)
      refute Helper.may_email?(user(site.id, ["probe:role"]), tenant: site.id)
      refute Helper.may_email?("new@example.com", tenant: site.id)
    end

    test "an offline site emails its admins of either surface", %{site: site} do
      offline!(site.id)

      assert Helper.may_email?(user(site.id, ["admin:api:user"]), tenant: site.id)
      assert Helper.may_email?(user(site.id, ["admin:dashboard:runtime:media"]), tenant: site.id)
    end

    test "an inactive site emails nobody, its own admin included" do
      site = cached_site!(active: false)

      refute Helper.may_email?(admin_of(site), tenant: site.id)
      refute Helper.may_email?(user(site.id, []), tenant: site.id)
      refute Helper.may_email?("new@example.com", tenant: site.id)
    end

    test "without a tenant, as when a master signs in, it may" do
      assert Helper.may_email?(master(), tenant: nil)
    end
  end

  # WHAT A GLOBAL DOCUMENT MAY USE: every site renders it, so only a site that is up can lend it a file.
  # A view that shows another site's record, as a preview does: the host's site is what
  # `on_mount/4` watches, the record's is what `follow/3` adds.
  describe "follow/3" do
    defp socket_on(host),
      do: %Phoenix.LiveView.Socket{private: %{site_availability_site: host.id}}

    defp session_of(nil), do: %{}

    defp session_of(user) do
      :ok = ViewerState.remember(user)
      on_exit(fn -> ViewerState.forget(user.id) end)
      %{"live_socket_id" => "users_sessions:" <> user.id}
    end

    test "refuses by the host's site first, a global record's view included", %{
      site: site,
      other: other
    } do
      offline!(site.id)
      site_id = site.id

      assert {:error, ^site_id, :offline} =
               SiteAvailability.follow(socket_on(site), nil, session_of(nil))

      assert {:error, ^site_id, :offline} =
               SiteAvailability.follow(socket_on(site), other.id, session_of(nil))

      assert {:ok, _socket} =
               SiteAvailability.follow(socket_on(site), nil, session_of(admin_of(site)))
    end

    test "refuses by the record's site, and names that site", %{site: site, other: other} do
      offline!(other.id)
      other_id = other.id

      assert {:error, ^other_id, :offline} =
               SiteAvailability.follow(socket_on(site), other.id, session_of(admin_of(site)))

      assert {:ok, socket} =
               SiteAvailability.follow(socket_on(site), other.id, session_of(admin_of(other)))

      assert socket.private.site_availability_follow == other_id
    end

    test "a global record's view on an open host follows nothing more", %{site: site} do
      assert {:ok, socket} = SiteAvailability.follow(socket_on(site), nil, session_of(nil))
      refute Map.has_key?(socket.private, :site_availability_follow)
    end
  end

  describe "open_site_ids/0" do
    test "is every site that is up, and not one that is inactive or offline", %{
      site: site,
      other: other
    } do
      off = cached_site!(active: false)
      offline!(other.id)

      ids = SiteAvailability.open_site_ids()

      assert site.id in ids
      refute other.id in ids, "an offline site"
      refute off.id in ids, "an inactive site"
    end

    test "is nobody while every site is offline", %{site: site} do
      offline!(nil)

      refute site.id in SiteAvailability.open_site_ids()
    end
  end
end
