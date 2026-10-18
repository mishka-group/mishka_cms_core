# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.TenantFromSite do
  @moduledoc """
  Runs the action under the tenant of the record's `site_id`.

  A master's create names the site it writes for, and the rest of the action (the tenant-scoped
  validations, the version row) reads that site as its tenant. A record with no `site_id`, a global
  one, is left as it is.

      create :master_create do
        change MishkaCmsCore.Runtime.Resources.Changes.TenantFromSite
      end
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :site_id) do
      nil -> changeset
      site_id -> Ash.Changeset.set_tenant(changeset, site_id)
    end
  end
end
