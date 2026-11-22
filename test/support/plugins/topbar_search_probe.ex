# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.TopbarSearchProbe do
  @moduledoc """
  Test plugin on `topbar:search`. For a query it answers a Customers group of one row and a Products
  group of two rows, declared out of their priority order, plus a group behind a permission the
  test admin does not hold, a group whose only row links to another site and a group with no row.
  The query "none" finds nothing. On a page of the "/admin/dashboard/settings" tree it gives the
  placeholder "Search the probe shop…" and leaves the other pages' as they are. Each call emits `[:mishka_cms_core, :test, :topbar_search_probe]`
  with the query it was handed.
  """
  use MishkaInstaller.Event.Hook, event: "topbar:search"

  @called [:mishka_cms_core, :test, :topbar_search_probe]

  @doc "The telemetry event each call emits."
  def called, do: @called

  @impl true
  def call(%{query: "", current_path: "/admin/dashboard/settings" <> _rest} = data),
    do: {:reply, %{data | placeholder: "Search the probe shop…"}}

  def call(%{query: ""} = data), do: {:reply, data}

  def call(%{query: query} = data) do
    :telemetry.execute(@called, %{count: 1}, %{query: query})
    {:reply, %{data | groups: data.groups ++ groups(query)}}
  end

  defp groups("none"), do: []

  defp groups(query) do
    [
      %{
        id: "probe-products",
        label: "Products",
        priority: 10,
        rows: [
          %{
            title: "Aurora UI kit #{query}",
            detail: "180 components",
            icon: "hero-cube",
            link: "/admin/dashboard/settings?tab=general"
          },
          %{title: "Atlas starter theme", link: "/admin/dashboard/runtime/pages"}
        ]
      },
      %{
        id: "probe-customers",
        label: "Customers",
        priority: 20,
        rows: [%{title: "Amelia Brooks", detail: "amelia@example.com", link: "/admin/dashboard"}]
      },
      %{
        id: "probe-gated",
        label: "Secret",
        permission: "admin:api:probe",
        rows: [%{title: "Hidden", link: "/admin/dashboard"}]
      },
      %{id: "probe-away", label: "Away", rows: [%{title: "Evil", link: "//evil.com"}]},
      %{id: "probe-empty", label: "Empty", rows: []}
    ]
  end
end
