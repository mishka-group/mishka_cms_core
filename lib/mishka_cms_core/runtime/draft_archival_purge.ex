defmodule MishkaCmsCore.Runtime.DraftArchivalPurge do
  @moduledoc """
  Deletes runtime drafts that were discarded while these resources still soft-deleted.

  ## What went wrong

  `MishkaCmsCore.Runtime.PageDraft` and its two siblings used `AshArchival` until 2026-08-01.
  Discarding a draft did not remove the row — it set `archived_at`, and a resource-level
  `base_filter_sql "(archived_at IS NULL)"` hid it from every read.

  When the extension was removed, discard became a real delete. But the base filter went with it,
  so every row still carrying an `archived_at` became **visible again**: a draft its author threw
  away is back in the picker, indistinguishable from work in progress. That happened the moment the
  code was pulled, before any migration ran.

  Dropping the column afterwards does not resurrect anything further — the rows were already
  visible — but it does remove the only evidence of which ones were discarded. This module is how
  that evidence gets acted on while it still exists.

  ## What it deletes

  Rows matching `archived_at IS NOT NULL AND applied_at IS NULL`, in `page_drafts`, `layout_drafts`
  and `error_page_drafts`.

  The `applied_at IS NULL` half is not redundant. Nothing in the UI could archive a published draft
  — every picker lists pending drafts only — but `Drafts.discard/3` takes an id from the client and
  does not check it against that list, so the combination is reachable in principle. A published
  draft has already written its content to the live `Page`, and its publish is recorded there;
  requiring `applied_at IS NULL` means this purge provably cannot destroy the record of a publish,
  rather than merely being unlikely to.

  Nothing else needs the same treatment. The old `archive do` blocks declared no `archive_related`,
  so the removal orphaned nothing, and the resources that still archive — Page, Layout, Component,
  Media, Site, and `MishkaDocument`'s own `*_drafts`, which are a different thing entirely — are
  untouched and must stay that way.

  ## Running it

  It is safe on a database that never archived, safe once the column is gone, and safe to run twice
  — each of those is a clean no-op reporting zero. It is only USEFUL before the migration that drops
  `archived_at`, because afterwards a discarded draft is byte-identical to live work and no query
  can tell them apart.

      mix mishka_cms_core.purge_draft_archival --dry-run
      mix mishka_cms_core.purge_draft_archival

  In a release there is no Mix, and `bin/migrate` drops the column unattended, so run this first:

      bin/mishka_cms eval 'MishkaCmsCore.Runtime.DraftArchivalPurge.run()'

  See `Mix.Tasks.MishkaCmsCore.PurgeDraftArchival` and `MishkaCmsCore.Runtime.PageDraft`.
  """

  alias MishkaCmsCore.Runtime.{ErrorPageDraft, LayoutDraft, PageDraft}

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Table and the resource that owns it. The table name is needed because the predicate is raw SQL —
  # `archived_at` is no longer an Ash attribute, so no Ash query can name it — and the resource is
  # needed because the deletion goes through Ash.
  @tables [
    {"page_drafts", PageDraft},
    {"layout_drafts", LayoutDraft},
    {"error_page_drafts", ErrorPageDraft}
  ]

  @type report :: %{
          required(String.t()) => %{
            optional(:deleted) => non_neg_integer(),
            optional(:found) => non_neg_integer(),
            optional(:skipped) => :no_table | :no_column,
            optional(:failed) => [String.t()]
          }
        }

  @doc """
  Purges the legacy rows and returns what it did, per table.

  Options:

    * `:dry_run` — find and count, delete nothing. Default `false`.
  """
  @spec run(keyword()) :: {:ok, report()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    {:ok, Map.new(@tables, fn {table, resource} -> {table, purge(table, resource, dry_run?)} end)}
  end

  @doc "Whether any table still carries the column — what makes this task worth running at all."
  @spec pending?() :: boolean()
  def pending?, do: Enum.any?(@tables, fn {table, _resource} -> column?(table) end)

  defp purge(table, resource, dry_run?) do
    cond do
      not table?(table) -> %{skipped: :no_table}
      not column?(table) -> %{skipped: :no_column}
      true -> delete_found(table, resource, dry_run?)
    end
  end

  defp delete_found(table, resource, dry_run?) do
    ids = legacy_ids(table)

    case dry_run? do
      true -> %{found: length(ids), deleted: 0}
      false -> destroy_all(ids, resource)
    end
  end

  # Through Ash rather than a raw DELETE. Nothing in Postgres references these tables, so a DELETE
  # would corrupt nothing — but `:master_destroy` broadcasts on PubSub and runs the plugin hook, and
  # an editor with the picker open should see the row leave rather than find it gone on next reload.
  defp destroy_all(ids, resource) do
    {deleted, failed} =
      Enum.reduce(ids, {0, []}, fn id, {deleted, failed} ->
        case destroy(resource, id) do
          :ok -> {deleted + 1, failed}
          :error -> {deleted, [id | failed]}
        end
      end)

    %{found: length(ids), deleted: deleted, failed: Enum.reverse(failed)}
  end

  defp destroy(resource, id) do
    with {:ok, record} <- Ash.get(resource, id, action: :get_any, authorize?: false),
         :ok <- destroy_record(record) do
      :ok
    else
      _error -> :error
    end
  end

  defp destroy_record(record) do
    record
    |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
    |> Ash.destroy()
    |> case do
      :ok -> :ok
      {:ok, _record} -> :ok
      {:error, _reason} -> :error
    end
  end

  # `applied_at IS NULL` is what makes this provably unable to delete the record of a publish.
  defp legacy_ids(table) do
    sql =
      "SELECT id::text FROM #{table} WHERE archived_at IS NOT NULL AND applied_at IS NULL " <>
        "ORDER BY archived_at"

    case Ecto.Adapters.SQL.query(@repo, sql, []) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      {:error, _reason} -> []
    end
  end

  # `to_regclass` answers nil rather than raising for a table that is not there, which is what makes
  # the check safe to run against a database this app has never migrated.
  defp table?(table) do
    case Ecto.Adapters.SQL.query(@repo, "SELECT to_regclass($1) IS NOT NULL", [table]) do
      {:ok, %{rows: [[present?]]}} -> present?
      _error -> false
    end
  end

  defp column?(table) do
    sql = """
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_name = $1 AND column_name = 'archived_at'
    )
    """

    case Ecto.Adapters.SQL.query(@repo, sql, [table]) do
      {:ok, %{rows: [[present?]]}} -> present?
      _error -> false
    end
  end
end
