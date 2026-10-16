# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.OpenThatTest do
  @moduledoc """
  A button that opens the dialog next to it — the half of reports 16 and 17 that is about the
  published page rather than the canvas.

  A developer writes `phx-click={show_modal("id")}` and thinks nothing of it. An author in the
  dashboard could not say it at all: `Interactions` compiled its six verbs against the element's OWN
  scope class, on purpose — *"`to:` is always the element's own scope, so an interaction can never
  reach something the author did not mean"* — so a button could show and hide itself and nothing
  beside it. With fourteen kit components rendering their own content closed, "open that" was not an
  expressible sentence.

  It is a target, not a new mechanism. The same `JS` command, the same `to:`, the same scope class
  `Tree.ensure_scope/2` mints and `ElementCss` keys a rule on — pointed at another node the document
  already contains.

  The assertions here are at the two levels that matter, because the canvas is not one of them:
  `CanvasLive` deliberately never emits a node's own `phx-*` bindings (they would fight its own
  selection binding), so what a button does is only observable in the DOCUMENT and on the page
  rendered from it.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @moduletag :unit

  defp open_session do
    {:ok, session} =
      EditorSession.open(%{
        section: "page",
        template: ~s(<div id="root"><button>Open</button><dialog id="d">Hello</dialog></div>)
      })

    session
  end

  defp id(session, tag), do: Enum.find(Tree.walk(session.tree), &(&1.tag == tag)).id

  # What `BuilderLive.handle_event("save_interaction", …)` does, in the order it does it: mint a
  # scope on the element being clicked, mint one on the TARGET, then write the command.
  defp aim(session, from, to, action) do
    {tree, scope} = Tree.ensure_scope(session.tree, from)
    {tree, target} = Tree.ensure_scope(tree, to)
    source = Interactions.source(action, scope, %{target: target})

    {:ok, tree} =
      Tree.set_attr(tree, from, "phx-click", {:expr, source})

    {tree, scope, target}
  end

  describe "a click aimed at another element" do
    test "writes a command naming the target's scope, not its own" do
      session = open_session()
      button = id(session, "button")
      dialog = id(session, "dialog")

      {tree, own, target} = aim(session, button, dialog, "show")

      assert own != target, "the two elements must not share a scope"

      assert Node.attr(Tree.get(tree, button), "phx-click") ==
               {:expr, ~s|JS.show(to: ".#{target}")|}

      # AND THE TARGET HAS TO BE FINDABLE. A command pointing at a class nothing carries is a click
      # that does nothing, silently — which is what an author would have got if the scope were minted
      # on the button and not on the dialog.
      assert Tree.get(tree, dialog) |> Node.attr_text("class") =~ target
    end

    test "the document round-trips it — the panel reads back what it wrote" do
      session = open_session()
      button = id(session, "button")
      dialog = id(session, "dialog")

      {tree, _own, target} = aim(session, button, dialog, "show")
      written = Node.attr(Tree.get(tree, button), "phx-click")

      assert Interactions.read(written) == {:ok, "show", %{}}
      assert Interactions.target(written) == target
    end

    # THE PAGE IS WHERE IT HAS TO WORK. The canvas never renders a node's own `phx-click`, so this is
    # the first place the command is real: LiveView serializes it into the attribute, and what lands
    # in the browser is a `show` pointed at the dialog's class.
    test "and renders on the page as a real command pointed at the dialog" do
      session = open_session()
      button = id(session, "button")
      dialog = id(session, "dialog")

      {tree, _own, target} = aim(session, button, dialog, "show")
      html = LiveViewCompiler.render_template(Serializer.serialize(tree), %{})

      assert is_binary(html), "the page did not render: #{inspect(html)}"
      assert html =~ "phx-click", "the button lost its command:\n#{html}"
      assert html =~ "show", "the command is not a show:\n#{html}"

      assert html =~ ".#{target}",
             "the command does not point at the dialog's scope:\n#{html}"
    end

    # EVERY ACTION THAT LANDS ON AN ELEMENT. "Show a message" acts on the page rather than on a
    # target — see `MishkaCmsCore.Runtime.PageMessage` — so there is no scope for it to point at.
    test "every action can be aimed, and every one of them renders" do
      for {action, _label} <- Interactions.actions(), not Interactions.server?(action) do
        session = open_session()
        button = id(session, "button")
        dialog = id(session, "dialog")

        {tree, scope} = Tree.ensure_scope(session.tree, button)
        {tree, target} = Tree.ensure_scope(tree, dialog)
        source = Interactions.source(action, scope, %{class: "is-open", target: target})
        {:ok, tree} = Tree.set_attr(tree, button, "phx-click", {:expr, source})

        html = LiveViewCompiler.render_template(Serializer.serialize(tree), %{})

        assert is_binary(html), "#{action} did not render: #{inspect(html)}"
        assert html =~ ".#{target}", "#{action} lost its target:\n#{html}"
      end
    end
  end

  # AN INTERACTION WITH NO TARGET IS THE ONE EVERY EXISTING DOCUMENT HAS. Adding a fourth argument
  # that changed what three arguments mean would rewrite every one of them on its next save.
  describe "an interaction on the element itself" do
    test "still points at that element and nothing else" do
      session = open_session()
      button = id(session, "button")

      {tree, scope} = Tree.ensure_scope(session.tree, button)
      source = Interactions.source("toggle_class", scope, %{class: "is-open"})

      assert source == ~s|JS.toggle_class("is-open", to: ".#{scope}")|
      assert Interactions.target({:expr, source}) == scope

      {:ok, tree} = Tree.set_attr(tree, button, "phx-click", {:expr, source})
      html = LiveViewCompiler.render_template(Serializer.serialize(tree), %{})

      assert is_binary(html)
      assert html =~ ".#{scope}"
    end
  end

  # THE HANDLE HAS TO SURVIVE THE AUTHOR EDITING THE THING IT IS ON.
  #
  # The scope class is the whole of the link between a button and the dialog it opens, and it lives
  # in the target's `class` attribute — where the inspector shows it, alone, in the author's own
  # class box, reading like eight characters of junk. Typing over it took the aim with it and said
  # nothing: the button kept a `phx-click` pointing at a class no element carried any more.
  #
  # `delete_attr/3` has guarded this since the class was first minted; `set_attr/4`, the writer the
  # box actually uses, did not.
  describe "the scope class and the author's class box" do
    test "typing in the box does not take the scope with it" do
      session = open_session()
      dialog = id(session, "dialog")

      {tree, scope} = Tree.ensure_scope(session.tree, dialog)
      {:ok, tree} = Tree.set_attr(tree, dialog, "class", {:string, "shadow-2xl"})

      assert Tree.scope(tree, dialog) == scope
      assert Tree.get(tree, dialog) |> Node.attr_text("class") =~ "shadow-2xl"
    end

    test "a button aimed at it still points at something that exists" do
      session = open_session()
      button = id(session, "button")
      dialog = id(session, "dialog")

      {tree, _own, target} = aim(session, button, dialog, "show")
      {:ok, tree} = Tree.set_attr(tree, dialog, "class", {:string, "rounded-xl"})

      assert Interactions.target(Node.attr(Tree.get(tree, button), "phx-click")) == target

      assert Tree.get(tree, dialog) |> Node.attr_text("class") =~ target,
             "the dialog no longer carries the class the button names"
    end

    # THE ELEMENT'S OWN CSS IS KEYED ON THE SAME CLASS, so this is one guard for two features — and
    # the reason it is unconditional rather than "only while something names it": what names it can
    # be a different node entirely, or a CSS rule that does not live in this tree at all.
    test "and clearing the box is still the author's to do" do
      session = open_session()
      dialog = id(session, "dialog")

      {tree, scope} = Tree.ensure_scope(session.tree, dialog)
      {:ok, tree} = Tree.set_attr(tree, dialog, "class", {:string, ""})

      assert Tree.scope(tree, dialog) == scope

      tree = Tree.drop_scope(tree, dialog)
      refute Tree.scope(tree, dialog)
    end

    test "an edit to any other attribute leaves the class alone" do
      session = open_session()
      dialog = id(session, "dialog")

      {tree, scope} = Tree.ensure_scope(session.tree, dialog)
      before = Tree.get(tree, dialog) |> Node.attr_text("class")
      {:ok, tree} = Tree.set_attr(tree, dialog, "title", {:string, "Hello"})

      assert Tree.scope(tree, dialog) == scope
      assert Tree.get(tree, dialog) |> Node.attr_text("class") == before
    end
  end
end
