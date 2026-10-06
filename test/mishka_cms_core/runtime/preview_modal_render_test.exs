defmodule MishkaCmsCoreWeb.Runtime.PreviewModalRenderTest do
  @moduledoc """
  Renders the runtime preview modal to validate the full-LiveView `src` wiring for ErrorPage/Layout:
  the Preview tab points its iframe at `/_preview/:resource/:token` (with `?status=` for error pages)
  for both the live original and a draft.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  import Phoenix.LiveViewTest
  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, Page, PageDraft}

  # Merged onto the real shape rather than a copy of it: a copy goes stale the moment a key is
  # added to the modal, and fails as a KeyError from the template instead of a behaviour.
  defp state(overrides) do
    PreviewHelpers.empty()
    |> Map.put(:resource, ErrorPage)
    |> Map.put(:active_tab, "preview")
    |> Map.merge(Map.new(overrides))
  end

  defp error_record do
    struct(ErrorPage,
      id: "rec-err",
      name: "Errors",
      path: "/e",
      preview_token: "tok-err",
      site: %{name: "localhost", host: "localhost"},
      error_pages: [%{status: 404, template: "x"}, %{status: 500, template: "y"}]
    )
  end

  test "ErrorPage original previews as a full-LiveView iframe with the selected status in the URL" do
    html =
      render_component(&RuntimePreviewModal.modal/1,
        preview: state(%{record: error_record(), preview_error_status: 500})
      )

    assert html =~ "/_preview/error_page/tok-err?status=500"
    # the error-code selector is present
    assert html =~ "Error code"
  end

  test "switching the selected status changes the iframe URL" do
    html =
      render_component(&RuntimePreviewModal.modal/1,
        preview: state(%{record: error_record(), preview_error_status: 404})
      )

    assert html =~ "/_preview/error_page/tok-err?status=404"
    refute html =~ "status=500\""
  end

  test "Layout original previews as a full-LiveView iframe (no status param)" do
    record =
      struct(Layout,
        id: "rec-lay",
        name: "Layout",
        path: "/l",
        preview_token: "tok-lay",
        site: %{name: "localhost", host: "localhost"}
      )

    html =
      render_component(&RuntimePreviewModal.modal/1,
        preview: state(%{resource: Layout, record: record, preview_error_status: nil})
      )

    assert html =~ "/_preview/layout/tok-lay"
    refute html =~ "?status="
  end

  # THE DRAFTS STRIP, which is the modal's answer to "which of these am I looking at" — and, since
  # the ✖ arrived, to "and which of them can I throw away". Both questions are about a SPECIFIC
  # badge rather than about the selection, which is what these pin.
  describe "the drafts strip" do
    defp draft(id, label, day) do
      struct(PageDraft,
        id: id,
        label: label,
        updated_at: DateTime.new!(Date.new!(2026, 8, day), ~T[11:18:00], "Etc/UTC")
      )
    end

    defp strip(overrides) do
      drafts = [
        draft("d-1", "Newest", 26),
        draft("d-2", "Middle", 25),
        draft("d-3", "Oldest", 24)
      ]

      state(
        Map.merge(
          %{
            resource: Page,
            active_tab: "overview",
            record: struct(Page, id: "rec-page", name: "Forms", path: "/forms"),
            drafts_enabled?: true,
            writable?: true,
            drafts: drafts,
            drafts_total: 3,
            draft: List.first(drafts)
          },
          Map.new(overrides)
        )
      )
    end

    defp render_strip(overrides \\ %{}),
      do: render_component(&RuntimePreviewModal.modal/1, preview: strip(overrides))

    test "every badge carries a delete of its own" do
      html = render_strip()

      for id <- ~w(d-1 d-2 d-3) do
        assert html =~ ~s(id="runtime-preview-draft-delete-#{id}"),
               "the badge for #{id} has no way to delete it"
      end
    end

    # THE ID IS THE WHOLE POINT. Without it the event carries nothing and the helper falls back to
    # the SELECTED draft — so every ✖ on the strip would have deleted the same row, whichever one
    # was clicked.
    test "and the delete names its own draft, not the selected one" do
      html = render_strip()

      [_before, after_delete] =
        String.split(html, ~s(id="runtime-preview-draft-delete-d-3"), parts: 2)

      assert after_delete =~ ~s(phx-value-id="d-3")
      assert String.split(after_delete, "</button>", parts: 2) |> hd() =~ "preview_discard_draft"
    end

    # A browser will not render a button inside a button — the outer one swallows the inner one's
    # clicks — so the ✖ has to be a sibling of the badge. The select button closing before the
    # delete opens is what says it is.
    test "the delete is a sibling of the badge, never nested inside it" do
      html = render_strip()

      [_before, rest] = String.split(html, ~s(id="runtime-preview-draft-d-2"), parts: 2)
      [between, _after] = String.split(rest, ~s(id="runtime-preview-draft-delete-d-2"), parts: 2)

      assert between =~ "</button>", "the ✖ is nested inside the badge's own button"
    end

    # DELETING, PUBLISHING AND DISCARDING WRITE, so a reader without the page area reads the strip
    # and is offered none of the three.
    test "a reader who may not write the record gets the badges and no write" do
      html = render_strip(%{writable?: false})

      assert html =~ ~s(id="runtime-preview-draft-d-1")
      refute html =~ "runtime-preview-draft-delete-"
      refute html =~ ~s(id="runtime-preview-publish")
      refute html =~ ~s(id="runtime-preview-discard")
      refute html =~ "New draft"
    end

    test "it asks first, in the words the builder's own draft list uses" do
      assert render_strip() =~ "Delete the draft “Middle”? This cannot be undone."
    end

    # LEAVING FOR THE BUILDER USED TO FORGET THE CHOICE. The editor read the drafts table for itself
    # and offered whichever was newest, so picking the second badge and clicking through arrived at
    # an offer to carry on with the first.
    test "the Visual Editor link carries the selected draft" do
      html =
        render_strip(%{
          visual_editor_url: "/admin/dashboard/runtime/builder/page/rec-page",
          draft: draft("d-2", "Middle", 25)
        })

      assert html =~ "/admin/dashboard/runtime/builder/page/rec-page?draft_id=d-2"
    end

    test "and joins it onto a site_id that is already on the URL" do
      html =
        render_strip(%{
          visual_editor_url: "/admin/dashboard/runtime/builder/page/rec-page?site_id=site-9",
          draft: draft("d-2", "Middle", 25)
        })

      assert html =~ "builder/page/rec-page?site_id=site-9&amp;draft_id=d-2"
    end

    test "with nothing selected the link is left exactly as it was" do
      html =
        render_strip(%{
          visual_editor_url: "/admin/dashboard/runtime/builder/page/rec-page",
          draft: nil
        })

      assert html =~ "/admin/dashboard/runtime/builder/page/rec-page"
      refute html =~ "draft_id="
    end
  end

  # The modal is drawn by six tables and the button by one. What decides it is the state the helper
  # computed, never the template guessing from the resource.
  describe "the Duplicate button" do
    defp duplicate_button(overrides) do
      record = struct(Component, id: "rec-comp", name: "chelekom-badge", site_id: nil)

      render_component(&RuntimePreviewModal.modal/1,
        preview: state(Map.merge(%{resource: Component, record: record}, Map.new(overrides)))
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#runtime-preview-duplicate")
    end

    test "is drawn only when the preview says the record is duplicable" do
      assert Enum.count(duplicate_button(duplicable?: true)) == 1
      assert Enum.empty?(duplicate_button(duplicable?: false))
    end

    test "sends its event, and says it is busy while the copy is written" do
      idle = duplicate_button(duplicable?: true)
      assert LazyHTML.attribute(idle, "phx-click") == ["preview_duplicate"]
      assert LazyHTML.attribute(idle, "disabled") == []
      assert LazyHTML.text(idle) =~ "Duplicate"

      busy = duplicate_button(duplicable?: true, duplicating?: true)
      assert LazyHTML.attribute(busy, "disabled") == [""]
      assert LazyHTML.text(busy) =~ "Duplicating…"
    end
  end
end
