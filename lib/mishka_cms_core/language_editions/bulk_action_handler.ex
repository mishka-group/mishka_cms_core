# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.LanguageEditions.BulkActionHandler do
  @moduledoc """
  A translated table's bulk actions over the archive, its masters handed over first.

      mishka_gervaz do
        table do
          events do
            bulk_action MishkaCmsCore.LanguageEditions.BulkActionHandler
          end
        end
      end

  The archive is the one list that shows a master beside its own archived editions
  (`MishkaCmsCore.LanguageEditions`), so restoring a whole group is one selection over all of them —
  and a translation is restored only into a group whose master is back
  (`MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore`). A bulk action walks
  its rows in the order the read hands them over, which on a random-uuid key is no order at all: with
  the master anywhere but first, a resource whose rows are written one at a time refuses the very
  selection the archive invites. Sorting the masters to the front of that read is what makes the
  answer the same every time.

  One at a time is what a manual action gets: Ash streams a bulk of those a row per batch, and
  `MishkaDocument.Workspace`'s actions are manual, wrapped by its event log. A resource whose rows go
  in as one batch has every write of the batch behind it before the first after-action hook runs,
  which is what lets `MishkaCmsCore.Runtime.Page` and `MishkaBlog.Collection` take a group in any
  order; this sort is what makes them all behave alike.

  Only the archive is sorted. The active list holds one row per group, so nothing there selects a
  master together with its translations except a search, and the rule for destroying a group is the
  other way round anyway: the translations go first.
  """

  use MishkaGervaz.Table.Web.Events.BulkActionHandler

  require Ash.Sort

  @impl true
  def build_bulk_query(resource, %{archive_status: :archived} = state, filter) do
    super(resource, state, filter)
    |> Ash.Query.sort([{Ash.Sort.expr_sort(language_group_id == id, :boolean), :desc_nils_first}])
  end

  def build_bulk_query(resource, state, filter), do: super(resource, state, filter)
end
