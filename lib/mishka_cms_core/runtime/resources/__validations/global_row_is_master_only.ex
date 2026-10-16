# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.GlobalRowIsMasterOnly do
  @moduledoc """
  Stops a tenant changing a row that belongs to no site.

  ## What it is for

  On a `global? true` resource a tenant can READ the global rows — that is what `global?` is for.
  Nothing in Ash stops them WRITING to one, and for a review note that mattered: a note on a shared
  component is visible to every site using it, so a tenant closing one would be answering on
  everybody's behalf about a component they cannot even edit.

  Reading is untouched, and so is creating: a tenant's own note is stamped with their site by the
  tenant create action, so it is never global in the first place. This guards only the actions that
  change a row that already exists.

  ## Usage

      update :resolve do
        validate GlobalRowIsMasterOnly
      end

  It reads the row's CURRENT `site_id` — `Ash.Changeset.get_data/2`, not `get_attribute/2` — because
  the question is what the row is, not what the changeset would like it to become.
  """
  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_data(changeset, :site_id) do
      nil ->
        {:error,
         field: :site_id,
         message:
           dgettext_noop(
             "errors",
             "This note is on something shared by every site. Only a master can change it."
           )}

      _site_id ->
        :ok
    end
  end

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
