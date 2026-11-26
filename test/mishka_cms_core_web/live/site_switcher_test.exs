# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SiteSwitcherTest do
  @moduledoc """
  The master's site switcher in the admin top bar (`MishkaCmsCore.Layouts.SiteSwitcher`): drawn
  for a master on every admin page of a CMS with two sites or more, never for a site user and
  never on a CMS with one site. A pick is kept (`MishkaCmsCore.Accounts.AdminSite`), the page it
  was made on shows that site alone, and another open page of the same master follows it live.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Admin
  import MishkaCmsCore.Test.Factory, only: [create_component!: 1, create_site!: 1]
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.AdminSite

  @components "/admin/dashboard/runtime/components"
  @layouts "/admin/dashboard/runtime/layouts"
  @settings "/admin/dashboard/settings"
  @await 5_000

  setup :serve_localhost!

  defp other_site! do
    site = create_site!(name: "second-site", host: "second.test", active: true)
    cache_site(site)
    site
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  describe "on a CMS with two sites" do
    setup %{site: site} do
      other = other_site!()
      mine = create_component!(site_id: site.id, name: "host-only-component")
      theirs = create_component!(site_id: other.id, name: "second-only-component")
      master = create_admin("picking-master@example.com")
      conn = log_in(build_conn_for_host("localhost"), master)
      %{conn: conn, master: master, other: other, mine: mine, theirs: theirs}
    end

    test "a master has it on a core page, with All sites and a row for each site", ctx do
      view = open(ctx.conn, @components)

      assert has_element?(view, "[data-testid=site-switcher-name]", "All sites")
      assert has_element?(view, "[data-testid=site-switcher-all]", "2 sites, seen as master")
      assert has_element?(view, "[data-testid=site-switcher-site-#{ctx.site.id}]", ctx.site.name)
      assert has_element?(view, "[data-testid=site-switcher-site-#{ctx.other.id}]", "second.test")

      view |> form("#admin-site-switcher-search", %{query: "second"}) |> render_change()
      refute has_element?(view, "[data-testid=site-switcher-site-#{ctx.site.id}]")
      assert has_element?(view, "[data-testid=site-switcher-site-#{ctx.other.id}]")
    end

    test "a master has it on a page that does not follow the pick", ctx do
      view = open(ctx.conn, @settings)
      assert has_element?(view, "[data-testid=site-switcher-button]")
    end

    test "All sites shows every site's rows; a pick shows that site's alone", ctx do
      view = open(ctx.conn, @components)
      assert has_element?(view, "#components-table_components-#{ctx.mine.id}")
      assert has_element?(view, "#components-table_components-#{ctx.theirs.id}")

      view |> element("[data-testid=site-switcher-site-#{ctx.other.id}]") |> render_click()
      assert_redirect(view, @components)
      assert AdminSite.chosen(ctx.master) == ctx.other.id

      view = open(ctx.conn, @components)
      assert has_element?(view, "[data-testid=site-switcher-name]", "second-site")
      assert has_element?(view, "#components-table_components-#{ctx.theirs.id}")
      refute has_element?(view, "#components-table_components-#{ctx.mine.id}")
    end

    test "a pick on one open page moves the master's other open page with it", ctx do
      components = open(ctx.conn, @components)
      layouts = open(ctx.conn, @layouts)

      components |> element("[data-testid=site-switcher-site-#{ctx.other.id}]") |> render_click()

      assert_redirect(layouts, @layouts)
    end

    test "the settings page opens on the picked site", ctx do
      :ok = AdminSite.keep(ctx.master, ctx.other.id)
      view = open(ctx.conn, @settings)
      assert has_element?(view, "[data-testid=site-switcher-name]", "second-site")
      assert has_element?(view, ~s(#scope-form option[selected][value="#{ctx.other.id}"]))
    end

    test "a site user never has it", ctx do
      admin = create_admin("site-admin@example.com", ctx.site.id)
      conn = log_in(build_conn_for_host("localhost"), admin)

      view = open(conn, @components)
      refute has_element?(view, "[data-testid=site-switcher]")
    end
  end

  test "a CMS with one site draws no switcher", %{conn: conn} do
    view = open(conn, @components)
    refute has_element?(view, "[data-testid=site-switcher]")
  end
end
