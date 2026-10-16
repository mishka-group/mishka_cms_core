# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.SetVersionSiteId do
  @moduledoc """
  Sets the site_id attribute on Version resources when multitenancy is bypassed.

  This change extracts the site_id from the `changes` snapshot attribute and
  explicitly sets it on the Version record. Required for resources with
  `global? true` multitenancy where master actions bypass tenant context.

  The change only activates when tenant is nil, preserving normal tenant-based
  site_id assignment for regular operations.
  """

  use Ash.Resource.Change

  @impl true
  def change(%{tenant: nil} = changeset, _opts, _context) do
    changeset |> extract_site_id() |> set_site_id(changeset)
  end

  def change(changeset, _opts, _context), do: changeset

  @impl true
  def atomic(%{tenant: nil} = changeset, _opts, _context) do
    updated = changeset |> extract_site_id() |> set_site_id(changeset)
    {:ok, updated}
  end

  def atomic(changeset, _opts, _context), do: {:ok, changeset}

  defp extract_site_id(%{casted_attributes: %{changes: %{site_id: site_id}}}), do: site_id
  defp extract_site_id(%{attributes: %{changes: %{site_id: site_id}}}), do: site_id
  defp extract_site_id(_changeset), do: nil

  defp set_site_id(nil, changeset), do: changeset

  defp set_site_id(site_id, changeset),
    do: Ash.Changeset.force_change_attribute(changeset, :site_id, site_id)
end
