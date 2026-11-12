# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.NestedMenu do
  @moduledoc """
  Test plugin: one `sidebar:menus` entry under Plugins, "Shop", with nine children. They
  ask for the shop's permission, and "Secret" for one of its own.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:menus"

  alias MishkaCmsCore.Sidebar

  @root "/admin/dashboard/probe-nested"
  @shop "admin:dashboard:probe_nested"

  @children ~w(overview orders inbox reports stock buyers notes taxes secret)
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
             Enum.map(Enum.with_index(@children), fn {name, index} ->
               %{
                 key: "nested.#{name}",
                 label: String.capitalize(name),
                 path: "#{@root}/#{name}",
                 parent: "nested",
                 order: (index + 1) * 10,
                 permissions: [(name == "secret" && "admin:dashboard:probe_secret") || @shop]
               }
             end)
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
