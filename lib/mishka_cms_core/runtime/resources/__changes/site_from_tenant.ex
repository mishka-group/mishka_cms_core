# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.SiteFromTenant do
  @moduledoc """
  Writes the tenant the action runs under into the record's `site_id`, replacing whatever was sent.

  A site user's create or update names no site of its own: the site is the one they are signed in
  to. An action with no tenant (a master's) is left as it is, so the `site_id` it was given stays.

      create :create do
        change MishkaCmsCore.Runtime.Resources.Changes.SiteFromTenant
      end
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{tenant: nil}), do: changeset

  def change(changeset, _opts, %{tenant: tenant}),
    do: Ash.Changeset.force_change_attribute(changeset, :site_id, tenant)
end
