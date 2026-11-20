# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TopbarPhoneTest do
  @moduledoc """
  The top bar on a phone, below 640px: 60px tall, the menu button, the heading of the open page
  taken from the sidebar's entry (`MishkaCmsCore.Sidebar.section/1`) and the bell with its badge;
  the search box, the extensions' items and the theme toggle are left out.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Test.Plugins.NestedMenu
  alias MishkaInstaller.Event.{Event, EventHandler}

  @shop NestedMenu.path()
  @phone "max-[640px]"

  describe "the heading of the open page" do
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
      :ok
    end

    test "is the page's entry under the entry above it, or under its group for a top row" do
      assert Sidebar.section(@shop <> "/orders-drafts") == %{eyebrow: "Orders", title: "Drafts"}
      assert Sidebar.section(@shop <> "/inbox") == %{eyebrow: "Shop", title: "Inbox"}
      assert Sidebar.section(@shop) == %{eyebrow: "Plugins", title: "Shop"}
      assert Sidebar.section(@shop <> "/order") == %{eyebrow: "Shop", title: "Orders"}

      assert Sidebar.section("/admin/dashboard/runtime/pages") ==
               %{eyebrow: "Runtime", title: "Pages"}

      assert Sidebar.section("/admin/dashboard") == %{eyebrow: nil, title: "Home"}
      assert Sidebar.section("/admin/elsewhere") == %{eyebrow: nil, title: nil}
      assert Sidebar.section(nil) == %{eyebrow: nil, title: nil}
    end
  end

  describe "the bar" do
    test "draws the menu button, the heading and the bell with its badge, 60px tall" do
      html = topbar(section: %{eyebrow: "Orders", title: "Drafts"}, notification_count: 3)

      assert classes(html, "header") =~ "#{@phone}:h-[60px]!"

      assert text(html, "#admin-phone-section [data-role=eyebrow]") == "Orders"
      assert text(html, "#admin-phone-section [data-role=title]") == "Drafts"
      assert classes(html, "#admin-phone-section") =~ "#{@phone}:block!"
      assert classes(html, "#admin-phone-section") =~ "hidden"

      assert attr(html, "#admin-menu-button", "phx-click") =~ "#admin-sidebar"
      assert classes(html, "#admin-menu-button") =~ "#{@phone}:size-11!"

      assert classes(html, "#topbar-bell") =~ "#{@phone}:size-11!"
      assert text(html, "#topbar-bell [data-bell-count]") == "3"
    end

    test "names the console where the sidebar names nothing" do
      html = topbar(section: nil)

      assert text(html, "#admin-phone-section [data-role=eyebrow]") == "Admin console"
      assert text(html, "#admin-phone-section [data-role=title]") == "MishkaCMS"
    end

    test "leaves out the search box, the extensions' items and the theme toggle" do
      item = %{id: "probe", priority: 1, render: fn _assigns -> "probe" end}
      html = topbar(section: %{eyebrow: nil, title: "Home"}, items: [item])

      assert classes(html, "#admin-topbar-search") =~ "#{@phone}:hidden!"
      assert classes(html, "#admin-topbar-items") =~ "#{@phone}:hidden!"

      for theme <- ~w(dark light) do
        assert classes(html, "button[data-phx-theme=#{theme}]") =~ "#{@phone}:hidden!"
      end

      refute classes(html, "#topbar-bell") =~ "#{@phone}:hidden"
    end
  end

  defp topbar(assigns) do
    user = create_user_with_permissions!(["admin:dashboard:*"])

    (&Layouts.topbar/1)
    |> render_component([current_user: user] ++ assigns)
    |> LazyHTML.from_fragment()
  end

  defp attr(html, selector, name),
    do: html |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> hd()

  defp classes(html, selector), do: attr(html, selector, "class")

  defp text(html, selector),
    do: html |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
end
