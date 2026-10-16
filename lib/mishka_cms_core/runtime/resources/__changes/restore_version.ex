# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion do
  @moduledoc """
  Copies a version's snapshot back onto the record it was taken of.

  The `:version_id` argument must name one of THIS record's versions. A version of any other record
  — another site's included — is refused on `:version_id` with the same words a missing one gets, so
  the answer does not say which ids exist elsewhere. Nothing of the refused version reaches the
  changeset.

  Only the fields the resource's primary `:update` accepts are copied, and never `site_id`: a restore
  changes what a record says, not which site it belongs to. Values are cast by each attribute's own
  type, so an atom field stored as a string in the snapshot comes back as the atom.

  ## Options

    * `:version` — the resource's AshPaperTrail version resource. Required. It must have a
      `:get_any` read.

  ## Usage

      update :restore_version do
        argument :version_id, :uuid, allow_nil?: false

        change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
                version: MishkaCmsCore.Runtime.Layout.Version}
      end
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} when is_atom(version) and not is_nil(version) -> {:ok, opts}
      _missing -> {:error, "RestoreVersion needs the :version resource"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    version_id = Ash.Changeset.get_argument(changeset, :version_id)
    record_id = changeset.data.id

    case Ash.get(opts[:version], version_id, action: :get_any, authorize?: false) do
      {:ok, %{version_source_id: ^record_id} = version} -> copy(changeset, version)
      _elsewhere_or_missing -> refuse(changeset)
    end
  end

  defp copy(changeset, version) do
    fields = restorable_fields(changeset.resource)

    version.changes
    |> decode()
    |> Enum.reduce(changeset, fn {key, value}, acc ->
      case Map.fetch(fields, to_string(key)) do
        {:ok, field} -> Ash.Changeset.change_attribute(acc, field, value)
        :error -> acc
      end
    end)
  end

  # What the resource's own update lets a person change, keyed by name so a snapshot's string keys
  # are matched without minting an atom from stored data.
  defp restorable_fields(resource) do
    resource
    |> Ash.Resource.Info.primary_action!(:update)
    |> Map.get(:accept)
    |> List.delete(:site_id)
    |> Map.new(&{to_string(&1), &1})
  end

  @doc "A version's snapshot as a map: `%{}` when it holds none or cannot be read."
  @spec decode(map() | String.t() | nil) :: map()
  def decode(nil), do: %{}
  def decode(changes) when is_map(changes), do: changes

  def decode(changes) when is_binary(changes) do
    case Jason.decode(changes) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _unreadable -> %{}
    end
  end

  defp refuse(changeset) do
    Ash.Changeset.add_error(
      changeset,
      InvalidAttribute.exception(
        field: :version_id,
        message: dgettext_noop("errors", "That version was not found for this record.")
      )
    )
  end
end
