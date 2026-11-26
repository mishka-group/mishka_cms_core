# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Accounts.AdminSiteTest do
  @moduledoc """
  The site a master's admin pages show (`MishkaCmsCore.Accounts.AdminSite`): one pick, kept as the
  master's preference, read the same way by every page; a site user is never moved off its site.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Accounts.AdminSite
  alias MishkaCmsCore.Runtime.States.SiteState

  setup do
    SiteState.clear()
    site_a = cached_site!(name: "site-a", host: "a.test")
    site_b = cached_site!(name: "site-b", host: "b.test")
    {:ok, site_a: site_a, site_b: site_b, master: create_user!()}
  end

  defp cached_site!(attrs) do
    site = create_site!(Keyword.put(attrs, :active, true))
    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))
    site
  end

  defp mount(user) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}
    {:cont, %{assigns: assigns}} = AdminSite.on_mount(:default, %{}, %{}, socket)
    assigns
  end

  test "a master who picked nothing sees every site", %{master: master} do
    assert AdminSite.chosen(master) == AdminSite.all()
    assert %{admin_site: "all", current_user: %{site_id: nil}} = mount(master)
  end

  test "a master's pick is kept, and the page is the picked site's alone", %{
    master: master,
    site_b: site_b
  } do
    assert :ok = AdminSite.keep(master, site_b.id)
    assert AdminSite.chosen(master) == site_b.id

    assert %{admin_site: picked, current_user: user} = mount(master)
    assert picked == site_b.id
    assert user.id == master.id
    assert user.site_id == site_b.id
    assert user.site.name == "site-b"

    assert :ok = AdminSite.keep(master, AdminSite.all())
    assert %{admin_site: "all", current_user: %{site_id: nil}} = mount(master)
  end

  test "a pick another open page of the master made reaches them on their topic", %{
    master: master,
    site_a: site_a
  } do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, AdminSite.topic(master.id))

    task = Task.async(fn -> AdminSite.keep(master, site_a.id) end)
    assert :ok = Task.await(task)

    picked = site_a.id
    assert_receive {:admin_site_chosen, ^picked}
  end

  test "a site that is gone or inactive, or any other value, is refused and nothing is kept", %{
    master: master,
    site_a: site_a
  } do
    assert {:error, :refused} = AdminSite.keep(master, Ecto.UUID.generate())
    assert {:error, :refused} = AdminSite.keep(master, "")
    assert AdminSite.chosen(master) == "all"

    assert :ok = AdminSite.keep(master, site_a.id)
    SiteState.save(%{id: site_a.id, name: "site-a", host: "a.test", priority: 0, active: false})

    assert AdminSite.chosen(master) == "all"
    assert %{current_user: %{site_id: nil}} = mount(master)
  end

  test "a site user keeps its own site and may not pick another", %{
    site_a: site_a,
    site_b: site_b
  } do
    admin = create_user!(site_id: site_a.id)

    assert {:error, :refused} = AdminSite.keep(admin, site_b.id)
    assert AdminSite.chosen(admin) == site_a.id
    assert %{admin_site: picked, current_user: %{site_id: own}} = mount(admin)
    assert picked == site_a.id
    assert own == site_a.id
  end
end
