# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.PurgePreviewAssets do
  @moduledoc """
  Drops what a record's preview keeps under its token after the row is written: the compiled preview
  module and the site its JS bundle is served for. `MishkaCmsCore.Runtime.DraftPreviewAssets` keeps
  no stylesheet: a preview's CSS is compiled on every open.

  A LIVE RECORD HAS A PREVIEW TOKEN TOO, so its `/_preview/:resource/:token` keeps a module like a
  draft's. That module is compiled again once the record's `updated_at` moves, so this is what lets
  the old one go rather than what keeps a stale one away — and on a destroy, it is the only thing
  that ever unloads it.

  ON THE RESOURCE, NOT ON A CALLER, because the callers are many: the visual editor's save, a draft
  publish (`Changes.PublishPageDraft` and its layout / error-page twins), a version restore and the
  inspector's Configuration form all write the same row. Registered on the update and destroy types —
  archiving a document is a soft destroy, and the key of a row nobody can read again is a leak
  nothing else will ever drop.

  AFTER THE TRANSACTION, NOT AFTER THE ACTION. An `after_action` hook runs while the new row is
  still uncommitted, so a preview opened in that window would compile the row as it WAS and keep it
  under the key this purge has already dropped. Purged only when the write succeeded, so a rolled
  back one keeps its module.
  """

  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.DraftPreviewAssets

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    # A DRAFT PUBLISH WRITES THE LIVE ROW FROM INSIDE ITS OWN TRANSACTION, so on that one path the
    # hook below still runs under a surrounding one, and Ash warns about it on every publish.
    # Silenced rather than solved: an inner action cannot see the outer commit, and the window this
    # leaves on that one path is the window `after_action` left on EVERY path.
    |> Ash.Changeset.set_context(%{warn_on_transaction_hooks?: false})
    |> Ash.Changeset.after_transaction(fn
      _changeset, {:ok, record} = result ->
        DraftPreviewAssets.purge(record)
        result

      _changeset, result ->
        result
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
