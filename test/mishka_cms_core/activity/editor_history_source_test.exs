# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.EditorHistoryTest do
  @moduledoc """
  The editor's record reaching the global feed.

  Nothing else can see these rows — `PageBuilderEvent` is not versioned, not an events log and not a
  job — so before this source a whole afternoon in the page builder left the feed empty while the
  editor's own sheet was full. One store, two surfaces.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Activity.Query
  alias MishkaCmsCore.Activity.Sources.EditorHistory, as: Source
  alias MishkaCmsCore.Runtime.{Component, Media, Page, PageBuilderEvent}

  @moduletag :integration

  setup do
    site = create_site!()
    page = create_page!(site_id: site.id)
    author = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

    %{site: site, page: page, author: author}
  end

  defp record(context, overrides) do
    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          source_type: :page,
          source_id: context.page.id,
          site_id: context.site.id,
          label: "Set gap (base)",
          target: "<nav>",
          kind: :style,
          op: :set_style
        },
        overrides
      )

    PageBuilderEvent
    |> Ash.Changeset.for_create(:create, attrs,
      tenant: context.site.id,
      actor: context.author,
      authorize?: false
    )
    |> Ash.create!(actor: context.author, authorize?: false)
  end

  defp editor_rows(opts \\ %{}), do: Enum.filter(Query.page(opts), &(&1.badge_label == "EDITOR"))

  describe "reaching the feed" do
    test "a change in the editor appears", context do
      record(context, %{})

      assert [entry] = editor_rows()
      assert entry.badge_label == "EDITOR"
      assert entry.resource_label =~ "Editor"
      assert entry.message =~ "Set gap (base)"
      assert entry.site_id == context.site.id
      assert entry.user_id == context.author.id
    end

    # `source_id` names the LIVE record on every source — it is what a resource-scoped feed filters
    # on, and what a row would have to link to. The editor branch used to alias the EVENT's id over
    # it, which pointed nowhere and would have silently emptied any such feed.
    test "source_id names the document, not the event", context do
      record(context, %{})

      assert [%{source_id: source_id}] = editor_rows()
      assert source_id == context.page.id
    end

    # The trap that comes with the line above: with the document in `source_id`, the row's own
    # identity has to come from the event instead — or a hundred edits to one page all answer to
    # `editor-<page_id>`, and the LiveView stream keyed on it draws one of them.
    test "every change to one page is still its own entry", context do
      for label <- ["Set gap (base)", "Set direction (base)", "Set justify (base)"] do
        record(context, %{label: label})
      end

      ids = editor_rows() |> Enum.map(& &1.id)

      assert length(ids) == 3
      assert Enum.uniq(ids) == ids
    end

    test "the message says which change, in the editor's own words", context do
      record(context, %{label: "Edited text", target: "<h1>", kind: :content})

      assert [%{message: message}] = editor_rows()
      assert message == "Edited text — <h1>"
    end

    test "a change with no element still reads", context do
      record(context, %{label: "Published contact", target: nil, kind: :publish, op: :publish})

      assert [%{message: message, action: action}] = editor_rows()
      assert message == "Published contact"
      assert action == :publish
    end

    test "everything that is not a publish is an update", context do
      record(context, %{kind: :style})
      record(context, %{id: Ecto.UUID.generate(), kind: :content, label: "Edited text"})

      assert Enum.all?(editor_rows(), &(&1.action == :update))
    end

    test "each section is named", context do
      component = create_component!(site_id: context.site.id)

      record(context, %{})

      record(context, %{
        id: Ecto.UUID.generate(),
        source_type: :component,
        source_id: component.id,
        label: "Styled button"
      })

      labels = editor_rows() |> Enum.map(& &1.resource_label) |> Enum.sort()

      assert labels == ["Editor · Component", "Editor · Page"]
    end
  end

  describe "scope" do
    test "a document's own feed shows its changes", context do
      record(context, %{})

      assert [_entry] = editor_rows(%{resource: to_string(Page)})
    end

    test "and another resource's feed does not", context do
      record(context, %{})

      assert editor_rows(%{resource: to_string(Media)}) == []
      assert editor_rows(%{resource: to_string(Component)}) == []
    end

    test "searching finds a change by what it says", context do
      record(context, %{label: "Set gap (base)"})
      record(context, %{id: Ecto.UUID.generate(), label: "Deleted element", target: "<span>"})

      assert [%{message: message}] = editor_rows(%{search: "Deleted"})
      assert message =~ "Deleted element"
    end
  end

  describe "the entry" do
    # The core's contract test asks whichever union sources are installed; this one asks the
    # editor's own, so the shape is held to wherever the source lives.
    test "omits no key a renderer reads" do
      row = %{
        "source" => Source.id(),
        "resource" => to_string(Page),
        "action" => "update",
        "source_id" => Ecto.UUID.generate(),
        "event_id" => Ecto.UUID.generate(),
        "site_id" => nil,
        "user_id" => nil,
        "inserted_at" => ~U[2026-01-01 09:00:00.000000Z],
        "payload" => %{"label" => "Edited text", "target" => "<h1>"}
      }

      assert MishkaCmsCore.Activity.Helpers.entry_keys() -- Map.keys(Source.entry_from_row(row)) ==
               []
    end

    test "is installed as a union source of the activity log" do
      assert Source in MishkaCmsCore.Activity.Behaviours.UnionSource.all()
    end
  end

  describe "what it does not do" do
    # The resource broadcasts nothing on purpose: a row is written on every settled change, and
    # re-reading a table for everybody on every keystroke is the noise the design avoids.
    test "it contributes nothing to the live tail" do
      assert Source.topics(%{}) == []
      refute Source.handles?(%{topic: "anything", event: "created", payload: %{}})
      assert Source.to_entry(%{topic: "anything", event: "created", payload: %{}}) == nil
      assert Source.initial_fetch(%{}, 10) == []
    end

    test "a warning-only read does not ask for editor rows", context do
      record(context, %{})

      # Every row is somebody making a change, which is information rather than a warning.
      assert editor_rows(%{severity: "warn"}) == []
      assert editor_rows(%{severity: "error"}) == []
    end
  end
end
