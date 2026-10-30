# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.EventsTest do
  @moduledoc """
  The builder's plugin surface: ten registries, the lifecycle announcements, the node transform
  seams and the save/publish gates.

  The gates matter most. A `builder:save:before` hook that cannot actually stop a write would be
  decoration, and the whole point of putting content lint and link checking there is that a refusal
  is binding. That is asserted end to end against the live editor in the `builder_live/` tests of
  `mishka_cms_builder`; here the contract itself is pinned down.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Builder.Descriptor
  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Runtime.Authoring.Icons.Bundled
  alias MishkaCmsCore.Test.Plugins.BuilderSaveGatePlugin
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarInvokedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  defp register!(plugin, event) do
    {:ok, _} =
      Event.write(%{
        name: plugin,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp seed(key, priority) do
    {:ok, descriptor} =
      Descriptor.builder(%{
        key: key,
        kind: :rail_tab,
        label: String.upcase(key),
        priority: priority
      })

    descriptor
  end

  describe "the registry contract" do
    test "every registry the builder documents is declared" do
      declared = Map.keys(Events.registries())

      for registry <- ~w(components blocks elements inspector_sections rails studio_tabs
                         canvas_toolbar commands audit_checks page_starters icon_libraries
                         interactions js_hooks mention_sources)a do
        assert registry in declared
      end
    end

    test "each registry names an event and the payload key it accumulates under" do
      for {_registry, {event, key}} <- Events.registries() do
        assert String.starts_with?(event, "builder:")
        assert is_atom(key)
      end
    end

    # Seeded with core and never `[]` — the `sidebar:menus` convention. With no plugin registered a
    # collect must hand back exactly the seed.
    test "collecting with no plugin returns the seed untouched" do
      seed = [seed("layers", 10), seed("audit", 30)]

      assert Events.collect(:rails, seed) |> Enum.map(& &1.key) == ["layers", "audit"]
    end

    test "entries come back ordered by priority then key" do
      seed = [seed("z", 10), seed("a", 90), seed("m", 10)]

      assert Events.collect(:rails, seed) |> Enum.map(& &1.key) == ["m", "z", "a"]
    end

    test "a duplicate key keeps the first declaration" do
      seed = [seed("layers", 10), seed("layers", 20)]
      collected = Events.collect(:rails, seed)

      assert length(collected) == 1
      assert hd(collected).priority == 10
    end

    test "an unknown registry raises rather than silently returning nothing" do
      assert_raise FunctionClauseError, fn -> Events.collect(:not_a_registry, []) end
    end
  end

  describe "fetch/3" do
    # `entry_id/1` answers a bare module with itself, because the icon libraries ARE modules. Nothing
    # resolves those by id, and an entry of that shape must stay inert rather than reach a caller
    # that will read `:template` off it.
    test "an entry that is not a map is not an answer" do
      assert Events.fetch(:icon_libraries, [Bundled], Bundled) == nil
    end

    test "an unknown registry raises rather than silently answering nil" do
      assert_raise FunctionClauseError, fn -> Events.fetch(:not_a_registry, [], "x") end
    end
  end

  describe "transform/2 and gate/2" do
    test "with no plugin, a transform returns its payload unchanged" do
      payload = %{heex: "<div></div>", meta: %{}}
      assert Events.transform("builder:serialize", payload) == payload
    end

    test "with no plugin, a gate allows" do
      assert Events.before_save(%{tree: nil, serialized: "<div></div>"}) == :ok
      assert Events.before_publish(%{tree: nil, serialized: "<div></div>"}) == :ok
    end

    test "serialize/2 returns the original string when nothing rewrites it" do
      assert Events.serialize("<p>hi</p>", %{}) == "<p>hi</p>"
    end

    test "announcements never raise and always return :ok" do
      assert Events.announce("builder:node:after_insert", %{op: :insert}) == :ok
      assert Events.after_save(%{record_id: "x", section: "page", stage: :draft}) == :ok
      assert Events.after_publish(%{record_id: "x", section: "page", stage: :published}) == :ok
    end

    test "session lifecycle announcements accept a session struct" do
      session = %{
        token: "t",
        section: "page",
        resource_id: "r",
        site_id: nil,
        actor_id: nil
      }

      assert Events.session_opened(session) == :ok
      assert Events.session_closed(session) == :ok
    end
  end

  describe "before_node/3 — the per-op transform seam" do
    test "returns the op unchanged when no plugin is listening" do
      op = %{kind: :delete, node_id: "nabcdefgh"}
      assert {:ok, ^op} = Events.before_node(:delete, op, %{actor: nil})
    end
  end

  describe "the save gate, with a plugin that refuses" do
    setup do
      register!(BuilderSaveGatePlugin, "builder:save:before")
      :ok
    end

    test "a clean template still passes the gate" do
      assert Events.before_save(%{tree: nil, serialized: "<div>fine</div>", section: "page"}) ==
               :ok
    end

    test "a plugin's refusal is returned as an error with its own message" do
      assert {:error, message} =
               Events.before_save(%{
                 tree: nil,
                 serialized: "<div>#{BuilderSaveGatePlugin.sentinel()}</div>",
                 section: "page"
               })

      assert message =~ "A plugin refused this save"
    end

    test "the publish gate is a SEPARATE event — a save hook must not block a publish" do
      assert Events.before_publish(%{
               tree: nil,
               serialized: "<div>#{BuilderSaveGatePlugin.sentinel()}</div>",
               section: "page"
             }) == :ok
    end
  end

  # A TOOLBAR DESCRIPTOR HAS NO `run`. `Descriptor.run` is read by `builder:interactions` alone, so
  # an entry in this registry could be drawn and pressed and still never reach the plugin that put
  # it there — the press fell through to "duplicate the selected element". The registry and the
  # announcement are two halves of one seam, so they are asserted together.
  describe "the canvas toolbar, with a plugin that contributes an action" do
    setup do
      register!(BuilderToolbarProbe, "builder:canvas:toolbar")
      register!(BuilderToolbarInvokedProbe, "builder:canvas:toolbar:invoked")

      Process.register(self(), BuilderToolbarInvokedProbe.waiter())
      :ok
    end

    test "the contributed action is collected beside the core's own" do
      keys =
        :canvas_toolbar
        |> Events.collect([%{key: "duplicate", priority: 10}, %{key: "delete", priority: 20}])
        |> Enum.map(&Descriptor.key/1)

      assert keys == ["duplicate", "delete", BuilderToolbarProbe.key()]
    end

    test "pressing it announces the key, the element and the session to the plugin" do
      assert Events.toolbar_invoked(%{
               action: BuilderToolbarProbe.key(),
               node_id: "nabcdefgh",
               token: "a-session-token"
             }) == :ok

      assert_receive {BuilderToolbarInvokedProbe,
                      %{action: "probe-toolbar", node_id: "nabcdefgh", token: "a-session-token"}}
    end
  end

  describe "an event whose plugins cannot run" do
    test "refuses what it could veto, and hands anything else back unchanged" do
      MishkaCmsCore.Test.EventCannotRun.stub!([
        "builder:save:before",
        "builder:containment",
        "builder:ai:before_ask",
        "builder:examples"
      ])

      assert {:error, saved} = Events.before_save(%{})
      assert saved =~ "not loaded"
      assert {:ok, false, placed} = Events.containment(true, %{})
      assert placed =~ "not loaded"
      assert {:error, _asked} = Events.before_ask(%{prompt: "Write a heading"})
      assert Events.examples([%{"label" => "One"}], %{}) == [%{"label" => "One"}]
    end
  end
end
