# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.TenantOwnsRecord do
  @moduledoc """
  Refuses a site's change to a row that belongs to no site, or to another one.

  On a `global? true` resource a site can read the global rows and the rows of its own site, and
  nothing in Ash stops it writing to either of the others. The row's CURRENT `site_id` is compared
  with the tenant of the action: a global row is refused with `:global`, a row of another site with
  `:foreign`. An action with no tenant (a master's) passes, and so does a row of the tenant's own
  site.

  ## Options

  - `:global` - Required. The message for a global row.
  - `:foreign` - Required. The message for a row of another site.

  ## Usage

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantOwnsRecord,
                global: dgettext_noop("errors", "Cannot modify global layout."),
                foreign: dgettext_noop("errors", "Cannot modify layout from another site.")}
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    case {Keyword.fetch(opts, :global), Keyword.fetch(opts, :foreign)} do
      {{:ok, global}, {:ok, foreign}} when is_binary(global) and is_binary(foreign) ->
        {:ok, [global: global, foreign: foreign]}

      _missing ->
        {:error, "TenantOwnsRecord needs a :global and a :foreign message"}
    end
  end

  @impl true
  def validate(changeset, opts, %{tenant: tenant}) when not is_nil(tenant) do
    case changeset.data.site_id do
      nil -> {:error, message: Keyword.fetch!(opts, :global)}
      ^tenant -> :ok
      _other -> {:error, message: Keyword.fetch!(opts, :foreign)}
    end
  end

  def validate(_changeset, _opts, _context), do: :ok
end
