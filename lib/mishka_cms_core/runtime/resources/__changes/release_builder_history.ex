# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.ReleaseBuilderHistory do
  @moduledoc """
  Detaches a draft's editing history from it as the draft is deleted, so the rows survive and join
  the live record's own timeline.

  Add it to a destroy action on any resource the page builder keeps drafts in:

      destroy :destroy do
        change MishkaCmsCore.Runtime.Resources.Changes.ReleaseBuilderHistory
        ...
      end

  ## Why this is not a foreign key

  It was one. `MishkaCmsCore.Runtime.PageBuilderEvent.draft_id` was a `belongs_to` to
  `MishkaCmsCore.Runtime.PageDraft` with `on_delete: :nilify`, which did exactly this job — for
  pages. But `source_type` names all four editable kinds and three of them keep their drafts in
  tables of their own, so a change made on a layout's or an error page's draft violated that one key
  and the row was refused: the History sheet was simply empty for those two sections, and the flush
  logged a warning nobody reads.

  A single key cannot name three tables, so the column became a plain id and the nilify moved here —
  to the resource, which is the same level the constraint was at, rather than to any one caller.
  That matters because a draft is deleted from several places: the picker's Delete goes through the
  resource's own destroy, publishing spends the draft through
  `MishkaCmsCore.Runtime.PageBuilder.Drafts.discard/3`, and the twenty-draft sweep prunes through
  `prune/3`. Only the resource sees all of them.

  ## Best effort, deliberately

  A draft the author asked to delete must go even if its history could not be released. A row left
  pointing at a draft that no longer exists is invisible rather than wrong — no read names a dead
  branch — so failing the delete to protect the tidiness of the log would be the worse trade.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias MishkaCmsCore.Runtime.PageBuilderEvent

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      release(record.id, context)
      {:ok, record}
    end)
  end

  defp release(draft_id, context) do
    PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(draft_id == ^draft_id)
    |> Ash.bulk_update(:release_draft, %{},
      authorize?: false,
      return_errors?: false,
      actor: context.actor
    )
  end
end
