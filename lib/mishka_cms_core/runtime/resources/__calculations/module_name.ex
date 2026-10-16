# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Calculations.ModuleName do
  @moduledoc """
  A centralized calculation for generating runtime module names across different resources.

  This calculation automatically detects the resource type and generates module names
  based on the resource's structure and site-specific naming conventions.
  """
  use Ash.Resource.Calculation

  alias MishkaCmsCore.Runtime.Compilers.Helpers

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def load(_query, _opts, _context), do: [:site_id]

  @impl true
  def calculate(records, opts, _context) do
    global? = Keyword.get(opts, :global?, true)
    field = Keyword.get(opts, :field, :id)
    site_names = site_names(records, global?)

    Enum.map(records, fn record ->
      resource_type = record.__struct__ |> Module.split() |> List.last()

      record
      |> Map.get(field)
      |> Helpers.module_name(Map.fetch!(site_names, record.site_id), resource_type)
    end)
  end

  # Resolved once per distinct site rather than once per record: a list of 200 pages on one site
  # used to issue 200 `Ash.get/3` calls to learn the same name 200 times.
  defp site_names(records, allow_global) do
    fallback = if allow_global, do: "Global", else: "UnknownSite"

    records
    |> Enum.map(& &1.site_id)
    |> Enum.uniq()
    |> Map.new(&{&1, site_name(&1, fallback)})
  end

  defp site_name(nil, fallback), do: fallback

  defp site_name(site_id, fallback) do
    MishkaCmsCore.Runtime.Site
    |> Ash.get(site_id, action: :get_any, authorize?: false)
    |> case do
      {:ok, site} -> site.name
      _ -> fallback
    end
  end

  @impl true
  def describe(_opts) do
    "Generates the runtime module name for resource compilation"
  end
end
