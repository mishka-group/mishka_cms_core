# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Builder.SidebarMenuTest do
  @moduledoc """
  The visual editor's `"sidebar:menus"` plugin and its routes: that it declares both of its pages,
  that neither is a link or a per-site switch, that every route it mounts is one of them, and that
  each opens to any name that opens an editor and to no other.

  The test run starts only after every editor plugin is registered (`test/test_helper.exs`), so the
  declarations are already in `MishkaCmsCore.Sidebar.collect/0` here.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCoreWeb.Live.Admin.Builder.{BuilderLive, CanvasLive, Routes, SidebarMenu}

  @opens [
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:layout",
    "admin:dashboard:runtime:component",
    "admin:dashboard:runtime:error_page",
    "admin:dashboard:code"
  ]

  defp opens?(user, module) do
    AccessPermissions.match?(user, %{}, permissions: Sidebar.permissions_for_module(module))
  end

  describe "the plugin" do
    test "appends its pages to the payload without touching what is already there" do
      seeded = Sidebar.core_menu()

      assert {:reply, %{items: items, groups: groups}} = SidebarMenu.call(seeded)
      assert groups == seeded.groups
      assert items == seeded.items ++ SidebarMenu.items()
    end

    test "declares the editor and its canvas as pages, never as links" do
      assert Enum.map(SidebarMenu.items(), & &1.key) == ["cms_builder", "cms_builder.canvas"]
      assert Enum.map(SidebarMenu.items(), & &1.module) == [BuilderLive, CanvasLive]
      refute Enum.any?(SidebarMenu.items(), & &1.nav)
    end

    test "names no extension, so no site can switch the editor off" do
      assert Enum.all?(SidebarMenu.items(), &is_nil(&1.extension))
    end

    test "is registered on the event the sidebar collects" do
      keys = Enum.map(Sidebar.collect().items, & &1.key)

      assert "cms_builder" in keys
      assert "cms_builder.canvas" in keys
    end

    test "an unknown key raises instead of quietly gating nothing" do
      assert_raise ArgumentError, ~r/no sidebar item declares the key/, fn ->
        SidebarMenu.permissions("cms_builder.nope")
      end
    end
  end

  describe "the routes" do
    # URLs are not namespaces: the paths stay what they were when the core routed them, so a stored
    # notification link and a bookmark still open the editor.
    test "are all standalone admin routes, at the editor's paths" do
      assert Routes.routes(:admin) == []
      assert Routes.routes(:public) == []
      assert Routes.routes(:api) == []

      assert Enum.map(Routes.routes(:admin_standalone), &elem(&1, 1)) == [
               "/runtime/builder/:section/:id",
               "/runtime/builder/:section",
               "/runtime/builder-canvas/:token",
               "/runtime/builder-canvas/:token/example/:name/:index",
               "/runtime/builder-canvas/:token/wizard/:wizard"
             ]
    end

    test "every page they mount is declared, so PageGuard lets it open" do
      declared = MapSet.new(SidebarMenu.items(), & &1.module)

      for {:live, path, module, _action} <- Routes.routes(:admin_standalone) do
        assert MapSet.member?(declared, module),
               "#{path} (#{inspect(module)}) has no declaration, so PageGuard would refuse it"
      end
    end
  end

  describe "the area each page asks for" do
    test "the builder and its canvas open to any name that opens a builder, and to no other" do
      for name <- @opens, module <- [BuilderLive, CanvasLive] do
        assert opens?(create_user_with_permissions!([name]), module),
               "#{inspect(module)} refused #{name}"
      end

      for name <- ["admin:dashboard:runtime:stylesheet", "admin:api:runtime:page"],
          module <- [BuilderLive, CanvasLive] do
        refute opens?(create_user_with_permissions!([name]), module),
               "#{inspect(module)} opened to #{name}"
      end
    end

    test "both pages declare the same gate, the names that write the editor's settings" do
      assert SidebarMenu.permissions("cms_builder") == @opens
      assert SidebarMenu.permissions("cms_builder.canvas") == @opens
      assert MishkaCmsCore.Runtime.PageBuilder.Plugins.Settings.opens() == @opens
    end
  end
end
