# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.NestedMenu do
  @moduledoc """
  Test plugin: one `sidebar:menus` entry under Plugins, "Shop", with nine children, three of which
  have two children each. "Secret" asks for a permission of its own, and "Order" is a page that is
  not in the nav and keeps "Orders" marked.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:menus"

  alias MishkaCmsCore.Sidebar

  @root "/admin/dashboard/probe-nested"
  @shop "admin:dashboard:probe_nested"

  @children ~w(overview orders inbox reports stock buyers notes taxes secret)
  @grandchildren %{
    "orders" => ~w(returns drafts),
    "reports" => ~w(daily monthly),
    "stock" => ~w(low out)
  }

  @items Sidebar.items!(
           [
             %{
               key: "nested",
               label: "Shop",
               path: @root,
               group: "plugins",
               order: 50,
               permissions: [@shop]
             }
           ] ++
             (@children
              |> Enum.with_index()
              |> Enum.flat_map(fn {name, index} ->
                [
                  %{
                    key: "nested.#{name}",
                    label: String.capitalize(name),
                    path: "#{@root}/#{name}",
                    parent: "nested",
                    order: (index + 1) * 10,
                    permissions: [(name == "secret" && "admin:dashboard:probe_secret") || @shop]
                  }
                  | Enum.map(Enum.with_index(Map.get(@grandchildren, name, [])), fn {sub, at} ->
                      %{
                        key: "nested.#{name}.#{sub}",
                        label: String.capitalize(sub),
                        path: "#{@root}/#{name}-#{sub}",
                        parent: "nested.#{name}",
                        order: (at + 1) * 10,
                        permissions: [@shop]
                      }
                    end)
                ]
              end)) ++
             [
               %{
                 key: "nested.order",
                 label: "Order",
                 path: "#{@root}/order",
                 nav: false,
                 mark: "nested.orders",
                 permissions: [@shop]
               }
             ]
         )

  @doc "The path of the entry's own page."
  @spec path() :: String.t()
  def path, do: @root

  @doc "The permission every entry of the shop asks for, but Secret."
  @spec permission() :: String.t()
  def permission, do: @shop

  @impl true
  def call(%{items: items} = data), do: {:reply, %{data | items: items ++ @items}}
end
