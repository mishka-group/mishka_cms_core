# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaCmsCore.PurgeDraftArchival do
  @shortdoc "Deletes runtime drafts discarded while drafts still soft-deleted"

  @moduledoc """
  Deletes runtime drafts that were discarded back when discarding was a soft delete.

  `MishkaCmsCore.Runtime.PageDraft` and its two siblings used `AshArchival` until 2026-08-01: a
  discard set `archived_at` and a base filter hid the row. Removing the extension took the filter
  with it, so those rows became visible again — a draft its author threw away now sits in the picker
  looking like work in progress. Run this once, on any database that existed before that date.

  `MishkaCmsCore.Runtime.DraftArchivalPurge` holds the logic and explains exactly which rows match
  and why a published draft is never one of them.

  ## Command line options

    * `--dry-run` — report what would be deleted and delete nothing
    * `--quiet` — print nothing; the exit status still reflects success

  ## Run it BEFORE migrating

  The migration that drops `archived_at` destroys the only thing separating a discarded draft from a
  live one. After that, no query can tell them apart and this task has nothing to work with — it
  reports zero and exits cleanly, which is the right behaviour and also useless.

      mix mishka_cms_core.purge_draft_archival --dry-run
      mix mishka_cms_core.purge_draft_archival
      mix ash.codegen remove_draft_archival
      mix ash.migrate

  Running it on a database that never archived, or twice, or after the column is gone, is a clean
  no-op in each case.

  ## In a release

  A release has no Mix, and `bin/migrate` drops the column unattended — so the purge has to happen
  before it, through `eval`:

      bin/mishka_cms eval 'MishkaCmsCore.Runtime.DraftArchivalPurge.run()'
      bin/migrate
  """

  use Mix.Task

  alias MishkaCmsCore.Runtime.DraftArchivalPurge

  @requirements ["app.start"]

  @switches [dry_run: :boolean, quiet: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    {:ok, report} = DraftArchivalPurge.run(dry_run: opts[:dry_run] || false)

    unless opts[:quiet], do: report(report, opts[:dry_run] || false)

    :ok
  end

  defp report(report, dry_run?) do
    Enum.each(report, fn {table, result} -> Mix.shell().info(line(table, result)) end)

    total = report |> Map.values() |> Enum.map(&Map.get(&1, :deleted, 0)) |> Enum.sum()
    found = report |> Map.values() |> Enum.map(&Map.get(&1, :found, 0)) |> Enum.sum()

    Mix.shell().info(summary(dry_run?, found, total))
  end

  defp line(table, %{skipped: :no_table}), do: "  #{table}: no such table — nothing to do"

  defp line(table, %{skipped: :no_column}),
    do: "  #{table}: already migrated (no archived_at) — nothing to do"

  defp line(table, %{found: found, deleted: deleted, failed: [_ | _] = failed}),
    do:
      "  #{table}: #{found} found, #{deleted} deleted, #{length(failed)} FAILED: #{Enum.join(failed, ", ")}"

  defp line(table, %{found: found, deleted: deleted}),
    do: "  #{table}: #{found} found, #{deleted} deleted"

  defp summary(true, found, _deleted),
    do: "#{found} legacy discarded draft(s) would be deleted. Re-run without --dry-run to do it."

  defp summary(false, _found, 0), do: "Nothing to purge."
  defp summary(false, _found, deleted), do: "Deleted #{deleted} legacy discarded draft(s)."
end
