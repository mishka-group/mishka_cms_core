# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.HistoryTimelineTest do
  @moduledoc """
  What a row LOOKS like once it is on screen, which is a separate question from what it records.

  The masking ladder is the reason this file exists. Every row names somebody, and a tenant's admin
  may not be shown a master's address — the same rule the review notes already follow. Getting it
  wrong leaks an email rather than raising, so it is asserted per reader rather than assumed.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MishkaCmsCoreWeb.Templates.HistoryTimeline

  @moduletag :unit

  @site "11111111-1111-1111-1111-111111111111"
  @other_site "22222222-2222-2222-2222-222222222222"

  defp master, do: %{id: "m", site_id: nil, email: "master@example.com"}
  defp tenant, do: %{id: "t", site_id: @site, email: "tenant@example.com"}

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        label: "Set gap (base)",
        kind: :style,
        op: :set_style,
        target: "<nav>",
        detail: "gap: 20px · base",
        note: nil,
        note_edited_at: nil,
        author_type: :human,
        prompt: nil,
        backend: nil,
        refused: false,
        snapshot_id: Ecto.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        author: nil,
        author_id: nil,
        note_author: nil,
        note_author_id: nil
      },
      overrides
    )
  end

  defp person(site_id, email), do: %{id: Ecto.UUID.generate(), site_id: site_id, email: email}

  # The whole template, as Gervaz renders it — rows are drawn inside `render/1`, so there is no
  # smaller unit to test and pretending otherwise would test something the sheet never runs.
  defp render_row(record, reader) do
    assigns = %{
      static: %{
        stream_name: "history",
        filters: [],
        features: [:paginate],
        config: %{},
        ui_adapter: nil,
        empty_state: %{message: "No changes recorded yet"}
      },
      state: %{
        filter_values: %{},
        has_more?: false,
        has_initial_data?: true,
        loading: :loaded,
        current_user: reader
      },
      stream: [{"history-#{record.id}", record}],
      myself: nil,
      __changed__: nil
    }

    rendered_to_string(HistoryTimeline.render(assigns))
  end

  defp author_of(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id^="pb-history-author-"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "who a row says made the change" do
    test "a master is shown every address", _context do
      html =
        render_row(row(%{author: person(nil, "someone@example.com"), author_id: "a"}), master())

      assert html =~ "someone@example.com"
    end

    test "a tenant is shown their own site's people", _context do
      html =
        render_row(
          row(%{author: person(@site, "colleague@example.com"), author_id: "a"}),
          tenant()
        )

      assert html =~ "colleague@example.com"
    end

    test "a tenant is never shown a master's address", _context do
      html =
        render_row(row(%{author: person(nil, "master@example.com"), author_id: "a"}), tenant())

      refute html =~ "master@example.com"
      refute html =~ ">master<"
      assert author_of(html) == "Master"
    end

    test "a master the tenant's read could not load reads Master", _context do
      html = render_row(row(%{author: nil, author_id: "a", author_master?: true}), tenant())

      assert author_of(html) == "Master"
    end

    test "a tenant is never shown another site's address", _context do
      html =
        render_row(
          row(%{author: person(@other_site, "rival@example.com"), author_id: "a"}),
          tenant()
        )

      refute html =~ "rival@example.com"
      assert author_of(html) == "Unknown"
    end

    test "a person's row with no account reads System", _context do
      assert row(%{author: nil, author_id: nil}) |> render_row(tenant()) |> author_of() ==
               "System"
    end

    test "the platform's own rows say so, and not by looking like a hidden person", _context do
      html = render_row(row(%{author_type: :system, op: :publish, kind: :publish}), tenant())

      assert author_of(html) == "System"
      refute html =~ "System administrator"
    end

    test "the assistant is named as the assistant, not as the person who asked", _context do
      html =
        render_row(
          row(%{
            author_type: :ai,
            author: person(@site, "asker@example.com"),
            author_id: "a",
            note: "Added three quotes below the hero.",
            prompt: "add social proof",
            backend: "claude-opus-5"
          }),
          tenant()
        )

      assert html =~ "Assistant"
      refute html =~ "asker@example.com"
    end

    test "an annotated assistant row names who annotated it", _context do
      html =
        render_row(
          row(%{
            author_type: :ai,
            note: "Covers the hero on a phone.",
            note_author: person(@site, "reviewer@example.com"),
            note_author_id: "n"
          }),
          tenant()
        )

      assert html =~ "reviewer@example.com"
      assert html =~ "annotated by"
    end

    test "an annotation by a master names the master as Master", _context do
      html =
        render_row(
          row(%{
            author_type: :ai,
            note: "Checked on a phone.",
            note_author: nil,
            note_author_id: "n",
            note_author_master?: true
          }),
          tenant()
        )

      assert html =~ "annotated by Master"
    end

    test "an annotation by a lost account names it Unknown", _context do
      html =
        render_row(
          row(%{
            author_type: :ai,
            note: "Checked on a phone.",
            note_author: nil,
            note_author_id: "n",
            note_author_master?: false
          }),
          tenant()
        )

      assert html =~ "annotated by Unknown"
    end
  end

  describe "what a row offers" do
    test "a change with a snapshot can be reverted", _context do
      html = render_row(row(), master())

      assert html =~ "Revert"
    end

    test "a change too large to snapshot says so instead", _context do
      html = render_row(row(%{snapshot_id: nil, refused: true}), master())

      refute html =~ ">Revert<"
      assert html =~ "Too large to restore"
    end

    test "a change whose payload retention took says something different", _context do
      html = render_row(row(%{snapshot_id: nil, refused: false}), master())

      refute html =~ ">Revert<"
      assert html =~ "Snapshot dropped"
    end
  end

  describe "how a row reads" do
    test "a restore reads as a restore, not as a publish", _context do
      html = render_row(row(%{kind: :publish, op: :restore, label: "Restored"}), master())

      assert html =~ "restore"
      assert html =~ "uppercase"
    end

    test "an undo reads as an undo", _context do
      html =
        render_row(row(%{kind: :publish, op: :undo, label: "Stepped back 5 changes"}), master())

      assert html =~ "undo"
      assert html =~ "uppercase"
    end

    test "an ordinary style change reads as its bucket", _context do
      html = render_row(row(), master())

      assert html =~ "style"
      assert html =~ "uppercase"
    end

    test "the element and the change are shown together", _context do
      html = render_row(row(%{target: "<nav>", detail: "gap: 20px · base"}), master())

      assert html =~ "&lt;nav&gt;"
      assert html =~ "gap: 20px"
    end

    test "a warning and an explanation do not look the same", _context do
      warning = render_row(row(%{snapshot_id: nil, note: "No longer restorable."}), master())
      explanation = render_row(row(%{note: "Made the header sticky."}), master())

      assert warning =~ "hero-exclamation-triangle"
      assert explanation =~ "hero-bolt"
    end

    test "a note is clamped so a long one does not take over the sheet", _context do
      html =
        render_row(
          row(%{note: String.duplicate("a long sentence about the change. ", 12)}),
          master()
        )

      assert html =~ "line-clamp-3"
      assert html =~ "group-open:line-clamp-none"
    end
  end
end
