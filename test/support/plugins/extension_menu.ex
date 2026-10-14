defmodule MishkaCmsCore.Test.Plugins.ExtensionMenu do
  @moduledoc """
  Test plugin: a top-level `sidebar:menus` entry owned by the extension `:mishka_probe`, so the site's
  `mishka_probe.active` switch decides whether it is drawn.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:menus"

  alias MishkaCmsCore.Sidebar.Item

  @doc "The href of the entry."
  @spec path() :: String.t()
  def path, do: "/admin/dashboard/probe-shop"

  @impl true
  def call(%{items: items} = data) do
    item =
      Item.new!(%{
        key: "probe.shop",
        label: "Probe shop",
        path: path(),
        extension: :mishka_probe,
        order: 15
      })

    {:reply, %{data | items: items ++ [item]}}
  end
end
