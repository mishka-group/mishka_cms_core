# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.PaperTrailTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Sources.PaperTrail
  alias MishkaCmsCore.Runtime

  @master_user %{site_id: nil}
  @tenant_user %{site_id: "a103bede-3c79-4f7b-9ece-ad9b391668d2"}
  @events ~w(created updated destroyed)
  @site_id "a103bede-3c79-4f7b-9ece-ad9b391668d2"

  describe "discovered_modules/0" do
    test "discovers every paper-trailed Runtime resource" do
      modules = PaperTrail.discovered_modules()

      assert Runtime.Page in modules
      assert Runtime.Layout in modules
      assert Runtime.Component in modules
      assert Runtime.ErrorPage in modules
      assert Runtime.JsHook in modules
      assert Runtime.Stylesheet in modules
      assert Runtime.Media in modules
      assert Runtime.MediaCategory in modules
    end

    test "does not include Site (no paper trail extension)" do
      refute Runtime.Site in PaperTrail.discovered_modules()
    end
  end

  describe "topics/1 — master" do
    test "produces one topic per (resource × event) without a site segment" do
      topics = PaperTrail.topics(%{current_user: @master_user})

      assert length(topics) == length(PaperTrail.discovered_modules()) * length(@events)
      assert "page:created" in topics
      assert "page:updated" in topics
      assert "page:destroyed" in topics
      assert "component:created" in topics
      assert "media_category:destroyed" in topics

      refute Enum.any?(topics, &String.contains?(&1, @site_id))
    end
  end

  describe "topics/1 — tenant" do
    test "every topic contains the user's site_id segment" do
      topics = PaperTrail.topics(%{current_user: @tenant_user})

      assert length(topics) == length(PaperTrail.discovered_modules()) * length(@events)
      assert "page:#{@site_id}:created" in topics
      assert "component:#{@site_id}:updated" in topics
      assert "media:#{@site_id}:destroyed" in topics

      refute "page:created" in topics
      assert Enum.all?(topics, &String.contains?(&1, @site_id))
    end
  end

  describe "topics/1 — no viewer" do
    test "no viewer, or one with no site on record, subscribes to nothing" do
      assert PaperTrail.topics(%{}) == []
      assert PaperTrail.topics(%{current_user: nil}) == []
      assert PaperTrail.topics(%{current_user: %{}, resources: [Runtime.Component]}) == []
    end
  end

  describe "topics/1 — resources scope" do
    test "restricts to listed resources only" do
      topics =
        PaperTrail.topics(%{current_user: @master_user, resources: [Runtime.Component]})

      assert length(topics) == length(@events)
      assert Enum.all?(topics, &String.starts_with?(&1, "component:"))
    end

    test "drops resources that are not paper-trailed" do
      topics =
        PaperTrail.topics(%{
          current_user: @master_user,
          resources: [Runtime.Component, Runtime.Site]
        })

      # Site has no paper trail → filtered out, only Component remains
      assert length(topics) == length(@events)
      assert Enum.all?(topics, &String.starts_with?(&1, "component:"))
    end

    test "falls back to all discovered when resources is nil or empty" do
      all = length(PaperTrail.discovered_modules()) * length(@events)
      assert length(PaperTrail.topics(%{current_user: @master_user, resources: nil})) == all
      assert length(PaperTrail.topics(%{current_user: @master_user, resources: []})) == all
    end
  end

  describe "handles?/1" do
    test "true for a Notification on a paper-trailed resource" do
      msg = broadcast(%Ash.Notifier.Notification{resource: Runtime.Page, data: %{}})
      assert PaperTrail.handles?(msg)
    end

    test "false for a Notification on Site (not paper-trailed)" do
      msg = broadcast(%Ash.Notifier.Notification{resource: Runtime.Site, data: %{}})
      refute PaperTrail.handles?(msg)
    end

    test "false for non-Ash payloads (Oban etc.)" do
      msg = broadcast(%{__oban__: true})
      refute PaperTrail.handles?(msg)
    end
  end

  describe "to_entry/1" do
    test "build entry with site_id from notification data and severity from action" do
      n = %Ash.Notifier.Notification{
        resource: Runtime.Page,
        action: %{name: :update},
        actor: %{id: "actor-1"},
        data: %{id: "rec-1", site_id: @site_id, name: "Home"}
      }

      entry = PaperTrail.to_entry(broadcast(n))

      assert entry.resource_label == "Page"
      assert entry.action == :update
      assert entry.severity == :info
      assert entry.badge_label == "UPDATE"
      assert entry.badge_tone == :sky
      assert entry.site_id == @site_id
      assert entry.user_id == "actor-1"
      assert entry.source_id == "rec-1"
      assert entry.message =~ "Page"
      assert entry.message =~ "Home"
      assert entry.message =~ "updated"
      assert is_binary(entry.id)
      assert %DateTime{} = entry.inserted_at
    end

    test "destroy maps to severity :warn and ARCHIVE/:amber badge" do
      n = %Ash.Notifier.Notification{
        resource: Runtime.Component,
        action: %{name: :master_destroy},
        actor: nil,
        data: %{id: "x", site_id: nil}
      }

      entry = PaperTrail.to_entry(broadcast(n))
      assert entry.severity == :warn
      assert entry.badge_label == "ARCHIVE"
      assert entry.badge_tone == :amber
    end

    test "handles missing actor (system action)" do
      n = %Ash.Notifier.Notification{
        resource: Runtime.JsHook,
        action: %{name: :create},
        actor: nil,
        data: %{id: "x", site_id: nil}
      }

      entry = PaperTrail.to_entry(broadcast(n))
      assert entry.user_id == nil
      assert entry.site_id == nil
    end

    test "returns nil for non-matching broadcast" do
      assert PaperTrail.to_entry(broadcast(%{__oban__: true})) == nil
    end
  end

  defp broadcast(payload) do
    %Phoenix.Socket.Broadcast{topic: "test", event: "test", payload: payload}
  end
end
