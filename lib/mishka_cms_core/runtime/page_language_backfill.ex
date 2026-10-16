# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageLanguageBackfill do
  @moduledoc """
  The language fields a page written before them has to be given, before anything reads them.

  ## Why

  A page's `language_group_id` is its master's id, and a new page gets its own id in the same write
  (`MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId`). A page stored before the column
  existed has none. Such a page is a master with nothing to join: the sibling relationships join on
  the group, so a translation that joined its id would be listed under no chip and give it no
  hreflang link. `MishkaCmsCore.Runtime.PageEditions.translate/4` gives a page the boot has not
  grouped its group with `run/1`, in the write that creates its first translation.

  Migrations are generated per database with `mix ash.codegen` and are not in the repository, so a
  data step written into one reaches only the database it was written on. This runs from
  `MishkaCmsCore.Runtime.Handlers.BootHandler` instead, before any page is compiled — a compiled page
  carries its group — on every database that boots this code.

  `Page`'s `unique_language_per_group` identity treats a missing group as distinct for the same
  reason: the migration that creates its index runs before this does, on a database where every old
  page has none.

  ## Archived pages

  Left as they are. The `prevent_archived_page_updates` trigger refuses every write to an archived
  page but the one that restores it, and one statement is all or nothing: a single archived page in
  it failed the whole `UPDATE`, and no page on any site got a group. An archived page gets its group
  from that restore instead — `:unarchive` and `:master_unarchive` run `SetLanguageGroupId` in the
  same write — and until then it is served nowhere and offered no translation.

  ## Running it

  One `UPDATE` of the live rows with no group, and nothing else — so a database with none left,
  which is every database after its first boot, is a no-op. SQL rather than an Ash update: the group
  is derived from the row's own id, and an update per page would be a version, a broadcast and a
  compile job for each page on the site.

      MishkaCmsCore.Runtime.PageLanguageBackfill.run()
      #=> {:ok, 12}
  """

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @ungrouped "UPDATE pages SET language_group_id = id " <>
               "WHERE language_group_id IS NULL AND archived_at IS NULL"

  @unmarked """
  UPDATE pages
  SET extra = jsonb_set(coalesce(extra, '{}'::jsonb), '{serves_all_languages}', 'true'::jsonb, true)
  WHERE archived_at IS NULL
    AND extra->>'provisioned_by' IS NOT NULL
    AND extra->>'provisioned_by' <> 'mishka_cms_core'
    AND coalesce(extra->>'serves_all_languages', '') <> 'true'
  """

  @doc "Gives each live page with no language group its own id as one. Returns how many it changed."
  @spec run() :: {:ok, non_neg_integer()} | {:error, term()}
  def run, do: query(@ungrouped, [])

  @doc """
  `run/0` for the one page `page_id` — `0` when it already has a group or is archived. It runs in the
  caller's transaction, if there is one.
  """
  @spec run(Ecto.UUID.t()) :: {:ok, 0 | 1} | {:error, term()}
  def run(page_id), do: query(@ungrouped <> " AND id = $1", [Ecto.UUID.dump!(page_id)])

  @doc """
  Marks every live extension-provisioned page as answering all languages, and says how many it
  changed.

  A `/:lang/...` page answers only the language it was written in — see
  `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState`'s `edition?/2`, which is what stops
  `/fa/about` serving the English page to a Persian reader. An extension's pages are the exception,
  and not because they are unfinished: `/:lang/blog` holds no prose. It holds components that read
  the captured language and fetch that language's rows, so one page has always answered every
  language its site publishes. `MishkaCmsCore.Runtime.ExtensionProvision` marks them as it writes
  them; every site provisioned before it learned to would otherwise lose `/fa/blog` on upgrade.

  THE EXTENSION'S OWN PAGES AND NO OTHERS. Core stamps its starter content the same way — `about`,
  `contact`, `privacy` — and those are prose, in one language, and precisely the pages the rule
  exists for: marking them would put the bug back. A page nobody stamped was written by hand, in a
  language, and keeps answering that one.

  Safe at every boot: a row already carrying the mark is skipped, so the second run changes nothing.
  """
  @spec mark_extension_pages() :: {:ok, non_neg_integer()} | {:error, term()}
  def mark_extension_pages, do: query(@unmarked, [])

  defp query(sql, params) do
    case Ecto.Adapters.SQL.query(@repo, sql, params) do
      {:ok, %{num_rows: changed}} -> {:ok, changed}
      {:error, _reason} = error -> error
    end
  end
end
