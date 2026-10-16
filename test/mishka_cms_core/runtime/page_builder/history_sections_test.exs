# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.HistorySectionsTest do
  @moduledoc """
  Whose drafts the editing history can actually be recorded against.

  `MishkaCmsCore.Runtime.PageBuilderEvent` says in its own moduledoc that `source_type` + `source_id`
  name the live record "always, for all four editable kinds", and that `draft_id` "only says which
  branch the change happened on". The first half was true. The second was a `belongs_to` to
  `MishkaCmsCore.Runtime.PageDraft` alone — one foreign key, to `page_drafts` — so a change made on a
  LAYOUT's or an ERROR PAGE's draft violated it, `write/3` logged a warning and the row was dropped.

  Nothing surfaced: the flush requeues on failure, the log line is a warning, and the History sheet
  simply showed an empty timeline for those two sections. Every revert point on a layout draft and an
  error-page draft was missing, and the editor gave no sign of it.

  These tests go through the same funnel `MishkaCmsCore.Runtime.PageBuilder.HistoryTest` uses — a real
  session, a real op, a real flush — and differ only in which section's draft the branch is.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.PageBuilder.{EditorSession, History, Tree}
  alias MishkaCmsCore.Runtime.PageBuilderEvent

  require Ash.Query

  @moduletag :unit

  @template ~s(<div id="root"><h1>Contact Us</h1></div>)

  setup do
    site = create_site!()
    author = create_user_with_permissions!(["admin:dashboard:runtime:*"], site_id: site.id)

    %{site: site, author: author}
  end

  defp heading(session) do
    session.tree |> Tree.walk() |> Enum.find(&(&1.tag == "h1")) |> Map.fetch!(:children) |> hd()
  end

  defp rows(record_id) do
    PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(source_id == ^record_id)
    |> Ash.read!(authorize?: false)
  end

  # Each section's live record and a draft of it, built the way the resource actually accepts —
  # which is the whole point: three keep a `template`, an error page keeps `error_pages`.
  defp fixture(:page, site) do
    record = create_page!(site_id: site.id, template: @template)

    draft =
      MishkaCmsCore.Runtime.PageDraft
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          label: "d",
          name: record.name,
          title: record.title,
          path: record.path,
          template: @template,
          source_page_id: record.id,
          site_id: site.id
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    {record, draft}
  end

  defp fixture(:layout, site) do
    record = create_layout!(site_id: site.id, template: @template)

    draft =
      MishkaCmsCore.Runtime.LayoutDraft
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          label: "d",
          name: record.name,
          path: record.path,
          template: @template,
          source_layout_id: record.id,
          site_id: site.id
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    {record, draft}
  end

  defp fixture(:error_page, site) do
    entries = [%{"status" => 404, "template" => @template, "layout" => %{}}]
    record = create_error_page!(site_id: site.id, error_pages: entries)

    draft =
      MishkaCmsCore.Runtime.ErrorPageDraft
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          label: "d",
          name: record.name,
          path: record.path,
          error_pages: entries,
          source_error_page_id: record.id,
          site_id: site.id
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    {record, draft}
  end

  for section <- [:page, :layout, :error_page] do
    test "a change on a #{section}'s draft is recorded against that branch", %{
      site: site,
      author: author
    } do
      {record, draft} = fixture(unquote(section), site)

      {:ok, session} =
        EditorSession.open(%{
          section: to_string(unquote(section)),
          template: @template,
          site_id: site.id,
          resource_id: record.id,
          draft_id: draft.id
        })

      {:ok, _edited} =
        EditorSession.apply_op(session.token, %{
          kind: :set_text,
          node_id: heading(session),
          text: "Talk to us"
        })

      assert {:ok, 1} = History.flush(session.token, author),
             "the row was refused and put back — the timeline for this section stays empty"

      assert [row] = rows(record.id)
      assert row.draft_id == draft.id, "the change was not anchored to the draft it happened on"
      assert row.source_id == record.id
    end
  end

  # WHAT THE FOREIGN KEY USED TO DO, now that there is no key to do it. Publishing and discarding
  # both delete the draft, and its rows have to stay and join the live record's timeline rather than
  # sit in a branch nothing can name again. Asserted through the RESOURCE's own destroy, because
  # that is the path the draft picker's Delete takes — `Drafts.discard/3` is only one of three.
  for section <- [:page, :layout, :error_page] do
    test "deleting a #{section}'s draft releases its history instead of losing it", %{
      site: site,
      author: author
    } do
      {record, draft} = fixture(unquote(section), site)

      {:ok, session} =
        EditorSession.open(%{
          section: to_string(unquote(section)),
          template: @template,
          site_id: site.id,
          resource_id: record.id,
          draft_id: draft.id
        })

      {:ok, _edited} =
        EditorSession.apply_op(session.token, %{
          kind: :set_text,
          node_id: heading(session),
          text: "Talk to us"
        })

      {:ok, 1} = History.flush(session.token, author)
      assert [%{draft_id: branch}] = rows(record.id)
      assert branch == draft.id

      draft
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
      |> Ash.destroy!(authorize?: false)

      assert [row] = rows(record.id), "the history went with the draft"

      assert is_nil(row.draft_id),
             "the row is stranded in a branch that no longer exists"
    end
  end

  # And the live branch, which never had a draft to point at, goes on working for all three.
  for section <- [:page, :layout, :error_page] do
    test "a change with no draft still records for a #{section}", %{site: site, author: author} do
      {record, _draft} = fixture(unquote(section), site)

      {:ok, session} =
        EditorSession.open(%{
          section: to_string(unquote(section)),
          template: @template,
          site_id: site.id,
          resource_id: record.id
        })

      {:ok, _edited} =
        EditorSession.apply_op(session.token, %{
          kind: :set_text,
          node_id: heading(session),
          text: "Talk to us"
        })

      assert {:ok, 1} = History.flush(session.token, author)
      assert [row] = rows(record.id)
      assert is_nil(row.draft_id)
    end
  end
end
