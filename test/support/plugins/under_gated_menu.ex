defmodule MishkaCmsCore.Test.Plugins.UnderGatedMenu do
  @moduledoc """
  Test plugin: a `sidebar:menus` group and page gated by `{:under, "admin:api"}` — anyone holding
  anything under the API surface.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:menus"

  alias MishkaCmsCore.Sidebar.{Group, Item}

  @page MishkaCmsCore.Test.UnderGatedPage

  @doc "The LiveView module the page entry declares."
  @spec page() :: module()
  def page, do: @page

  @impl true
  def call(%{groups: groups, items: items} = data) do
    group =
      Group.new!(%{
        key: "under-gated",
        label: "Under gated",
        order: 999,
        permissions: [{:under, "admin:api"}]
      })

    item =
      Item.new!(%{
        key: "under-gated.page",
        label: "Under gated page",
        path: "/admin/dashboard/under-gated",
        group: "under-gated",
        module: @page,
        permissions: [{:under, "admin:api"}]
      })

    {:reply, %{data | groups: groups ++ [group], items: items ++ [item]}}
  end
end
