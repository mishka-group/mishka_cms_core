# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.EditorSessionRetryTest do
  @moduledoc """
  A change that lost its compare-and-swap, asked again.

  A session change is worked out once more on the session another write left, so two things have
  to hold for that to be safe: whatever must happen once — the broadcast, the plugin announcement —
  happens after the swap, and whatever is worked out from the document is worked out inside it.

  The `builder:node:before_*` seam is asked between a change's read and its write, so a plugin there
  lands the other write at exactly that moment, on the first try only.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Test.Plugins.BuilderNodeLanding
  alias MishkaCmsCore.Test.Plugins.BuilderNodeProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :unit

  setup do
    for {plugin, event} <- [
          {BuilderNodeLanding, "builder:node:before_set_text"},
          {BuilderNodeProbe, "builder:node:after_set_text"}
        ] do
      {:ok, _} =
        Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

      :ok = EventHandler.do_compile(event, :start, false)
      on_exit(fn -> Event.unregister(:name, plugin, false) end)
    end

    {:ok, session} =
      EditorSession.open(%{
        section: "page",
        template: ~s(<div id="root"><p>hello world</p></div>)
      })

    on_exit(fn -> EditorSession.close(session.token) end)

    %{session: session, text: Enum.find(Tree.walk(session.tree), &(&1.kind == :text))}
  end

  defp set_text(token, node, text) do
    {:ok, _session} =
      EditorSession.apply_op(token, %{kind: :set_text, node_id: node.id, text: text})
  end

  defp stored_text(token, node) do
    {:ok, session} = EditorSession.fetch(token)
    Tree.get(session.tree, node.id).text
  end

  describe "an op tried again" do
    test "is announced once, to the page and to plugins", %{session: session, text: text} do
      token = session.token
      :ok = EditorSession.subscribe(token)
      BuilderNodeLanding.land(fn -> {:ok, _} = EditorSession.set_preview(token, true) end)

      set_text(token, text, "hello there")

      assert_received {BuilderNodeLanding, :asked}
      assert_received {BuilderNodeLanding, :asked}, "the op was not tried again"

      assert_received {:builder_session, ^token, {:op_applied, :set_text}}
      refute_received {:builder_session, ^token, {:op_applied, :set_text}}
      assert_received {:builder_session, ^token, {:preview, true}}

      assert_received {BuilderNodeProbe, %{token: ^token}}
      refute_received {BuilderNodeProbe, _summary}

      assert {:ok, %{preview?: true}} = EditorSession.fetch(token)
      assert stored_text(token, text) == "hello there"
    end
  end

  # FIND AND REPLACE WRITES A NODE'S WHOLE TEXT, worked out from the text it had. A word typed into
  # that node while the replace was being worked out is in the text it is worked out from.
  describe "a replace tried again" do
    test "keeps what was typed in between", %{session: session, text: text} do
      token = session.token
      BuilderNodeLanding.land(fn -> set_text(token, text, "hello world, typed") end)

      assert {:ok, _session} = EditorSession.replace_text(token, "hello", "goodbye")

      assert stored_text(token, text) == "goodbye world, typed", "the typing was replaced"
    end
  end
end
