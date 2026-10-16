# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.RuntimeDraftTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import MishkaCmsCore.Test.Factory
  @moduletag :integration

  alias MishkaCmsCore.Activity.Query
  alias MishkaCmsCore.Activity.Sources.RuntimeDraft, as: Source

  alias MishkaCmsCore.Runtime.{
    Component,
    Page,
    Layout,
    ErrorPage,
    PageDraft,
    LayoutDraft,
    ErrorPageDraft
  }

  defp broadcast(resource, action_name, data, actor \\ nil) do
    %Phoenix.Socket.Broadcast{
      topic: "draft:updated",
      event: "updated",
      payload: %Ash.Notifier.Notification{
        resource: resource,
        action: %{name: action_name},
        data: data,
        actor: actor
      }
    }
  end

  test "handles? matches all three draft resources, not others" do
    for module <- [PageDraft, LayoutDraft, ErrorPageDraft] do
      assert Source.handles?(broadcast(module, :update, %{id: "x", name: "n"}))
    end

    refute Source.handles?(%Phoenix.Socket.Broadcast{
             payload: %Ash.Notifier.Notification{resource: Page}
           })

    refute Source.handles?(%Phoenix.Socket.Broadcast{payload: %{__oban__: true}})
    refute Source.handles?(:nope)
  end

  test "topics are per-resource-scope; unscoped covers all three prefixes" do
    master = %{site_id: nil}

    all = Source.topics(%{current_user: master})
    assert Enum.any?(all, &String.starts_with?(&1, "page_draft:"))
    assert Enum.any?(all, &String.starts_with?(&1, "layout_draft:"))
    assert Enum.any?(all, &String.starts_with?(&1, "error_page_draft:"))

    page_topics = Source.topics(%{current_user: master, resources: [Page]})
    assert page_topics != [] and Enum.all?(page_topics, &String.starts_with?(&1, "page_draft:"))

    layout_topics = Source.topics(%{current_user: master, resources: [Layout]})

    assert layout_topics != [] and
             Enum.all?(layout_topics, &String.starts_with?(&1, "layout_draft:"))

    error_topics = Source.topics(%{current_user: master, resources: [ErrorPage]})

    assert error_topics != [] and
             Enum.all?(error_topics, &String.starts_with?(&1, "error_page_draft:"))

    assert Source.topics(%{current_user: master, resources: [Component]}) == []

    tenant = Source.topics(%{current_user: %{site_id: "abc"}})
    assert tenant != [] and Enum.all?(tenant, &String.contains?(&1, "abc"))

    # A MASTER IS A USER WHOSE `site_id` IS NIL; no viewer subscribes to nothing.
    assert Source.topics(%{}) == []
    assert Source.topics(%{current_user: %{}, resources: [Page]}) == []
  end

  test "to_entry tags DRAFT with a per-resource label + verb-aware message + severity" do
    saved =
      Source.to_entry(
        broadcast(PageDraft, :update, %{id: "1", name: "Contact", updated_at: DateTime.utc_now()})
      )

    assert saved.badge_label == "DRAFT"
    assert saved.resource_label == "Page Draft"
    assert saved.action == :update
    assert saved.severity == :info
    assert saved.message =~ "Contact" and saved.message =~ "saved"

    assert Source.to_entry(
             broadcast(LayoutDraft, :update, %{
               id: "1",
               name: "Hero",
               updated_at: DateTime.utc_now()
             })
           ).resource_label == "Layout Draft"

    assert Source.to_entry(
             broadcast(ErrorPageDraft, :update, %{
               id: "1",
               name: "Errs",
               updated_at: DateTime.utc_now()
             })
           ).resource_label == "Error Page Draft"

    published =
      Source.to_entry(
        broadcast(PageDraft, :master_publish, %{
          id: "1",
          name: "C",
          updated_at: DateTime.utc_now()
        })
      )

    assert published.action == :publish and published.message =~ "published"

    # A discard is a LIVE event and only a live one: these resources do not archive, so the row is
    # gone and the history read has nothing left to report. The notification carries the record as it
    # was immediately before deletion — `updated_at`, and no `archived_at`, which an earlier
    # soft-deleting version used to supply.
    discarded_at = ~U[2026-01-02 03:04:05Z]

    discarded =
      Source.to_entry(
        broadcast(PageDraft, :destroy, %{id: "1", name: "C", updated_at: discarded_at})
      )

    assert discarded.action == :destroy and discarded.severity == :warn and
             discarded.message =~ "discarded"

    # The last time the draft was touched is the closest thing to a discard time there is.
    assert DateTime.compare(discarded.inserted_at, discarded_at) == :eq
  end

  test "to_entry id is deterministic per broadcast (idempotent on double-delivery)" do
    msg = broadcast(PageDraft, :update, %{id: "1", name: "X", updated_at: DateTime.utc_now()})
    assert Source.to_entry(msg).id == Source.to_entry(msg).id
  end

  test "entry_from_row derives the label from the row's resource module" do
    row = fn module ->
      %{
        "resource" => to_string(module),
        "action" => "publish",
        "source_id" => "abc",
        "site_id" => "s",
        "user_id" => nil,
        "inserted_at" => DateTime.utc_now(),
        "payload" => %{"name" => "Home"}
      }
    end

    assert Source.entry_from_row(row.(PageDraft)).resource_label == "Page Draft"
    assert Source.entry_from_row(row.(LayoutDraft)).resource_label == "Layout Draft"

    entry = Source.entry_from_row(row.(ErrorPageDraft))
    assert entry.resource_label == "Error Page Draft"

    assert entry.badge_label == "DRAFT" and entry.action == :publish and
             entry.message =~ "published"
  end

  # The bug this guards against: the draft branches referenced `archived_at` after the column was
  # dropped, so the UNION failed — and `Query.run/6` answers a failed query with an empty list, which
  # emptied the WHOLE log. Every source, silently, with the page reading "No matching events".
  #
  # Asserting "drafts appear" is not enough to catch it, because a merged log with a broken branch
  # returns nothing at all rather than nothing-for-drafts. This pins the mechanism instead: the SQL
  # runs against the REAL schema, and a log that has content cannot be empty.
  test "the draft branches run against the real schema — a broken one would empty the whole log" do
    site = create_site!()

    PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Schema", title: "Schema", path: "/schema", template: "<h1>s</h1>"},
      tenant: site.id
    )
    |> Ash.create!(authorize?: false)

    # Each severity slice interpolates the action expression differently — `info` is the only one
    # that interpolates it a SECOND time, inside `content_severity_clause/2` — so each is a separate
    # chance for the SQL to name a column that is not there.
    #
    # Asserting the result `is_list/1` would be worthless: `Query.page/1` answers `[]` for a genuine
    # no-rows read AND for a swallowed failure, so `is_list` is true on precisely the breakage this
    # test exists to catch. What separates the two is the log line `run/6` now emits, so that is what
    # is asserted — it holds even for a severity that legitimately matches nothing.
    for severity <- [nil, "info", "warn", "error"] do
      logged =
        capture_log(fn ->
          assert is_list(Query.page(%{site_id: site.id, severity: severity, limit: 50}))
          assert is_integer(Query.counts(%{site_id: site.id, severity: severity}).total)
        end)

      refute logged =~ "[Activity.Query]",
             "severity #{inspect(severity)} made a branch fail: #{logged}"
    end

    assert Query.page(%{site_id: site.id, limit: 50}) != [],
           "the unified log came back empty — a branch is failing and being swallowed"

    # The counts run the same UNION; they must agree with the list rather than silently reading zero.
    assert Query.counts(%{site_id: site.id}).total > 0

    # A draft is never a warning: it is reachable only while it exists, and it exists only while it
    # has not been discarded. If this ever returns a draft, the destroy arm has come back.
    refute %{site_id: site.id, severity: "warn", limit: 50}
           |> Query.page()
           |> Enum.any?(&(&1.badge_label == "DRAFT"))
  end

  test "Query.page (unified activity log) includes page, layout AND error-page drafts" do
    site = create_site!()

    PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{name: "P Merged", title: "P Merged", path: "/pm", template: "<h1>p</h1>"},
      tenant: site.id
    )
    |> Ash.create!(authorize?: false)

    LayoutDraft
    |> Ash.Changeset.for_create(
      :master_create,
      %{
        name: "L Merged",
        path: "/lm",
        template: "<body>{@inner_content}</body>",
        site_id: site.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    ErrorPageDraft
    |> Ash.Changeset.for_create(
      :master_create,
      %{
        name: "E Merged",
        path: "/em",
        error_pages: [%{status: 404, template: "<h1>x</h1>"}],
        site_id: site.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    labels =
      %{site_id: site.id, limit: 100}
      |> Query.page()
      |> Enum.map(& &1.resource_label)
      |> Enum.uniq()

    assert "Page Draft" in labels
    assert "Layout Draft" in labels
    assert "Error Page Draft" in labels
  end

  # A draft moving IS the content being created, updated or destroyed, so it carries the same content
  # tone a paper-trailed save does and the timeline tints it the same way. A publish is not one of
  # those three words, so it has none and falls back to severity — which is the documented behaviour.
  describe "the content tone" do
    test "an update carries :updated, a destroy :destroyed, a publish none" do
      for {action, expected} <- [{"update", :updated}, {"destroy", :destroyed}, {"publish", nil}] do
        row = %{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => action,
          "source_id" => "d1",
          "site_id" => "s1",
          "user_id" => nil,
          "inserted_at" => ~U[2026-01-01 00:00:00Z],
          "payload" => %{"name" => "Home"}
        }

        assert Source.entry_from_row(row).tone == expected
      end
    end
  end
end
