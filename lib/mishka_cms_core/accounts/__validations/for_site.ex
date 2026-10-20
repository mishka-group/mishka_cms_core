# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Validations.ForSite do
  @moduledoc """
  Passes for an action run for a site (a tenant), and fails for one run with none — a master's. A
  `where:` condition, so a change written for a site's accounts leaves masters' to another:

      change AshAuthentication.Strategy.OAuth2.IdentityChange,
        where: [MishkaCmsCore.Accounts.Validations.ForSite]
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def validate(%{tenant: tenant}, _opts, _context) when not is_nil(tenant), do: :ok

  def validate(_changeset, _opts, _context),
    do: {:error, message: dgettext_noop("errors", "run with no site")}
end
