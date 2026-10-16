# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId do
  @moduledoc """
  Automatically sets language_group_id for master collections.

  This change handles the multilingual collection structure by setting the language_group_id
  to the record's own ID for master collections (collections without a language_group_id).
  This creates a self-referential relationship where master collections point to themselves,
  while translations point to their master collection's ID.

  ## Behavior

  - **Master collections**: When `language_group_id` is nil during creation, the change
    automatically sets it to the record's own ID after insertion using an after_action hook.

  - **Translation collections**: When `language_group_id` is explicitly provided (pointing
    to a master collection), the changeset passes through unchanged.

  ## Implementation Details

  The change uses `after_action` to perform the update because we need the record's ID
  first (generated during insertion). The update:
  - Uses the record's site_id as the tenant context
  - Bypasses authorization (internal system operation)
  - Updates only the language_group_id field

  ## Usage

      create :create do
        change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      end

  ## In the same write

  Pass `before_action?: true` and the group is written WITH the row instead of by a second write
  after it:

      create :create do
        change {MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId, before_action?: true}
      end

      update :update do
        change {MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId, before_action?: true}
      end

  The id is already on a create's changeset by the time a before-action runs, so nothing waits for
  the insert. `MishkaCmsCore.Runtime.Page` needs this: its `:update` validates and signs code,
  versions the page, broadcasts it and queues a compile, so the second write turned one save into
  two versions, two broadcasts and two compile jobs.

  On an update the same rule keeps a group from being emptied — a record whose group is set to nil
  becomes the master of a group of its own rather than a record with no group at all.

  On a restore it gives a group to a record archived before it had one. A
  `prevent_archived_*_updates` trigger refuses every other write to an archived row, so the
  restoring write is the first one that can:

      update :unarchive do
        change set_attribute(:archived_at, nil)
        change {MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId, before_action?: true}
      end

  ## Example Flow

  ### Creating a master collection (English):
  ```elixir
  # User provides: language_group_id = nil
  Ash.create(Collection, %{name: "Tech", language: "en", ...}, tenant: site_id)
  # After insert: language_group_id automatically set to record.id
  # Result: id = "abc123", language_group_id = "abc123"
  ```

  ### Creating a translation (Persian):
  ```elixir
  # User provides: language_group_id = "abc123" (master's ID)
  Ash.create(Collection, %{name: "فناوری", language: "fa", language_group_id: "abc123", ...})
  # After insert: language_group_id remains "abc123"
  # Result: id = "def456", language_group_id = "abc123"
  ```

  ## Database Implications

  This creates a structure where:
  - Master collections: `id == language_group_id`
  - Translations: `language_group_id == master_collection.id`
  - Query all variants: `WHERE language_group_id = X` (includes master and all translations)
  """
  use Ash.Resource.Change

  @impl true
  @doc """
  Applies the language_group_id assignment logic.

  ## Parameters
  - `changeset` - The Ash changeset for the collection being created
  - `opts` - `before_action?: true` writes the group with the row (see "In the same write")
  - `_context` - Change context (unused)

  ## Returns
  Modified changeset with a hook that sets the group if language_group_id is nil,
  otherwise returns changeset unchanged
  """
  def change(changeset, opts, _context) do
    language_group_id = Ash.Changeset.get_attribute(changeset, :language_group_id)

    cond do
      # Translation collection - language_group_id already provided
      not is_nil(language_group_id) ->
        changeset

      Keyword.get(opts, :before_action?, false) ->
        Ash.Changeset.before_action(changeset, &own_group/1)

      # Master collection - set language_group_id = record.id after insert
      true ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          record
          |> Ash.Changeset.for_update(
            :update,
            %{language_group_id: record.id},
            tenant: record.site_id,
            authorize?: false
          )
          |> Ash.update()
        end)
    end
  end

  # A create's id is generated before its before-actions run, so it is already there to copy.
  defp own_group(changeset) do
    id = Ash.Changeset.get_attribute(changeset, :id)
    Ash.Changeset.force_change_attribute(changeset, :language_group_id, id)
  end
end
