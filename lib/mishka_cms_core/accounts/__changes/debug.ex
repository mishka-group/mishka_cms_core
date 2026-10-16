# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Changes.DebugTokenGeneration do
  @moduledoc """
  Debug change for troubleshooting token generation and tenant issues.

  This change provides detailed logging throughout the token generation process,
  particularly focusing on tenant handling and context management. It logs the
  changeset state before and after token generation, attempts to clear tenant
  information for proper token creation, and tracks the user creation lifecycle.

  The change attempts to resolve tenant-related issues by clearing the tenant from
  multiple locations in the changeset and setting authentication-specific context
  flags. It uses after_action callbacks to log the final state of created users,
  helping identify where tenant information might be incorrectly retained.

  This module should only be used during development and debugging. It exposes
  sensitive information through logs and should be removed or disabled in production
  environments. The extensive logging helps trace authentication flow issues and
  tenant isolation problems in multi-tenant authentication scenarios.
  """

  use Ash.Resource.Change
  require Logger

  @doc """
  Applies debug logging and tenant manipulation to the changeset.

  Logs changeset state at multiple points, attempts to clear tenant information,
  and tracks the user creation process through after_action callbacks.

  ## Parameters
  - `changeset` - The Ash changeset being modified
  - `_opts` - Change options (unused)
  - `_context` - Change context (unused)

  ## Returns
  Modified changeset with debug logging and tenant clearing attempts
  """
  def change(changeset, _opts, _context) do
    Logger.info("=== BEFORE TOKEN GENERATION ===")
    Logger.info("Changeset tenant: #{inspect(changeset.tenant)}")
    Logger.info("Changeset context: #{inspect(changeset.context)}")
    Logger.info("Changeset data: #{inspect(changeset.data)}")
    Logger.info("Changeset attributes: #{inspect(changeset.attributes)}")
    Logger.info("Site_id in attributes: #{inspect(changeset.attributes[:site_id])}")

    # Try multiple ways to clear tenant
    changeset =
      changeset
      |> Map.put(:tenant, nil)
      |> Ash.Changeset.set_context(%{
        private: %{
          ash_authentication?: true,
          tenant: nil,
          no_tenant: true
        },
        tenant: nil
      })

    Logger.info("=== AFTER ATTEMPTING TO CLEAR TENANT ===")
    Logger.info("Modified changeset tenant: #{inspect(changeset.tenant)}")
    Logger.info("Modified changeset context: #{inspect(changeset.context)}")

    # Apply token generation and capture what happens
    changeset =
      Ash.Changeset.after_action(changeset, fn changeset, user ->
        Logger.info("=== AFTER USER CREATION ===")
        Logger.info("Created user: #{inspect(user)}")
        Logger.info("User site_id: #{inspect(user.site_id)}")
        Logger.info("User metadata: #{inspect(user.__metadata__)}")
        Logger.info("Changeset tenant at this point: #{inspect(changeset.tenant)}")

        {:ok, user}
      end)

    changeset
  end
end
