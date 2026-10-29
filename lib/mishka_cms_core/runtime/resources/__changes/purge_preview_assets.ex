# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.PurgePreviewAssets do
  @moduledoc """
  Drops a record's cached preview stylesheet after the row is written.

  A LIVE RECORD HAS A PREVIEW TOKEN TOO, and its temporary stylesheet is compiled once and cached
  under it. `MishkaCmsCore.Runtime.DraftPreviewAssets.ensure_css/2` compiles only when that key is
  ABSENT, so a document written with new utility classes went on being previewed against the CSS of
  the version before it — the new classes had no rules at all, for the life of the node, and the
  reviewer handed the shareable `/_preview/:resource/:token` link read the markup as broken.

  ON THE RESOURCE, NOT ON A CALLER, because the callers are many and each one was a separate chance
  to forget: the builder's `MishkaCmsBuilder.Helpers.save_section/4` purged; a draft publish
  (`Changes.PublishPageDraft` and its layout / error-page twins), a version restore and the
  inspector's Configuration form all wrote the same row and did not. Registered on the update and
  destroy types — archiving a document is a soft destroy, and the key of a row nobody can read again
  is a leak nothing else will ever drop.

  AFTER THE TRANSACTION, NOT AFTER THE ACTION. An `after_action` hook runs while the new row is
  still uncommitted, so a preview opened in that window compiles the row as it WAS and stores it
  under the key this purge has already dropped — the stale stylesheet back for the life of the node,
  which is the whole defect. Purged only when the write succeeded, so a rolled back one keeps its
  cache.

  DROPPED, NOT RECOMPILED, for the reason `MishkaCmsCore.Runtime.Authoring.Drafts` gives: a
  Tailwind pass on every save would pay for a preview nobody may open, and `ensure_css/2` already
  compiles on the way in.
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
