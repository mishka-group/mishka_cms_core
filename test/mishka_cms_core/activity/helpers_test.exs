defmodule MishkaCmsCore.Activity.HelpersTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Helpers

  describe "severity_for/1" do
    for action <- [:destroy, :master_destroy, :permanent_destroy, :master_permanent_destroy] do
      test "#{inspect(action)} → :warn" do
        assert Helpers.severity_for(unquote(action)) == :warn
      end
    end

    for action <- [:create, :master_create, :update, :master_update, :unarchive] do
      test "#{inspect(action)} → :info" do
        assert Helpers.severity_for(unquote(action)) == :info
      end
    end

    test "unknown action falls back to :info" do
      assert Helpers.severity_for(:something_new) == :info
    end
  end

  describe "humanize_module/1" do
    test "single-word module" do
      assert Helpers.humanize_module(MishkaCmsCore.Runtime.Page) == "Page"
    end

    test "compound module splits on capitals" do
      assert Helpers.humanize_module(MishkaCmsCore.Runtime.MediaCategory) == "Media Category"
      assert Helpers.humanize_module(MishkaCmsCore.Runtime.ErrorPage) == "Error Page"
    end
  end

  describe "paper_trail_badge/1" do
    for action <- [:create, :master_create] do
      test "#{inspect(action)} → CREATE/:emerald" do
        assert Helpers.paper_trail_badge(unquote(action)) == {"CREATE", :emerald}
      end
    end

    for action <- [:update, :master_update] do
      test "#{inspect(action)} → UPDATE/:sky" do
        assert Helpers.paper_trail_badge(unquote(action)) == {"UPDATE", :sky}
      end
    end

    for action <- [:destroy, :master_destroy] do
      test "#{inspect(action)} → ARCHIVE/:amber" do
        assert Helpers.paper_trail_badge(unquote(action)) == {"ARCHIVE", :amber}
      end
    end

    for action <- [:permanent_destroy, :master_permanent_destroy] do
      test "#{inspect(action)} → PURGE/:rose" do
        assert Helpers.paper_trail_badge(unquote(action)) == {"PURGE", :rose}
      end
    end

    for action <- [:unarchive, :master_unarchive] do
      test "#{inspect(action)} → RESTORE/:emerald" do
        assert Helpers.paper_trail_badge(unquote(action)) == {"RESTORE", :emerald}
      end
    end

    test ":restore_version → REVERT/:indigo" do
      assert Helpers.paper_trail_badge(:restore_version) == {"REVERT", :indigo}
    end

    test "unknown action → upcased atom name with :slate fallback" do
      assert Helpers.paper_trail_badge(:custom_thing) == {"CUSTOM_THING", :slate}
    end
  end

  describe "visible_to?/2 — live-feed site scoping" do
    @site_a "11111111-1111-1111-1111-111111111111"
    @site_b "22222222-2222-2222-2222-222222222222"

    test "master (no site_id) sees every site, including global" do
      master = %{site_id: nil}
      assert Helpers.visible_to?(@site_a, master)
      assert Helpers.visible_to?(@site_b, master)
      assert Helpers.visible_to?(nil, master)
    end

    test "tenant sees its own site but never another tenant's site" do
      tenant = %{site_id: @site_a}
      assert Helpers.visible_to?(@site_a, tenant)
      refute Helpers.visible_to?(@site_b, tenant)
    end

    test "tenant does NOT see global (nil) entries on the live feed (own-site-scoped)" do
      # The realtime feed is subscription-scoped to a tenant's own site; the
      # "own + global" rule for shared runtime resources lives on the bulk DB read.
      refute Helpers.visible_to?(nil, %{site_id: @site_a})
    end

    # A MASTER IS A USER WHOSE `site_id` IS NIL, never the absence of one: no viewer, or a viewer
    # with no site on record, sees nothing on the live feed.
    test "no viewer / missing site_id key → sees nothing" do
      refute Helpers.visible_to?(@site_a, nil)
      refute Helpers.visible_to?(@site_a, %{})
      refute Helpers.visible_to?(nil, nil)
      refute Helpers.visible_to?(nil, %{id: "someone"})
    end
  end

  describe "action_icon/1" do
    test "content actions map to distinct heroicons" do
      assert Helpers.action_icon(:create) == "hero-plus-circle"
      assert Helpers.action_icon(:update) == "hero-pencil-square"
      assert Helpers.action_icon(:destroy) == "hero-archive-box"
      assert Helpers.action_icon(:permanent_destroy) == "hero-trash"
      assert Helpers.action_icon(:restore_version) == "hero-clock"
    end

    test "oban outcomes and unknowns have icons too" do
      assert Helpers.action_icon(:completed) == "hero-check-circle"
      assert Helpers.action_icon(:exception) == "hero-x-circle"
      assert Helpers.action_icon(:anything_else) == "hero-bolt"
    end
  end

  describe "initials/1 and avatar_tone/1" do
    test "initials takes up to two uppercase letters" do
      assert Helpers.initials("John Doe") == "JD"
      assert Helpers.initials("alice") == "A"
      assert Helpers.initials("") == "?"
      assert Helpers.initials(nil) == "?"
    end

    test "avatar_tone is deterministic for the same seed" do
      assert Helpers.avatar_tone("user-1") == Helpers.avatar_tone("user-1")
      assert is_atom(Helpers.avatar_tone("user-1"))
    end
  end
end
