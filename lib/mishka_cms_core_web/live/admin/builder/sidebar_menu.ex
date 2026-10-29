# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Builder.SidebarMenu do
  @moduledoc """
  The visual editor's admin pages — a `"sidebar:menus"` plugin (`MishkaCmsCore.Sidebar`).

  The editor is reached from a page, layout, component or error-page row, never from the nav, so
  both of its LiveViews are declared as pages (`nav: false`) rather than links. The canvas is a
  declaration of its own because it is a mount of its own: it answers inside an iframe, and an
  undeclared page is one `MishkaCmsCore.Sidebar.PageGuard` refuses.

  Both open to any name that opens an editor — the page, layout, component and error-page areas and
  `admin:dashboard:code` — and the editor then asks for the type it opens on. The names are read
  from `MishkaCmsCore.Runtime.PageBuilder.Plugins.Settings.opens/0`, the same ones that write the
  editor's own settings, so the two lists cannot drift. Neither page names an `extension:`: that
  would make the editor a switch each site can turn off, and it is not one.

  The core names none of this, so a host without the editor has no builder pages at all.
  """

  use MishkaInstaller.Event.Hook, event: "sidebar:menus", initial: %{priority: 50}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Sidebar.Item

  @opens MishkaCmsCore.Runtime.PageBuilder.Plugins.Settings.opens()

  @items Enum.map(
           [
             %{
               key: "cms_builder",
               label: gettext_noop("Page Builder"),
               icon: "hero-squares-2x2",
               path: "/admin/dashboard/runtime/builder",
               module: MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive,
               nav: false,
               permissions: @opens
             },
             %{
               key: "cms_builder.canvas",
               label: gettext_noop("Page Builder canvas"),
               icon: "hero-squares-2x2",
               path: "/admin/dashboard/runtime/builder-canvas",
               module: MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive,
               nav: false,
               permissions: @opens
             }
           ],
           &Item.new!/1
         )

  @doc "Every admin page the editor owns, each declared as a page and none as a link."
  @spec items() :: [Item.t()]
  def items, do: @items

  @doc "The permissions declared for one of the editor's pages. See `MishkaCmsCore.Sidebar.permissions/2`."
  @spec permissions(String.t()) :: [MishkaCmsCore.Accounts.Checks.AccessPermissions.requirement()]
  def permissions(key), do: Sidebar.permissions(@items, key)

  @impl true
  def call(%{items: items} = data), do: {:reply, %{data | items: items ++ @items}}
end
