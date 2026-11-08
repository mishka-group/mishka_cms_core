# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.PagePath do
  @moduledoc """
  Writes a page's path the way the router serves it: without a trailing `/`. The router answers
  `/about/` as `/about`, so a page stored at `/about/` and one at `/about` were two rows for one
  address, and `unique_path_per_site` and `Validations.PagePathUnique` compare the stored string.
  `/` stays `/`, and the attribute's `trim?` constraint has already dropped the spaces around the
  path.

  It is stored as `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.canonical_path/1` writes it,
  its `%XX` escapes decoded and in Unicode NFC, which is the form the resolver matches a request in:
  a page pasted as `/fa/%D9%88...` is stored, and served, as `/fa/و...`.

  Any other mistake in a path, no leading `/` or a `?` or a `#` in it, is `Validations.PathFormat`'s
  to refuse on the `path` field.

      changes do
        change MishkaCmsCore.Runtime.Resources.Changes.PagePath, on: [:create, :update]
      end
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :path) do
      {:ok, path} when is_binary(path) ->
        served(
          changeset,
          path,
          path |> WebRunTimeMetaDataState.canonical_path() |> String.trim_trailing("/")
        )

      _not_written ->
        changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp served(changeset, path, path), do: changeset
  defp served(changeset, _path, ""), do: changeset

  defp served(changeset, _path, trimmed),
    do: Ash.Changeset.force_change_attribute(changeset, :path, trimmed)
end
