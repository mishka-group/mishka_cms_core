# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Checks.ExtensionInteraction do
  @moduledoc """
  This check is true if the access is coming from a relationship load.

  This check allows resources to be accessed through relationship loads from
  other resources, without creating hard dependencies. It simply checks if
  Ash's `accessing_from` context is present, which indicates the access is
  happening through a relationship load.

  ## Usage in policies

  ```elixir
  policies do
    bypass ExtensionInteraction do
      authorize_if always()
    end
  end
  ```

  This pattern allows any resource to load related data through relationships
  while maintaining proper authorization boundaries. The check doesn't
  distinguish between "core" and "extension" resources - it simply allows
  relationship-based access.

  ## How it works

  When Ash loads a relationship (e.g., `Blogger.user`), it automatically sets
  `accessing_from: %{name: :user, source: MishkaBlog.Blogger}` in the query
  context. This check detects that context and grants access.
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_) do
    "Accessing through relationship"
  end

  @impl Ash.Policy.SimpleCheck
  def match?(_actor, context, _opts) do
    # Simply check if this is a relationship load
    # If accessing_from is present, it means Ash is loading through a relationship
    accessing_from = get_accessing_from(context)

    case accessing_from do
      %{source: source_resource}
      when is_atom(source_resource) and source_resource != MishkaCmsCore.Accounts.User ->
        # Relationship load detected - allow access
        true

      _ ->
        # No relationship load - deny access
        false
    end
  end

  # Extract accessing_from information from Ash authorization context
  # Ash stores accessing_from as %{name: relationship_name, source: source_resource}
  defp get_accessing_from(%{query: query}) when not is_nil(query) do
    get_in(query, [Access.key(:context), Access.key(:accessing_from)])
  end

  defp get_accessing_from(%{changeset: changeset}) when not is_nil(changeset) do
    get_in(changeset, [Access.key(:context), Access.key(:accessing_from)])
  end

  defp get_accessing_from(_), do: nil
end
