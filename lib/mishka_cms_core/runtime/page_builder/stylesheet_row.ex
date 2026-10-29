# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.StylesheetRow do
  @moduledoc """
  The stylesheet row the page builder owns for one site, found by its reserved name: the reusable
  classes (`MishkaCmsBuilder.Classes`) and an element's own CSS
  (`MishkaCmsCore.Runtime.PageBuilder.ElementCss`) are each one row of `Stylesheet`.

  ## Scoped, not capped

  The reserved name is the same constant on every site and the identity is `[:name, :site_id]`, so
  the name alone matches one row per site. Asking for one row before saying which site it is for
  hands back whichever rows the read reached, and the site's own row then reads as absent.

  A master's read (`:master_read`) bypasses multitenancy, so every site's row is a candidate and the
  site has to be in the query. A tenant's read is already scoped by Ash; the globals are the scope
  whose `site_id` is `nil` (`site_id == ^nil` is a comparison that can never match), so the filter
  is written once for both.
  """
  alias MishkaCmsCore.Runtime.Stylesheet

  require Ash.Query

  @doc """
  The row called `name` on `site_id` (`nil` for the globals), read as `actor`, or `nil` when there
  is none or it cannot be read.
  """
  @spec fetch(map() | nil, String.t() | nil, String.t()) :: Stylesheet.t() | nil
  def fetch(actor, site_id, name) do
    Stylesheet
    |> Ash.Query.filter(name == ^name)
    |> scoped(site_id)
    |> read(actor, site_id)
  end

  defp scoped(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp scoped(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp read(query, %{site_id: nil} = actor, _site_id) do
    query
    |> Ash.Query.for_read(:master_read, %{}, actor: actor)
    |> Ash.read()
    |> first()
  end

  defp read(query, actor, site_id) do
    query
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: site_id)
    |> Ash.read()
    |> first()
  end

  # The identity leaves a scoped query at most one row to answer with. Pagination is on for the
  # master read, so what comes back is a page rather than a list.
  defp first({:ok, %Ash.Page.Offset{results: rows}}), do: first({:ok, rows})
  defp first({:ok, [row | _rest]}), do: row
  defp first({:ok, []}), do: nil
  defp first({:error, _reason}), do: nil
end
