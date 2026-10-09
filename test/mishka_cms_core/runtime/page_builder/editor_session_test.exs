defmodule MishkaCmsCore.Runtime.PageBuilder.EditorSessionTest do
  @moduledoc """
  The editing session: the mutation funnel, the undo history, the clipboard, locks and the
  breakpoint cascade.

  These are the behaviours the React editor advertised and never delivered — its history provider
  watched a store nothing wrote to, so undo, redo and all thirteen shortcuts were inert. Every one
  of them is asserted here against real state.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Test.Factory

  # The real Chelekom rows the two-form page below is built from. The bundle is 12 MB, read once.
  setup_all do
    {:ok,
     chelekom:
       Factory.chelekom_rows(
         ~w(chelekom-card chelekom-text-field chelekom-email-field chelekom-form-wrapper chelekom-button)
       )}
  end

  defp open(template \\ ~s(<div id="root"><p>hello</p></div>), attrs \\ %{}) do
    {:ok, session} =
      EditorSession.open(Map.merge(%{section: "page", template: template}, attrs))

    session
  end

  defp find(session, tag), do: Enum.find(Tree.walk(session.tree), &(&1.tag == tag))
  defp html(session), do: Serializer.serialize(session.tree)
  defp parent_of(session, id), do: Tree.get(session.tree, id).parent_id

  # THE SAME DOCUMENT, THROUGH HEEx AND BACK — which is exactly what a revert does, and the reason
  # every node id in the session is stale afterwards.
  defp reparsed(session), do: session.tree |> Serializer.serialize() |> Tree.parse!()

  describe "open/1" do
    test "parses the template and stores the session" do
      session = open()

      assert session.section == "page"
      assert Tree.size(session.tree) > 0
      assert {:ok, ^session} = EditorSession.fetch(session.token)
    end

    test "mints a token matching the canvas URL format" do
      assert open().token =~ ~r/^[a-z0-9]{32}$/
    end

    test "starts clean, at the base breakpoint and state" do
      session = open()

      assert session.breakpoint == :base
      assert session.pseudo == :base
      refute session.dirty?
      assert session.past == []
      assert session.future == []
    end

    test "an unparseable template is reported, not raised" do
      assert {:error, %{message: message}} =
               EditorSession.open(%{section: "page", template: "<div><span></div>"})

      assert message =~ "closing tag"
    end

    test "an unknown section is refused" do
      assert {:error, _errors} =
               EditorSession.open(%{section: "spreadsheet", template: "<div></div>"})
    end

    test "an empty template opens an empty document" do
      session = open("")
      assert session.tree.roots == []
    end

    # MARKUP THAT WAS ALREADY SAVED WEARING TWO NAMES. Paste styles carried the source element's
    # minted class until it was stopped at the copy, so every document an author used it in still
    # holds the target wearing the source's name FIRST — which is the one `Tree.scope/2` answers
    # with, so the CSS box still shows the source's rule and the next save still prunes the
    # target's own away. Stopping the paste does nothing for the documents that already have it.
    test "an element wearing a name that is not its own is left with its own" do
      session =
        open(
          ~s(<div id="root"><p class="lede pb-aaaaaaaa">one</p><span class="note pb-aaaaaaaa pb-bbbbbbbb">two</span></div>)
        )

      rules = %{"pb-aaaaaaaa" => "color: red;", "pb-bbbbbbbb" => "color: blue;"}

      assert Tree.scope(session.tree, find(session, "span").id) == "pb-bbbbbbbb"
      assert Tree.scope(session.tree, find(session, "p").id) == "pb-aaaaaaaa"
      assert html(session) =~ ~s(<span class="note pb-bbbbbbbb">two</span>)
      assert ElementCss.live_rules(session.tree, rules) == rules
    end

    # AND A NAME SITS IN AN EXPRESSION AS READILY AS IN A STRING, since that is where one goes when
    # the author's class is computed. Taking the wrong one off has to leave the expression standing:
    # rebuilding the attribute from the classes read out of it writes the literal text `@variant`
    # onto the element, which costs the author a computed class to fix a name.
    test "an element wearing two names in an expression keeps its own and keeps the expression" do
      session =
        open(
          ~s(<div id="root"><p class={[@variant, "pb-aaaaaaaa"]}>one</p><span class={[@variant, "pb-aaaaaaaa", "pb-bbbbbbbb"]}>two</span></div>)
        )

      assert Tree.scope(session.tree, find(session, "span").id) == "pb-bbbbbbbb"
      assert Tree.scope(session.tree, find(session, "p").id) == "pb-aaaaaaaa"
      assert html(session) =~ ~s(<span class={[@variant, "pb-bbbbbbbb"]}>two</span>)
    end

    # AND NOT WHERE THE MARKUP NO LONGER SAYS WHICH NAME WAS WHOSE. Duplicating an element that had
    # been pasted onto leaves two of them wearing the same pair, and neither name is on one element
    # alone — so taking either off is a guess, and the guess that goes wrong deletes a rule.
    test "an element whose own name cannot be told apart is left alone" do
      session =
        open(
          ~s(<div id="root"><p class="pb-aaaaaaaa pb-bbbbbbbb">one</p><span class="pb-aaaaaaaa pb-bbbbbbbb">two</span></div>)
        )

      assert html(session) =~ ~s(<p class="pb-aaaaaaaa pb-bbbbbbbb">one</p>)
      assert html(session) =~ ~s(<span class="pb-aaaaaaaa pb-bbbbbbbb">two</span>)
    end

    test "close/1 drops the session" do
      session = open()
      assert :ok = EditorSession.close(session.token)
      assert :error = EditorSession.fetch(session.token)
    end
  end

  describe "apply_op/3 — the funnel" do
    test "inserts a parsed template at a parent" do
      session = open()
      root = find(session, "div")

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{
                 "kind" => "insert",
                 "template" => ~s(<span>new</span>),
                 "parent_id" => root.id,
                 "index" => "1"
               })

      assert html(session) == ~s(<div id="root"><p>hello</p><span>new</span></div>)
    end

    test "an inserted node becomes the selection" do
      session = open()
      root = find(session, "div")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :insert,
          template: ~s(<span>new</span>),
          parent_id: root.id
        })

      assert Tree.get(session.tree, session.selection).tag == "span"
    end

    test "inserts at the document root when the parent is \"root\"" do
      session = open()

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :insert,
          template: ~s(<footer></footer>),
          parent_id: "root",
          index: 1
        })

      assert html(session) == ~s(<div id="root"><p>hello</p></div><footer></footer>)
    end

    test "an inserted subtree gets fresh ids and never collides" do
      session = open()
      root = find(session, "div")
      before = MapSet.new(Map.keys(session.tree.nodes))

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :insert,
          template: ~s(<span>new</span>),
          parent_id: root.id
        })

      assert MapSet.subset?(before, MapSet.new(Map.keys(session.tree.nodes)))
    end

    test "moves a node" do
      session = open(~s(<div><a-one></a-one><b-two></b-two></div>))
      a = find(session, "a-one")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :move,
          node_id: a.id,
          parent_id: "root",
          index: 0
        })

      assert html(session) == ~s(<a-one></a-one><div><b-two></b-two></div>)
    end

    test "deletes a node and everything under it" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})
      assert html(session) == ~s(<div id="root"></div>)
    end

    test "sets a string, expression and boolean attribute" do
      session = open()
      p = find(session, "p")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "class",
          value: "lead"
        })

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "title",
          value: "@t",
          value_kind: "expr"
        })

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "hidden",
          value_kind: "boolean"
        })

      assert html(session) == ~s(<div id="root"><p class="lead" title={@t} hidden>hello</p></div>)
    end

    # An attribute that holds an expression goes on holding one. Every property control in the
    # inspector shows an expression's SOURCE — `@icon` for `name={@icon}` — and posts that source
    # back as an ordinary value, so with no kind stated the write landed as `name="@icon"`: a string
    # literal that looks identical in the panel and is no longer bound to anything. A component that
    # nests another component is made of exactly these bindings, so editing any property of an inner
    # component quietly cut it off from the attribute it was passing down.
    test "an attribute that holds an expression keeps holding one" do
      session = open()
      p = find(session, "p")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "title",
          value: "@icon",
          value_kind: "expr"
        })

      # The inspector posts the source back with no kind, which is what every plain control does.
      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "title",
          value: "@other_icon"
        })

      assert html(session) =~ ~s(title={@other_icon})
      refute html(session) =~ ~s(title="@other_icon")
    end

    # And a stated kind still wins, which is how a literal stays reachable.
    test "unless the write says which kind it means" do
      session = open()
      p = find(session, "p")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "title",
          value: "@icon",
          value_kind: "expr"
        })

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "title",
          value: "plain words",
          value_kind: "string"
        })

      assert html(session) =~ ~s(title="plain words")
    end

    # An attribute that was never an expression is not turned into one by being edited.
    test "and a plain attribute stays plain" do
      session = open()
      p = find(session, "p")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "class",
          value: "lead"
        })

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: p.id,
          name: "class",
          value: "@lead"
        })

      assert html(session) =~ ~s(class="@lead")
    end

    test "sets text" do
      session = open()
      text = Enum.find(Tree.walk(session.tree), &(&1.kind == :text))

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_text,
          node_id: text.id,
          text: "goodbye"
        })

      assert html(session) == ~s(<div id="root"><p>goodbye</p></div>)
    end

    test "records a style override in the current write bucket" do
      session = open()
      p = find(session, "p")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_style,
          node_id: p.id,
          bucket: "tablet",
          prop: "padding",
          value: "14px"
        })

      assert Tree.get(session.tree, p.id).meta.styles == %{tablet: %{"padding" => "14px"}}
    end

    test "every mutation marks the session dirty" do
      session = open()
      p = find(session, "p")

      refute session.dirty?
      {:ok, session} = EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})
      assert session.dirty?
    end

    test "an unknown session is refused" do
      assert {:error, :unknown_session} =
               EditorSession.apply_op("nope", %{kind: :delete, node_id: "nabcdefgh"})
    end

    test "a malformed op is refused before any combinator runs" do
      session = open()

      assert {:error, _errors} = EditorSession.apply_op(session.token, %{kind: "explode"})
      assert {:error, _errors} = EditorSession.apply_op(session.token, %{kind: "move"})

      assert {:error, _errors} =
               EditorSession.apply_op(session.token, %{kind: "delete", node_id: "../etc"})

      {:ok, unchanged} = EditorSession.fetch(session.token)
      assert html(unchanged) == html(session)
    end
  end

  describe "apply_op/3 — containment is enforced server-side" do
    test "a block element cannot be inserted into a phrasing-only element" do
      session = open(~s(<span></span>))
      span = find(session, "span")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{
                 kind: :insert,
                 template: ~s(<div></div>),
                 parent_id: span.id
               })

      assert message =~ "text and inline"
    end

    test "a list refuses a non-item child even with a tampered payload" do
      session = open(~s(<ul></ul>))
      ul = find(session, "ul")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{
                 kind: :insert,
                 template: ~s(<div></div>),
                 parent_id: ul.id
               })

      assert message =~ "`<li>`"
      assert html(session) == ~s(<ul></ul>)
    end

    test "a move into a descendant is refused" do
      session = open(~s(<div id="outer"><section></section></div>))
      outer = find(session, "div")
      inner = find(session, "section")

      assert {:error, _message} =
               EditorSession.apply_op(session.token, %{
                 kind: :move,
                 node_id: outer.id,
                 parent_id: inner.id
               })
    end
  end

  describe "undo and redo" do
    setup do
      session = open()
      p = find(session, "p")
      {:ok, edited} = EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})
      %{session: edited, original: html(session)}
    end

    test "undo restores the previous tree", %{session: session, original: original} do
      assert {:ok, undone} = EditorSession.undo(session.token)
      assert html(undone) == original
    end

    test "redo re-applies it", %{session: session} do
      after_edit = html(session)
      {:ok, _undone} = EditorSession.undo(session.token)

      assert {:ok, redone} = EditorSession.redo(session.token)
      assert html(redone) == after_edit
    end

    # The rail these entries feed reads like a changelog, not a log file. Before this, an entry
    # carried only the op's own name and the node's generated id, and the sheet showed the likes of
    # "set_attr · nyauaklow" — true, and useless to the person who made the change.
    test "an entry says what was touched and how, in words" do
      session = open(~s(<div id="root"><p>hello</p></div>))
      p = find(session, "p")

      {:ok, styled} =
        EditorSession.apply_op(session.token, %{
          kind: :set_style,
          node_id: p.id,
          bucket: :base,
          prop: "py",
          value: "24px"
        })

      assert %{label: "Set py (base)", target: "<p>", detail: "py: 24px · base", note: nil} =
               hd(styled.past)
    end

    # A delete takes the subtree with it, which is the one consequence the line above it does not
    # state — so it is the one that earns the explanation box.
    test "deleting a parent says what went with it" do
      session = open(~s(<div id="root"><section><p>hello</p></section></div>))
      target = find(session, "section")

      {:ok, deleted} =
        EditorSession.apply_op(session.token, %{kind: :delete, node_id: target.id})

      assert %{label: "Deleted element", target: "<section>"} = hd(deleted.past)
      assert hd(deleted.past).note =~ "2 nested elements went with it"
    end

    # Typing a sentence is one history entry, and the entry has to quote the sentence — not the
    # first keystroke of it — while still undoing to the state before any of it.
    test "coalesced text edits keep the first tree and the last words" do
      session = open(~s(<div id="root"><p>hello</p></div>))
      text = Enum.find(Tree.walk(session.tree), &(&1.kind == :text))

      {:ok, once} =
        EditorSession.apply_op(session.token, %{kind: :set_text, node_id: text.id, text: "h"})

      {:ok, twice} =
        EditorSession.apply_op(once.token, %{kind: :set_text, node_id: text.id, text: "hi there"})

      assert length(twice.past) == 1
      assert hd(twice.past).detail == "“hi there”"

      assert {:ok, undone} = EditorSession.undo(twice.token)
      assert html(undone) == ~s(<div id="root"><p>hello</p></div>)
    end

    test "undo at the bottom is a no-op, not an error" do
      session = open()
      assert {:ok, same} = EditorSession.undo(session.token)
      assert same.past == []
    end

    test "redo at the top is a no-op, not an error", %{session: session} do
      assert {:ok, same} = EditorSession.redo(session.token)
      assert same.future == []
    end

    # Tabbing through the style panel blurs every field on the way past, and each blur arrives as a
    # `set_style` carrying the value that field already had. Recording those meant one real change
    # took several presses of undo to take back.
    test "an op that changes nothing is not recorded", %{session: session} do
      before = length(session.past)
      div = find(session, "div")

      {:ok, same} =
        EditorSession.apply_op(session.token, %{
          kind: :set_style,
          node_id: div.id,
          bucket: :base,
          prop: "gap",
          value: ""
        })

      assert length(same.past) == before
      assert same.dirty? == session.dirty?
    end

    test "re-setting a style to the value it already has is not recorded either" do
      session = open(~s(<div></div>))
      div = find(session, "div")
      style = %{kind: :set_style, node_id: div.id, bucket: :base, prop: "gap", value: "8px"}

      {:ok, once} = EditorSession.apply_op(session.token, style)
      {:ok, twice} = EditorSession.apply_op(once.token, style)

      assert length(twice.past) == length(once.past)
    end

    test "a no-op leaves an untouched session clean, so Save stays quiet" do
      session = open(~s(<div></div>))
      div = find(session, "div")
      refute session.dirty?

      {:ok, same} =
        EditorSession.apply_op(session.token, %{
          kind: :set_style,
          node_id: div.id,
          bucket: :base,
          prop: "gap",
          value: ""
        })

      refute same.dirty?
      assert same.past == []
    end

    test "a new edit truncates the redo stack", %{session: session} do
      {:ok, undone} = EditorSession.undo(session.token)
      assert undone.future != []

      p = find(undone, "p")
      {:ok, edited} = EditorSession.apply_op(undone.token, %{kind: :delete, node_id: p.id})

      assert edited.future == []
    end

    # NOT CAPPED AT A COUNT ANY MORE. Fifty steps is a few minutes' work, and the cap was also what
    # made the editor stop recording once it filled. Depth is bounded by memory now — see
    # `MishkaCmsCore.Runtime.States.EditorHistoryStateTest` for the budget itself, which needs a
    # table of its own to be deterministic about.
    test "the history keeps every step of a long sitting" do
      session = open(~s(<div></div>))
      div = find(session, "div")

      # SIXTY DIFFERENT ATTRIBUTES, not one attribute sixty times: consecutive writes to the same
      # field are one gesture and collapse into a single entry, which is what a drag should cost.
      session =
        Enum.reduce(1..60, session, fn n, acc ->
          {:ok, next} =
            EditorSession.apply_op(acc.token, %{
              kind: :set_attr,
              node_id: div.id,
              name: "data-n#{n}",
              value: to_string(n)
            })

          next
        end)

      assert length(session.past) == 60

      # And every one of them still reconstructs, which is the thing depth is for.
      oldest = List.last(session.past)
      assert {:ok, tree} = EditorSession.entry_tree(session, oldest)
      refute Tree.get(tree, div.id) |> Node.attr("data-n60")
    end

    test "consecutive text edits on one node coalesce into a single entry" do
      session = open()
      text = Enum.find(Tree.walk(session.tree), &(&1.kind == :text))

      session =
        Enum.reduce(["h", "he", "hel", "hell", "hello!"], session, fn value, acc ->
          {:ok, next} =
            EditorSession.apply_op(acc.token, %{kind: :set_text, node_id: text.id, text: value})

          next
        end)

      assert length(session.past) == 1
      assert {:ok, undone} = EditorSession.undo(session.token)
      assert html(undone) == ~s(<div id="root"><p>hello</p></div>)
    end

    test "text edits on different nodes do not coalesce" do
      session = open(~s(<p>a</p><p>b</p>))
      [first, second] = Enum.filter(Tree.walk(session.tree), &(&1.kind == :text))

      {:ok, session} =
        EditorSession.apply_op(session.token, %{kind: :set_text, node_id: first.id, text: "x"})

      {:ok, session} =
        EditorSession.apply_op(session.token, %{kind: :set_text, node_id: second.id, text: "y"})

      assert length(session.past) == 2
    end

    test "history_counter reports position and total", %{session: session} do
      assert EditorSession.history_counter(session) == {1, 1}

      {:ok, undone} = EditorSession.undo(session.token)
      assert EditorSession.history_counter(undone) == {0, 1}
    end

    test "undo clears a selection that no longer exists", %{session: session} do
      {:ok, undone} = EditorSession.undo(session.token)
      assert is_nil(undone.selection) or Tree.get(undone.tree, undone.selection)
    end
  end

  describe "clipboard" do
    test "copy holds a subtree and names it" do
      session = open()
      p = find(session, "p")

      assert {:ok, session} = EditorSession.copy(session.token, p.id)
      assert session.clipboard_label == "p"
      assert Serializer.serialize(session.clipboard) == "<p>hello</p>"
    end

    test "copy leaves the document alone" do
      session = open()
      p = find(session, "p")
      {:ok, copied} = EditorSession.copy(session.token, p.id)

      assert html(copied) == html(session)
    end

    test "cut removes the node and holds it" do
      session = open()
      p = find(session, "p")

      assert {:ok, session} = EditorSession.cut(session.token, p.id)
      assert html(session) == ~s(<div id="root"></div>)
      assert Serializer.serialize(session.clipboard) == "<p>hello</p>"
    end

    test "paste places the clipboard after the selection" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.copy(session.token, p.id)
      {:ok, session} = EditorSession.select(session.token, p.id)

      assert {:ok, session} = EditorSession.paste(session.token)
      assert html(session) == ~s(<div id="root"><p>hello</p><p>hello</p></div>)
    end

    test "paste into an explicit parent" do
      session = open()
      root = find(session, "div")
      p = find(session, "p")

      {:ok, session} = EditorSession.copy(session.token, p.id)

      assert {:ok, session} = EditorSession.paste(session.token, parent_id: root.id, index: 0)
      assert html(session) == ~s(<div id="root"><p>hello</p><p>hello</p></div>)
    end

    test "paste with an empty clipboard is refused with a message" do
      session = open()
      assert {:error, "Nothing to paste."} = EditorSession.paste(session.token)
    end

    test "a pasted subtree is independent of the original" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.copy(session.token, p.id)
      {:ok, session} = EditorSession.select(session.token, p.id)
      {:ok, session} = EditorSession.paste(session.token)

      pasted = session.tree |> Tree.walk() |> Enum.filter(&(&1.tag == "p"))
      assert length(pasted) == 2
      assert Enum.uniq(Enum.map(pasted, & &1.id)) |> length() == 2
    end
  end

  # ONE NAME PER FORM, WHICHEVER DOOR THE SECOND ONE CAME THROUGH. `Tree.duplicate/2` mints fresh
  # node ids and copies every attribute verbatim, so a copied form arrives answering to the
  # original's DOM id, param name, page assign and both event names — and two forms on one page
  # sharing a param name means one form's values land in the other's handler.
  describe "form names" do
    defp contact do
      open(
        ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"></.form></div>)
      )
    end

    defp form_names(session), do: session |> html() |> PageForms.declared() |> Enum.map(& &1.as)

    @form_block ~s(<section id="band"><.form :let={g} as={:signup} for={assigns[:signup_form]}><input name="email" /></.form></section>)

    defp copied(session) do
      form = find(session, ".form")
      {:ok, session} = EditorSession.copy(session.token, form.id)
      {:ok, session} = EditorSession.select(session.token, form.id)
      session
    end

    test "two pastes of one form are three forms with three names" do
      session = copied(contact())

      {:ok, session} = EditorSession.paste(session.token)
      {:ok, session} = EditorSession.paste(session.token)

      assert form_names(session) == ~w(contact contact_2 contact_3)
    end

    test "and all five derived names move with the seed" do
      session = copied(contact())

      {:ok, session} = EditorSession.paste(session.token)

      assert [_first, copy] = PageForms.declared(html(session))
      assert copy.as == "contact_2"
      assert copy.assign == :contact_2_form
      assert copy.id == "contact_2-form"
      assert copy.change =~ ~r/^contact_2-[a-z2-7]{5}-validate$/
      assert copy.submit =~ ~r/^contact_2-[a-z2-7]{5}-submit$/
    end

    test "two pastes of one form give every copy its own token, and the original keeps none" do
      session = copied(contact())

      {:ok, session} = EditorSession.paste(session.token)
      {:ok, session} = EditorSession.paste(session.token)

      assert [original | copies] = PageForms.declared(html(session))
      assert original.submit == "contact_submit"

      tokens = Enum.map(copies, &Naming.token(&1.submit))

      assert length(tokens) == 2
      assert Enum.all?(tokens, &is_binary/1)
      assert Enum.uniq(tokens) == tokens

      for copy <- copies do
        assert Naming.same_form?(copy.change, copy.submit)
      end
    end

    test "a pasted tagged form never shares its original's token" do
      session =
        open(
          ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"></.form></div>)
        )
        |> copied()

      {:ok, session} = EditorSession.paste(session.token)

      assert [original, copy] = PageForms.declared(html(session))
      assert original.submit == "contact-k7m2q-submit"
      refute Naming.token(copy.submit) in [nil, "k7m2q"]
    end

    test "a form from a template gets a token when it lands" do
      session = open(~s(<div id="root"></div>))
      root = find(session, "div")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :insert,
          template:
            ~s(<.form :let={f} id="signup-form" as={:signup} for={assigns[:signup_form]} phx-change="signup_validate" phx-submit="signup_submit"></.form>),
          parent_id: root.id,
          index: 0
        })

      assert [form] = PageForms.declared(html(session))
      assert form.submit =~ ~r/^signup-[a-z2-7]{5}-submit$/
      assert form.as == "signup"
    end

    # THE MARKUP PANE'S APPLY is a delete and an insert of the same subtree (`replace_node`), so a
    # pre-token form deep in it arrives again with the names its saved handler answers to.
    test "rewriting an ancestor's markup keeps a pre-token form's untagged names" do
      form =
        ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /></.form>)

      session =
        open(~s(<div id="root"><div class="card"><div class="grid">#{form}</div></div></div>))

      card = Enum.find(Tree.walk(session.tree), &(Node.attr_text(&1, "class") == "card"))

      {:ok, session} =
        EditorSession.apply_ops(
          session.token,
          [
            %{kind: :delete, node_id: card.id},
            %{
              kind: :insert,
              template: ~s(<div class="card shadow"><div class="grid">#{form}</div></div>),
              parent_id: card.parent_id,
              index: 0
            }
          ],
          "Rewrote a card"
        )

      assert [rewritten] = PageForms.declared(html(session))
      assert rewritten.change == "contact_validate"
      assert rewritten.submit == "contact_submit"
    end

    test "a whole document sharing a token is retokened when it arrives" do
      session = open(~s(<div id="root"></div>))

      tree =
        Tree.parse!(
          ~s(<.form as={:a} for={assigns[:a_form]} phx-submit="a-k7m2q-submit"></.form><.form as={:b} for={assigns[:b_form]} phx-submit="b-k7m2q-submit"></.form>)
        )

      {:ok, replaced} = EditorSession.put_tree(session.token, tree)

      assert [a, b] = PageForms.declared(html(replaced))
      assert a.submit == "a-k7m2q-submit"
      assert b.submit =~ ~r/^b-[a-z2-7]{5}-submit$/
      refute b.submit == "b-k7m2q-submit"
    end

    test "a whole document of untagged forms keeps its names" do
      session = open(~s(<div id="root"></div>))

      tree =
        Tree.parse!(
          ~s(<.form as={:a} for={assigns[:a_form]} phx-submit="a_submit"></.form><.form as={:b} for={assigns[:b_form]} phx-submit="b_submit"></.form>)
        )

      {:ok, replaced} = EditorSession.put_tree(session.token, tree)

      assert Enum.map(PageForms.declared(html(replaced)), & &1.submit) == ~w(a_submit b_submit)
    end

    # A FORM BLOCK OPENS WITH A BAND TAG BY DESIGN, so what the containment rules were handed by a
    # drag was a `<section>` and the `<.form>` inside it was invisible: the block landed in the form
    # the author was pointing at, browsers dropped the inner one, and everything after it stopped
    # submitting — reported by the audit rail afterwards instead of refused at the drop.
    test "a block that brings its own form is refused inside a form" do
      session = contact()
      form = find(session, ".form")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{
                 "kind" => "insert",
                 "template" => @form_block,
                 "parent_id" => form.id,
                 "index" => "0"
               })

      assert message =~ "inside another form"
      assert form_names(session) == ~w(contact)
    end

    test "and lands beside it where there is no form to nest in" do
      session = contact()
      root = find(session, "div")
      contact_form = find(session, ".form")

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{
                 "kind" => "insert",
                 "template" => @form_block,
                 "parent_id" => root.id,
                 "index" => "1"
               })

      assert form_names(session) == ~w(contact signup)

      signup = Enum.find(Tree.walk(session.tree), &(PageForms.param_name(&1) == "signup"))
      above = session.tree |> Tree.ancestors(signup.id) |> Enum.map(& &1.id)

      refute contact_form.id in above
    end

    test "duplicating a form renames the copy, not the original" do
      session = contact()
      form = find(session, ".form")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{kind: :duplicate, node_id: form.id})

      assert form_names(session) == ~w(contact contact_2)
    end

    test "a run of ops is renumbered as it goes, not once at the end" do
      session = open(~s(<div id="root"></div>))
      root = find(session, "div")
      form = ~s(<.form :let={f} as={:signup} for={assigns[:signup_form]}></.form>)

      {:ok, session} =
        EditorSession.apply_ops(
          session.token,
          [
            %{kind: :insert, template: form, parent_id: root.id, index: 0},
            %{kind: :insert, template: form, parent_id: root.id, index: 1}
          ],
          "two forms"
        )

      assert form_names(session) == ~w(signup signup_2)
    end

    test "a whole document arriving at once is renumbered too" do
      session = open(~s(<div id="root"></div>))

      tree =
        Tree.parse!(
          ~s(<.form as={:a} for={assigns[:a_form]}></.form><.form as={:a} for={assigns[:a_form]}></.form>)
        )

      {:ok, replaced} = EditorSession.put_tree(session.token, tree)

      assert form_names(replaced) == ~w(a a_2)
    end

    test "a page with one form is left exactly as it was" do
      session = contact()
      form = find(session, ".form")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :insert,
          template: "<h2>Title</h2>",
          parent_id: form.id,
          index: 0
        })

      assert form_names(session) == ~w(contact)
      assert html(session) =~ ~s(id="contact-form")
    end

    # THE ARRIVAL LOSES THE RACE, NOT THE PAGE. Renumbering in document order renamed whichever form
    # came first, so dropping a second Contact form ABOVE the first rewrote the one already on the
    # page — its param name, its page assign and both event names — and the `contact_submit` clause
    # the author had already written on the Events tab was left bound to nothing.
    test "a form arriving above an existing one is the one that gets renumbered" do
      session = contact()
      root = find(session, "div")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :insert,
          template:
            ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"></.form>),
          parent_id: root.id,
          index: 0
        })

      assert form_names(session) == ~w(contact_2 contact)

      assert [_arrival, incumbent] = PageForms.declared(html(session))
      assert incumbent.submit == "contact_submit"
      assert incumbent.assign == :contact_form
      assert incumbent.id == "contact-form"
    end

    test "pasting a form above the original renames the paste" do
      session = copied(contact())
      root = find(session, "div")

      {:ok, session} = EditorSession.paste(session.token, parent_id: root.id, index: 0)

      assert form_names(session) == ~w(contact_2 contact)
    end
  end

  # ONE KEY PER FIELD, WHICHEVER DOOR THE SECOND ONE CAME THROUGH. `Tree.duplicate/2` copies every
  # attribute verbatim, so a duplicated field arrives bound to the key the original already owns —
  # several inputs writing into one key, where the visitor's later value silently overwrites the
  # earlier and the spec carries a single field.
  describe "field keys" do
    defp bound_form(field \\ ~s(<input name={f[:email].name} value={f[:email].value} />)) do
      open(
        ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit">#{field}</.form></div>)
      )
    end

    defp field_keys(session) do
      session
      |> html()
      |> PageForms.declared()
      |> Enum.flat_map(fn spec -> Enum.map(spec.fields, & &1.key) end)
    end

    test "duplicating a field gives the copy a key of its own" do
      session = bound_form()
      input = find(session, "input")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{kind: :duplicate, node_id: input.id})

      assert field_keys(session) == [:email, :email_2]
    end

    test "duplicating three times fills the family rather than repeating it" do
      session = bound_form()

      session =
        Enum.reduce(1..3, session, fn _copy, session ->
          input = find(session, "input")

          {:ok, session} =
            EditorSession.apply_op(session.token, %{kind: :duplicate, node_id: input.id})

          session
        end)

      assert Enum.sort(field_keys(session)) == [:email, :email_2, :email_3, :email_4]
    end

    # A LABEL AND ITS INPUT ARE ONE FIELD. Both carry the key, and a copy that re-keyed only the
    # input would leave the label pointing at a field that no longer exists.
    test "a duplicated pair sharing one key is re-keyed together" do
      session =
        bound_form(
          ~s(<div><label for={f[:email].id}>Email</label><input name={f[:email].name} value={f[:email].value} /></div>)
        )

      {:ok, session} =
        EditorSession.apply_op(session.token, %{kind: :duplicate, node_id: wrapper_id(session)})

      assert field_keys(session) == [:email, :email_2]
      assert html(session) =~ ~s(<label for={f[:email_2].id}>)
    end

    defp wrapper_id(session) do
      session.tree
      |> Tree.walk()
      |> Enum.find(&(&1.tag == "div" and Node.attr_text(&1, "id") != "root"))
      |> Map.get(:id)
    end

    # THE WHOLE GESTURE, THROUGH THE FUNNEL: dropping a Checkbox into a form binds both of its
    # controls to one key, and duplicating it gives the copy a key of its own rather than a second
    # tick writing over the first.
    test "a checkbox dropped into a form is one boolean field, and its duplicate is another" do
      session = open(Elements.get("el-form").template)
      field = find(session, ".input")

      {:relocated, session, "Added it to Form 1."} =
        EditorSession.place_template(
          session.token,
          Elements.get("el-checkbox").template,
          field.id
        )

      assert [%{fields: fields}] = PageForms.declared(html(session))
      assert Enum.map(fields, &{&1.key, &1.type}) == [{:field, :string}, {:agree, :boolean}]
      refute html(session) =~ ~s(name="agree")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :duplicate,
          node_id: find(session, "label").id
        })

      assert [%{fields: fields}] = PageForms.declared(html(session))
      assert Enum.map(fields, & &1.key) == [:field, :agree, :agree_2]
    end

    # DUPLICATING A WHOLE FORM IS NOT A KEY COLLISION. Each form scopes its own params, so the copy
    # keeps every key it had and only the form's five names are renumbered.
    test "duplicating a whole form leaves both copies' keys alone" do
      session = bound_form()
      form = find(session, ".form")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{kind: :duplicate, node_id: form.id})

      assert form_names(session) == ~w(contact contact_2)
      assert field_keys(session) == [:email, :email]
    end
  end

  # STYLING FOUR CARDS TO MATCH is not the same gesture as duplicating one, so it gets its own
  # clipboard: copying a look to paste it must not throw away the subtree waiting to be pasted.
  describe "the styles clipboard" do
    defp styled do
      open(~s(<div id="root"><p class="text-sm text-red-500">hello</p><span>x</span></div>))
    end

    defp named do
      open(
        ~s(<div id="root"><p class="lede pb-aaaaaaaa">one</p><span class="note pb-bbbbbbbb">two</span></div>)
      )
    end

    test "copying a look takes the classes and leaves the words" do
      session = styled()
      p = find(session, "p")

      assert {:ok, session} = EditorSession.copy_styles(session.token, p.id)
      assert session.styles.class == {:string, "text-sm text-red-500"}
      assert session.styles_label == "p"
      assert html(session) =~ "hello"
    end

    test "it does not disturb the subtree clipboard" do
      session = styled()
      p = find(session, "p")

      {:ok, session} = EditorSession.copy(session.token, p.id)
      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "span").id)

      assert Serializer.serialize(session.clipboard) =~ "hello"
      assert session.styles_label == "span"
    end

    test "pasting puts the classes on another node" do
      session = styled()
      p = find(session, "p")
      span = find(session, "span")

      {:ok, session} = EditorSession.copy_styles(session.token, p.id)

      assert {:ok, session} = EditorSession.paste_styles(session.token, span.id)
      assert html(session) =~ ~s(<span class="text-sm text-red-500">x</span>)
      assert html(session) =~ ~s(<p class="text-sm text-red-500">hello</p>)
    end

    # A REPLACEMENT, NOT A MERGE. A target keeping a colour the source does not have ends up looking
    # like neither of them, which is the one outcome nobody can explain.
    test "the target's own classes go" do
      session = open(~s(<div id="root"><p class="a">one</p><span class="b">two</span></div>))

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.paste_styles(session.token, find(session, "span").id)

      refute html(session) =~ ~s(class="b")
      assert html(session) =~ ~s(<span class="a">two</span>)
    end

    # THE MINTED CLASS IS NOT PART OF A LOOK. `pb-xxxxxxxx` names ONE element to its own CSS rule
    # and is the `to:` of every interaction aimed at it, so a look carrying it keys two elements to
    # one rule with nothing in the UI saying so.
    test "a copied look leaves the element's own name behind" do
      session = named()

      assert {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      assert session.styles.class == {:string, "lede"}
    end

    # AND NOTHING ELSE THAT STARTS THE SAME WAY. Tailwind's padding-bottom utilities open with the
    # same two letters, and a look arriving without the author's spacing is a look nobody asked for.
    test "a class of the author's own that merely reads like one stays" do
      session = open(~s(<div id="root"><p class="pb-4 md:pb-8 pb-aaaaaaaa">one</p></div>))

      assert {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      assert session.styles.class == {:string, "pb-4 md:pb-8"}
    end

    test "pasting leaves the target wearing its own name, and the source wearing its" do
      session = named()

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)

      assert {:ok, session} =
               EditorSession.paste_styles(session.token, find(session, "span").id)

      assert Tree.scope(session.tree, find(session, "span").id) == "pb-bbbbbbbb"
      assert Tree.scope(session.tree, find(session, "p").id) == "pb-aaaaaaaa"
      assert html(session) =~ ~s(<span class="lede pb-bbbbbbbb">two</span>)
    end

    # WHAT THE NEXT SAVE DOES WITH IT. `live_rules/2` is what the save rewrites the stylesheet row
    # to hold, and it asks `Tree.scope/2`, which answers with the FIRST class it finds — so a target
    # wearing the source's name loses its own hand-written CSS to the next save. Asserted through
    # the save itself in the `builder_live/` tests; this is the same question without a database.
    test "and the hand-written CSS on both of them survives the save" do
      session = named()
      rules = %{"pb-aaaaaaaa" => "color: red;", "pb-bbbbbbbb" => "color: blue;"}

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.paste_styles(session.token, find(session, "span").id)

      assert ElementCss.live_rules(session.tree, rules) == rules
    end

    # A dozen ops for one gesture, and undo has to take the card back to how it looked rather than
    # unwinding it one property at a time.
    test "a paste is one undo step" do
      session = styled()
      before = html(session)

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.paste_styles(session.token, find(session, "span").id)
      refute html(session) == before

      assert {:ok, undone} = EditorSession.undo(session.token)
      assert html(undone) == before
    end

    test "pasting before anything was copied says so" do
      session = styled()

      assert {:error, "No styles copied yet."} =
               EditorSession.paste_styles(session.token, find(session, "span").id)
    end

    # `class={@variant}` and `class="p-4"` are different things, and flattening the first into the
    # literal string `@variant` is how a working component becomes a broken one.
    test "an expression class stays an expression" do
      session = open(~s(<div id="root"><p class={@variant}>a</p><span>b</span></div>))

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.paste_styles(session.token, find(session, "span").id)

      assert html(session) =~ ~s(<span class={@variant}>b</span>)
    end

    # AND THE TARGET'S OWN NAME JOINS IT. The minted class is the key the target's CSS rule is
    # written against, and the only way a writer that cannot read an expression had of keeping it was
    # to rebuild the attribute as a string: the paste left the element wearing its own name and no
    # look at all — the author's `note` gone with the `@variant` that was meant to replace it.
    test "an expression class pasted onto an element that has a name keeps both" do
      session =
        open(
          ~s(<div id="root"><p class={@variant}>one</p><span class="note pb-bbbbbbbb">two</span></div>)
        )

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.paste_styles(session.token, find(session, "span").id)

      assert html(session) =~ ~s(<span class={[@variant, "pb-bbbbbbbb"]}>two</span>)
      assert Tree.scope(session.tree, find(session, "span").id) == "pb-bbbbbbbb"

      assert ElementCss.live_rules(session.tree, %{"pb-bbbbbbbb" => "color: blue;"}) ==
               %{"pb-bbbbbbbb" => "color: blue;"}
    end

    # AND A NAME HIDES IN AN EXPRESSION TOO, now that minting one on `class={@variant}` splices it
    # into the list rather than flattening the author's value away. A look carrying it keys two
    # elements to one rule exactly as a string class did.
    test "a look copied off an expression class leaves the element's own name behind" do
      session =
        open(
          ~s(<div id="root"><p class={[@variant, "pb-aaaaaaaa"]}>one</p><span class="note pb-bbbbbbbb">two</span></div>)
        )

      assert {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      assert session.styles.class == {:expr, "[@variant]"}

      assert {:ok, session} = EditorSession.paste_styles(session.token, find(session, "span").id)

      assert html(session) =~ ~s(<span class={[@variant, "pb-bbbbbbbb"]}>two</span>)
      assert Tree.scope(session.tree, find(session, "span").id) == "pb-bbbbbbbb"
      assert Tree.scope(session.tree, find(session, "p").id) == "pb-aaaaaaaa"
    end

    # And an override on top of one JOINS it rather than replacing it: `class={@variant}` is a value
    # the component works out at render time, so writing utilities over it would swap a computed
    # class for the literal text `@variant`. HEEx flattens a list class, which is what makes this
    # legal.
    test "an override lands beside an expression class, not on top of it" do
      session = open(~s(<div id="root"><p class={@variant}>a</p><span>b</span></div>))
      p = find(session, "p")

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :set_style,
          node_id: p.id,
          bucket: :base,
          prop: "padding",
          value: "8"
        })

      assert html(session) =~ ~s(class={[@variant, ")
      assert html(session) =~ "@variant"
    end
  end

  # ONE SELECTION, PLUS THE ONES HELD WITH IT. `selection` stays exactly one element — it is what the
  # inspector edits and the toolbar names — so everything reading a single selection was left alone,
  # and only the handful of actions that mean "all of them" ask for the rest.
  describe "holding several elements" do
    defp row do
      open(~s(<div id="root"><p>one</p><span>two</span><b>three</b></div>))
    end

    test "the first ⌘-click selects, rather than holding nothing" do
      session = row()
      p = find(session, "p")

      assert {:ok, session} = EditorSession.mark(session.token, p.id)
      assert session.selection == p.id
      assert MapSet.size(session.marked) == 0
    end

    test "the next one is held beside it, and clicking it again lets go" do
      session = row()
      p = find(session, "p")
      span = find(session, "span")

      {:ok, session} = EditorSession.select(session.token, p.id)
      {:ok, session} = EditorSession.mark(session.token, span.id)

      assert EditorSession.chosen(session) == [p.id, span.id]

      {:ok, session} = EditorSession.mark(session.token, span.id)
      assert EditorSession.chosen(session) == [p.id]
    end

    # A PLAIN CLICK MEANS "THIS INSTEAD". Without this, holding three elements and then clicking a
    # fourth quietly acts on four.
    test "an ordinary click lets go of everything" do
      session = row()

      {:ok, session} = EditorSession.select(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "span").id)
      {:ok, session} = EditorSession.select(session.token, find(session, "b").id)

      assert EditorSession.chosen(session) == [find(session, "b").id]
    end

    # AN ID SET OUTLIVES THE NODE IT NAMES. Marks, locks and hidden flags are ids held BESIDE the
    # tree, and a delete takes the element out of the tree and out of nothing else — so the bulk bar
    # went on counting an element that was gone, and the action it offered ran against an id that
    # resolves to nothing. `put_tree/3` already re-homes these across a whole-document replacement;
    # a single op deserves the same care.
    test "a deleted element stops being held" do
      session = row()
      p = find(session, "p")
      span = find(session, "span")

      {:ok, session} = EditorSession.select(session.token, p.id)
      {:ok, session} = EditorSession.mark(session.token, span.id)
      assert EditorSession.chosen(session) == [p.id, span.id]

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{kind: :delete, node_id: span.id})

      assert EditorSession.chosen(session) == [p.id],
             "the bulk bar was still holding an element that is not in the document"

      refute MapSet.member?(session.marked, span.id)
    end

    test "and so does a deleted selection" do
      session = row()
      p = find(session, "p")

      {:ok, session} = EditorSession.select(session.token, p.id)

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})

      assert is_nil(session.selection),
             "the inspector was still pointed at an element that is not in the document"
    end

    test "a deleted element's lock and hidden flag go with it" do
      session = row()
      span = find(session, "span")

      {:ok, session} = EditorSession.toggle_lock(session.token, span.id)
      {:ok, session} = EditorSession.toggle_hidden(session.token, span.id)
      {:ok, session} = EditorSession.toggle_lock(session.token, span.id)

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{kind: :delete, node_id: span.id})

      refute MapSet.member?(session.hidden, span.id)
      assert MapSet.size(session.locked) == 0
    end

    # A DELETE TAKES ITS CHILDREN WITH IT, and the ids of those children are held the same way.
    test "and everything that was inside it" do
      session = open(~s(<div id="root"><section><p>one</p></section></div>))
      wrapper = find(session, "section")
      inner = find(session, "p")

      {:ok, session} = EditorSession.select(session.token, inner.id)
      {:ok, session} = EditorSession.mark(session.token, wrapper.id)

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{kind: :delete, node_id: wrapper.id})

      assert EditorSession.chosen(session) == []
    end

    # A RUN IS ONE CHANGE, and the same care applies: `apply_ops/4` read the selection off the session
    # as it was BEFORE the run, so a run that deleted the selected element put its id straight back.
    test "a run that deletes the selection does not put it back" do
      session = row()
      p = find(session, "p")
      span = find(session, "span")

      {:ok, session} = EditorSession.select(session.token, p.id)

      assert {:ok, session} =
               EditorSession.apply_ops(
                 session.token,
                 [
                   %{kind: :delete, node_id: p.id},
                   %{kind: :set_attr, node_id: span.id, name: "data-x", value: "1"}
                 ],
                 "Tidied up"
               )

      assert is_nil(session.selection)
      assert EditorSession.chosen(session) == []
    end

    test "delete takes them all, as one undo step" do
      session = row()
      before = html(session)

      {:ok, session} = EditorSession.select(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "span").id)

      assert {:ok, session} = EditorSession.bulk(session.token, "delete")
      assert html(session) == ~s(<div id="root"><b>three</b></div>)
      assert EditorSession.chosen(session) == []

      assert {:ok, undone} = EditorSession.undo(session.token)
      assert html(undone) == before
    end

    # HOLDING A CARD AND SOMETHING INSIDE IT. Deleting the card takes the child with it, and the run
    # would then halt on a node that is no longer there — leaving the rest of the selection alone.
    test "a child held with its parent does not break the run" do
      session = open(~s(<div id="root"><section><p>a</p></section><span>b</span></div>))

      {:ok, session} = EditorSession.select(session.token, find(session, "section").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "span").id)

      assert {:ok, session} = EditorSession.bulk(session.token, "delete")
      assert html(session) == ~s(<div id="root"></div>)
    end

    test "wrap puts them in one container, in the order they read" do
      session = row()

      {:ok, session} = EditorSession.select(session.token, find(session, "span").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "p").id)

      assert {:ok, session} = EditorSession.bulk(session.token, "wrap")

      assert html(session) ==
               ~s(<div id="root"><div><p>one</p><span>two</span></div><b>three</b></div>)
    end

    # THREE CARDS IN A ROW HAVE AN OBVIOUS CONTAINER; a heading here and a button two branches away
    # do not, and inventing one would move them somewhere neither of them was.
    test "wrap refuses elements that are not siblings" do
      session = open(~s(<div id="root"><section><p>a</p></section><span>b</span></div>))

      {:ok, session} = EditorSession.select(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "span").id)

      assert {:error, :not_siblings} = EditorSession.bulk(session.token, "wrap")
    end

    test "styles land on every one of them" do
      session = open(~s(<div id="root"><p class="a">one</p><span>two</span><b>three</b></div>))

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.select(session.token, find(session, "span").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "b").id)

      assert {:ok, session} = EditorSession.bulk(session.token, "paste_styles")
      assert html(session) =~ ~s(<span class="a">two</span>)
      assert html(session) =~ ~s(<b class="a">three</b>)
    end

    # AND EVERY ONE OF THEM KEEPS ITS OWN NAME. One paste keys one element to the source's CSS rule;
    # a bulk paste does it to the whole selection at once, and the save after that deletes every
    # rule they stopped naming.
    test "styles land without the source's own name on them" do
      session =
        open(
          ~s(<div id="root"><p class="a pb-aaaaaaaa">one</p><span class="b pb-bbbbbbbb">two</span><b class="c pb-cccccccc">three</b></div>)
        )

      rules = %{
        "pb-aaaaaaaa" => "color: red;",
        "pb-bbbbbbbb" => "color: blue;",
        "pb-cccccccc" => "color: green;"
      }

      {:ok, session} = EditorSession.copy_styles(session.token, find(session, "p").id)
      {:ok, session} = EditorSession.select(session.token, find(session, "span").id)
      {:ok, session} = EditorSession.mark(session.token, find(session, "b").id)

      assert {:ok, session} = EditorSession.bulk(session.token, "paste_styles")

      assert Tree.scope(session.tree, find(session, "span").id) == "pb-bbbbbbbb"
      assert Tree.scope(session.tree, find(session, "b").id) == "pb-cccccccc"
      assert ElementCss.live_rules(session.tree, rules) == rules
    end

    test "an empty selection says so instead of doing nothing" do
      assert {:error, "Nothing is selected."} = EditorSession.bulk(row().token, "delete")
    end
  end

  describe "context_action/3" do
    test "each entry does what its label says" do
      session = open()
      p = find(session, "p")

      assert {:ok, wrapped} = EditorSession.context_action(session.token, "wrap", p.id)
      assert html(wrapped) == ~s(<div id="root"><div><p>hello</p></div></div>)

      assert {:ok, unwrapped} =
               EditorSession.context_action(wrapped.token, "unwrap", parent_of(wrapped, p.id))

      assert html(unwrapped) == ~s(<div id="root"><p>hello</p></div>)
    end

    # PASTE AFTER THE NODE YOU POINTED AT. The keyboard follows the selection because that is all it
    # has; a right-click named a place, and putting the copy somewhere else is the bug.
    test "paste lands after the node the menu was opened on" do
      session = open(~s(<div id="root"><p>one</p><span>two</span></div>))
      p = find(session, "p")

      {:ok, session} = EditorSession.copy(session.token, p.id)
      {:ok, session} = EditorSession.select(session.token, find(session, "span").id)

      assert {:ok, session} = EditorSession.context_action(session.token, "paste", p.id)
      assert html(session) == ~s(<div id="root"><p>one</p><p>one</p><span>two</span></div>)
    end

    test "saving a snippet is a form, so it is handed back rather than applied" do
      session = open()
      assert {:open, :snippet} = EditorSession.context_action(session.token, "snippet", "n123")
    end

    test "a word the menu does not offer is refused" do
      session = open()
      p = find(session, "p")

      assert {:error, :unknown_action} =
               EditorSession.context_action(session.token, "drop_database", p.id)
    end

    test "a node that is no longer there is refused, not crashed through" do
      session = open()

      assert {:error, _reason} = EditorSession.context_action(session.token, "paste", "nzzzzzzzz")
    end
  end

  # WRAPPING AND UNWRAPPING MOVE ELEMENTS, and every other move in the editor is asked whether the
  # destination will have it. These two were not: `check_containment/2` named `:insert` and `:move`,
  # and a wrap is an insert plus a move written as one word. So the editor would put a `<div>` in a
  # `<ul>`, a block inside a `<span>`, or promote a `<td>` out of its row into a `<section>` — none
  # of which survive a browser's parser, and all of which are refused when the same movement is
  # spelled as a drag.
  describe "wrap and unwrap answer to the same content model as a drop" do
    test "a wrapper that cannot sit where the node sits is refused" do
      session = open(~s(<ul id="root"><li>one</li></ul>))
      item = find(session, "li")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{
                 kind: :wrap,
                 node_id: item.id,
                 tag: "div"
               })

      assert message =~ "can only contain"
    end

    test "a wrapper that cannot HOLD the node is refused too" do
      session = open(~s(<div id="root"><section><p>text</p></section></div>))
      block = find(session, "section")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{
                 kind: :wrap,
                 node_id: block.id,
                 tag: "span"
               })

      assert message =~ "text and inline"
    end

    test "a void tag is never a wrapper" do
      session = open()
      p = find(session, "p")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{kind: :wrap, node_id: p.id, tag: "img"})

      assert message =~ "cannot contain"
    end

    test "wrapping in a form inside a form is refused, as dragging one in would be" do
      session = open(~s(<form id="root"><div><p>text</p></div></form>))
      inner = find(session, "div")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{
                 kind: :wrap,
                 node_id: inner.id,
                 tag: "form"
               })

      assert message =~ "cannot go inside another form"
    end

    test "a legal wrap still goes through" do
      session = open()
      p = find(session, "p")

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{kind: :wrap, node_id: p.id, tag: "div"})

      assert html(session) =~ ~s(<div><p>hello</p></div>)
    end

    test "wrap_many asks the same of every element it collects" do
      session = open(~s(<ul id="root"><li>one</li><li>two</li></ul>))
      [first, second] = Enum.filter(Tree.walk(session.tree), &(&1.tag == "li"))

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{
                 kind: :wrap_many,
                 node_ids: [first.id, second.id],
                 tag: "div"
               })

      assert message =~ "can only contain"
    end

    test "and a legal wrap_many still goes through" do
      session = open(~s(<div id="root"><p>one</p><p>two</p></div>))
      [first, second] = Enum.filter(Tree.walk(session.tree), &(&1.tag == "p"))

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{
                 kind: :wrap_many,
                 node_ids: [first.id, second.id],
                 tag: "section"
               })

      assert html(session) =~ "<section><p>one</p><p>two</p></section>"
    end

    test "unwrap is refused when the promoted children may not live in the grandparent" do
      session = open(~s(<table id="root"><tr><td>cell</td></tr></table>))
      row = find(session, "tr")

      assert {:error, message} =
               EditorSession.apply_op(session.token, %{kind: :unwrap, node_id: row.id})

      assert message =~ "can only contain"
    end

    test "and a legal unwrap still goes through" do
      session = open(~s(<div id="root"><section><p>one</p></section></div>))
      wrapper = find(session, "section")

      assert {:ok, session} =
               EditorSession.apply_op(session.token, %{kind: :unwrap, node_id: wrapper.id})

      refute html(session) =~ "<section>"
      assert html(session) =~ "<p>one</p>"
    end
  end

  describe "locks and visibility" do
    test "a locked node refuses edits" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.toggle_lock(session.token, p.id)
      assert EditorSession.locked?(session, p.id)

      assert {:error, "That element is locked."} =
               EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})
    end

    test "a locked parent refuses a drop into it" do
      session = open()
      root = find(session, "div")

      {:ok, session} = EditorSession.toggle_lock(session.token, root.id)

      assert {:error, "That element is locked."} =
               EditorSession.apply_op(session.token, %{
                 kind: :insert,
                 template: "<span></span>",
                 parent_id: root.id
               })
    end

    # THE ONE OP THAT NAMES ITS TARGETS IN THE PLURAL. `authorize/2` reads `node_id`, and a
    # `:wrap_many` has none — it carries `node_ids` — so a locked element could be picked up by a
    # multi-select and boxed anyway. "Locked" has to mean the same thing however the element was
    # reached, or it means "cannot be dragged" and nothing more.
    test "a locked node refuses a wrap_many that includes it" do
      session = open(~s(<div id="root"><p>one</p><p>two</p></div>))
      [first, second] = Enum.filter(Tree.walk(session.tree), &(&1.tag == "p"))

      {:ok, session} = EditorSession.toggle_lock(session.token, second.id)

      assert {:error, "That element is locked."} =
               EditorSession.apply_op(session.token, %{
                 kind: :wrap_many,
                 node_ids: [first.id, second.id],
                 tag: "div"
               })
    end

    test "and refuses an unwrap of a locked container" do
      session = open(~s(<div id="root"><section><p>one</p></section></div>))
      wrapper = find(session, "section")

      {:ok, session} = EditorSession.toggle_lock(session.token, wrapper.id)

      assert {:error, "That element is locked."} =
               EditorSession.apply_op(session.token, %{kind: :unwrap, node_id: wrapper.id})
    end

    test "unlocking restores editing" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.toggle_lock(session.token, p.id)
      {:ok, session} = EditorSession.toggle_lock(session.token, p.id)

      refute EditorSession.locked?(session, p.id)

      assert {:ok, _session} =
               EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})
    end

    test "hidden is session state and never reaches the template" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.toggle_hidden(session.token, p.id)

      assert EditorSession.hidden?(session, p)
      assert html(session) == ~s(<div id="root"><p>hello</p></div>)
    end

    # A COMMENT RENDERS NOTHING ON THE LIVE PAGE, so the chip standing in for one starts folded and
    # the eye is what unfolds it. Same eye, same set: one flip away from whatever the kind defaults
    # to, which is why the set cannot be read as "these are the hidden ones".
    test "a comment starts folded and the eye unfolds it" do
      session = open(~s(<div><%!-- a note --%><p>hello</p></div>))
      note = Enum.find(Tree.walk(session.tree), &(&1.kind == :eex_comment))
      p = find(session, "p")

      assert EditorSession.hidden?(session, note)

      refute EditorSession.hidden?(session, p),
             "everything that is not a comment still starts drawn"

      {:ok, session} = EditorSession.toggle_hidden(session.token, note.id)
      refute EditorSession.hidden?(session, note)

      {:ok, session} = EditorSession.toggle_hidden(session.token, note.id)
      assert EditorSession.hidden?(session, note)
    end

    # A SNIPPET IS THE SAME GESTURE AS THE PALETTE. This path used to drop its template beside the
    # selection whatever it was, so a section snippet inserted while a heading inside a hero was
    # selected landed inside that hero — the bug the click rule exists to prevent, by another door.
    test "an unarmed template follows the band rule too" do
      session = open(~s(<section id="hero"><h1>Title</h1></section>))
      h1 = find(session, "h1")

      assert {:relocated, session, note} =
               EditorSession.place_template(
                 session.token,
                 ~s(<section id="new"></section>),
                 h1.id
               )

      hero = find(session, "section")
      assert hero.id != nil
      assert Enum.count(session.tree.roots) == 2
      assert note =~ "beside each other"

      assert Tree.get(session.tree, List.last(session.tree.roots)).tag == "section"
    end

    test "an unarmed leaf still goes inside what was selected" do
      session = open(~s(<section id="hero"><h1>Title</h1></section>))
      hero = find(session, "section")

      assert {:ok, session} =
               EditorSession.place_template(session.token, ~s(<p>New</p>), hero.id)

      assert session.tree |> Tree.get(hero.id) |> Map.fetch!(:children) |> length() == 2
    end

    # A SNIPPET, AN EXAMPLE AND A WIZARD'S COMPOSITION WERE ALL WRITTEN IN ANOTHER DOCUMENT, and a
    # `pb-` class is the key into THAT document's element CSS row — see
    # `MishkaCmsCore.Runtime.PageBuilder.ElementScopes`. Kept, the element arrives styled by a row
    # this document neither owns nor prunes, with an empty CSS box in front of the author. The class
    # is also the handle an interaction points at, so both have to move together.
    test "an unarmed template brings none of its old element classes with it" do
      session = open(~s(<section id="hero"><h1>Title</h1></section>))
      hero = find(session, "section")

      assert {:ok, session} =
               EditorSession.place_template(
                 session.token,
                 ~s(<p class="note pb-0a1b2c3d" data-target=".pb-0a1b2c3d">New</p>),
                 hero.id
               )

      markup = html(session)

      assert [minted] = ~r/pb-[a-f0-9]{8}/ |> Regex.scan(markup) |> List.flatten() |> Enum.uniq()
      refute minted == "pb-0a1b2c3d"
      assert markup =~ ~s(class="note #{minted}")
      assert markup =~ ~s(data-target=".#{minted}")
    end

    # THE BAD PATH. Folding is a view preference and must never become a deletion — whatever the eye
    # says, both notes are still in the tree and still come back out of the serializer.
    test "folding a comment never takes it out of the template" do
      source = ~s(<div><%!-- an editor note --%><!-- html note --><p>hello</p></div>)
      session = open(source)
      notes = Enum.filter(Tree.walk(session.tree), &Node.comment?/1)

      assert length(notes) == 2
      assert Enum.all?(notes, &EditorSession.hidden?(session, &1))
      assert html(session) == source

      {:ok, session} = EditorSession.toggle_hidden(session.token, hd(notes).id)

      assert html(session) == source
    end
  end

  # Review notes used to live on the session: a list in ETS, swept after a day idle. They are rows
  # now — `MishkaCmsCore.Runtime.PageComment` — so what used to be tested here is tested in
  # `test/mishka_cms_core/runtime/resources/page_comment_test.exs` instead. The session keeps no
  # copy: a second place holding the same thread is exactly what the move was for.
  test "the session holds no comments of its own" do
    session = open()

    refute Map.has_key?(session, :comments),
           "notes are rows now; a copy on the session would be a second comment system"

    refute function_exported?(EditorSession, :add_comment, 2)
    refute function_exported?(EditorSession, :resolve_comment, 2)
  end

  describe "view state" do
    test "selection and hover round-trip" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.select(session.token, p.id)
      assert session.selection == p.id

      {:ok, session} = EditorSession.hover(session.token, p.id)
      assert session.hover == p.id

      {:ok, session} = EditorSession.select(session.token, nil)
      assert is_nil(session.selection)
    end

    # THE BUCKET IS BOTH SELECTORS, not whichever one is not Normal. It used to be either — the
    # breakpoint while Normal was selected, the state otherwise — so a hover colour set with the
    # panel on Mobile was written to `:hover`, which is every width, and changed the desktop with
    # it. "On a phone, when touched" could not be said at all.
    test "the write bucket is the width and the state together" do
      session = open()

      assert EditorSession.write_bucket(session) == :base

      {:ok, session} = EditorSession.set_breakpoint(session.token, :mobile)
      assert EditorSession.write_bucket(session) == :mobile

      {:ok, session} = EditorSession.set_pseudo(session.token, :hover)
      assert EditorSession.write_bucket(session) == :mobile_hover

      {:ok, session} = EditorSession.set_breakpoint(session.token, :tablet)
      assert EditorSession.write_bucket(session) == :tablet_hover

      # A state at the widest breakpoint keeps its own name: `hover:` with no query already applies
      # at every width, which is what makes the common case cheap.
      {:ok, session} = EditorSession.set_breakpoint(session.token, :base)
      assert EditorSession.write_bucket(session) == :hover

      {:ok, session} = EditorSession.set_pseudo(session.token, :base)
      assert EditorSession.write_bucket(session) == :base
    end

    test "view changes do not touch the history" do
      session = open()
      p = find(session, "p")

      {:ok, session} = EditorSession.select(session.token, p.id)
      {:ok, session} = EditorSession.set_breakpoint(session.token, :tablet)
      {:ok, session} = EditorSession.hover(session.token, p.id)

      assert session.past == []
      refute session.dirty?
    end
  end

  describe "PubSub" do
    test "a mutation announces on the session topic" do
      session = open()
      p = find(session, "p")
      :ok = EditorSession.subscribe(session.token)

      {:ok, _session} = EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})

      token = session.token
      assert_receive {:builder_session, ^token, {:op_applied, :delete}}
    end

    test "selection announces too, so the canvas can follow the layers panel" do
      session = open()
      p = find(session, "p")
      :ok = EditorSession.subscribe(session.token)

      {:ok, _session} = EditorSession.select(session.token, p.id)

      token = session.token
      node_id = p.id
      assert_receive {:builder_session, ^token, {:selection, ^node_id, :panel}}
    end

    test "a silent write does not announce" do
      session = open()
      :ok = EditorSession.subscribe(session.token)

      {:ok, _session} = EditorSession.put_tree(session.token, session.tree, silent: true)

      refute_receive {:builder_session, _token, _message}, 50
    end
  end

  # WHAT AN ASSISTANT USES. `apply_op/3` is one change at a time — one ETS copy in and out, one
  # history snapshot, one broadcast, one re-render in every LiveView watching — which is right for a
  # person and wrong for anything writing a document. A run pays that once.
  describe "apply_ops/4" do
    defp section_id(session), do: find(session, "section").id

    defp inserts(session, count) do
      parent = section_id(session)

      for i <- 1..count,
          do: %{kind: :insert, parent_id: parent, index: i - 1, template: "<p>line #{i}</p>"}
    end

    test "applies every op and keeps one undo step for the run" do
      session = open(~s(<div id="root"><section></section></div>))

      assert {:ok, run} =
               EditorSession.apply_ops(session.token, inserts(session, 5), "Wrote five lines")

      assert Enum.count(Tree.walk(run.tree), &(&1.tag == "p")) == 5
      assert length(run.past) == 1
      assert hd(run.past).label == "Wrote five lines"
      assert run.dirty?
    end

    test "one undo takes the whole run back" do
      session = open(~s(<div id="root"><section></section></div>))
      before = html(session)

      {:ok, _run} = EditorSession.apply_ops(session.token, inserts(session, 4), "Wrote four")

      assert {:ok, undone} = EditorSession.undo(session.token)
      assert html(undone) == before
    end

    # A HALF-WRITTEN SECTION IS WORSE THAN A REFUSED ONE, so nothing is kept unless all of it applies.
    test "a bad op in the middle leaves the document untouched" do
      session = open(~s(<div id="root"><section></section></div>))
      before = html(session)
      parent = section_id(session)

      ops = [
        %{kind: :insert, parent_id: parent, index: 0, template: "<p>good</p>"},
        %{kind: :delete, node_id: "no-such-node"},
        %{kind: :insert, parent_id: parent, index: 1, template: "<p>never</p>"}
      ]

      assert {:error, _reason} = EditorSession.apply_ops(session.token, ops, "Half a section")

      {:ok, unchanged} = EditorSession.fetch(session.token)
      assert html(unchanged) == before
      assert unchanged.past == []
    end

    # Each op sees the tree the one before it produced: five inserts at index 0 must stack in order,
    # which is only true if each is applied against the result of the last rather than the original.
    test "each op is applied against what the one before it produced" do
      session = open(~s(<div id="root"><section></section></div>))
      parent = section_id(session)

      ops =
        for word <- ~w(one two three) do
          %{kind: :insert, parent_id: parent, index: 0, template: "<p>#{word}</p>"}
        end

      {:ok, run} = EditorSession.apply_ops(session.token, ops, "Three lines")

      assert html(run) =~ "<p>three</p><p>two</p><p>one</p>"
    end

    # A subtree arrives as ONE template, so a run does not need to address nodes it has just made.
    test "a whole nested subtree is one op inside the run" do
      session = open(~s(<div id="root"><section></section></div>))
      parent = section_id(session)

      {:ok, run} =
        EditorSession.apply_ops(
          session.token,
          [
            %{
              kind: :insert,
              parent_id: parent,
              index: 0,
              template: "<ul><li>one</li><li>two</li></ul>"
            },
            %{kind: :insert, parent_id: parent, index: 1, template: "<p>after</p>"}
          ],
          "Built a list"
        )

      assert Enum.count(Tree.walk(run.tree), &(&1.tag == "li")) == 2
      assert html(run) =~ "<p>after</p>"
    end

    test "the run is broadcast once, not once per op" do
      session = open(~s(<div id="root"><section></section></div>))
      EditorSession.subscribe(session.token)

      {:ok, _run} = EditorSession.apply_ops(session.token, inserts(session, 6), "Six at once")

      assert_receive {:builder_session, _token, {:op_applied, :run}}
      refute_receive {:builder_session, _token, {:op_applied, _other}}
    end
  end

  describe "save bookkeeping" do
    test "mark_saved clears dirty and stamps the time" do
      session = open()
      p = find(session, "p")
      {:ok, session} = EditorSession.apply_op(session.token, %{kind: :delete, node_id: p.id})

      assert {:ok, saved} = EditorSession.mark_saved(session.token, draft_id: "draft-1")

      refute saved.dirty?
      assert %DateTime{} = saved.saved_at
      assert saved.draft_id == "draft-1"
    end

    # A SAVE ANSWERS FOR THE DOCUMENT IT CARRIED, not for the one that arrived while it was away. The
    # editor hands a draft write to a task and hears back later; calling the session clean on the way
    # back reported an edit made in between as kept by a draft that does not contain it.
    test "mark_saved leaves a session dirty when it has moved past the revision that was written" do
      session = open(~s(<div id="root"><p>hello</p><span>there</span></div>))

      {:ok, written} =
        EditorSession.apply_op(session.token, %{kind: :delete, node_id: find(session, "p").id})

      {:ok, later} =
        EditorSession.apply_op(written.token, %{kind: :delete, node_id: find(written, "span").id})

      assert {:ok, saved} =
               EditorSession.mark_saved(later.token, draft_id: "draft-1", as_of: written.revision)

      assert saved.dirty?, "the edit that write could not carry is still unsaved work"
      assert saved.draft_id == "draft-1", "and the draft it really made is adopted all the same"

      assert {:ok, caught_up} = EditorSession.mark_saved(saved.token, as_of: saved.revision)
      refute caught_up.dirty?
    end

    test "put_tree replaces the document and is undoable" do
      session = open()
      replacement = Tree.parse!(~s(<article>fresh</article>))

      assert {:ok, replaced} = EditorSession.put_tree(session.token, replacement)
      assert html(replaced) == ~s(<article>fresh</article>)

      assert {:ok, undone} = EditorSession.undo(replaced.token)
      assert html(undone) == ~s(<div id="root"><p>hello</p></div>)
    end

    # REPLACING THE WHOLE DOCUMENT IS A CHANGE, and the timeline is written from `pending`. This
    # reached `past` — so it could be undone — without ever reaching `pending`, which meant a revert
    # left no trace of itself in the record of what happened.
    test "put_tree is recorded, not only undoable" do
      session = open()
      replacement = Tree.parse!(~s(<article>fresh</article>))

      {:ok, replaced} = EditorSession.put_tree(session.token, replacement, reason: :revert)

      assert {:ok, [entry]} = EditorSession.drain_pending(replaced.token)
      assert entry.kind == :restore
      assert entry.label == "Restored"
    end

    test "each kind of replacement says what it actually was" do
      for {reason, label} <- [
            {:revert, "Restored"},
            {:source_edit, "Edited the source"},
            {:page_starter, "Started from a layout"}
          ] do
        session = open()

        {:ok, replaced} =
          EditorSession.put_tree(session.token, Tree.parse!("<article>x</article>"),
            reason: reason
          )

        assert {:ok, [entry]} = EditorSession.drain_pending(replaced.token)
        assert entry.label == label
      end
    end

    # ONE DOCUMENT PER RUN OF TAPS, NOT ONE PER TAP. A step entry keeps a whole document rather than a
    # patch, because it has no version after it to be relative to — and it never enters `past` or
    # `future`, so nothing can ever drop it. Minting one per tap left documents nothing could reach,
    # charged to the session's budget for ever, and the trim answered by cutting the real history
    # down to a single step. Measured before the fix: 160 taps, 32 MB, four times the whole budget.
    test "a run of taps keeps one document, not one per tap" do
      session = open(~s(<div id="root"><p>a</p><p>b</p><p>c</p></div>))
      ids = session.tree |> Tree.walk() |> Enum.filter(&(&1.tag == "p")) |> Enum.map(& &1.id)

      session =
        Enum.reduce(ids, session, fn id, acc ->
          {:ok, next} =
            EditorSession.apply_op(acc.token, %{kind: :set_text, node_id: id, text: "x"})

          next
        end)

      assert kept_documents(session.token) == 0

      session =
        Enum.reduce(1..3, session, fn _tap, acc ->
          {:ok, next} = EditorSession.undo(acc.token)
          next
        end)

      assert kept_documents(session.token) == 1, "three taps kept more than one document"

      session =
        Enum.reduce(1..3, session, fn _tap, acc ->
          {:ok, next} = EditorSession.redo(acc.token)
          next
        end)

      assert kept_documents(session.token) == 1, "continuing the run kept another document"

      # And the history it is meant to protect is still all there.
      assert length(session.past) == length(ids)
    end

    # WHOLE DOCUMENTS, not patches. Counted straight off the table, because the leak this pins was
    # invisible from anywhere else: the rows it left could not be reached from `past` or `future`,
    # so nothing but the table itself could say they were there.
    defp kept_documents(token) do
      :mishka_builder_history
      |> :ets.select([{{{token, :"$1"}, {:tree, :_}, :_}, [{:is_reference, :"$1"}], [true]}])
      |> length()
    end

    # THE UNDO STACK SATURATES; THE COUNT MUST NOT. `past` is capped at fifty and every change empties
    # `future`, so a chrome asking "did anything move?" as `{length(past), length(future)}` was told
    # "no" from the fifty-first change of a sitting onward — and stopped autosaving and stopped
    # recording history for the rest of the afternoon.
    test "the revision keeps counting after the undo stack is full" do
      session = open(~s(<div id="root"><p>x</p></div>))
      id = find(session, "p").id

      session =
        Enum.reduce(1..60, session, fn n, acc ->
          {:ok, next} =
            EditorSession.apply_op(acc.token, %{
              kind: :set_attr,
              node_id: id,
              name: "data-n#{n}",
              value: to_string(n)
            })

          next
        end)

      assert length(session.past) == 60
      assert session.revision == 60

      {:ok, further} =
        EditorSession.apply_op(session.token, %{
          kind: :set_attr,
          node_id: id,
          name: "data-later",
          value: "1"
        })

      assert length(further.past) == 61
      assert further.revision == 61
    end

    test "every kind of movement counts, and nothing else does" do
      session = open(~s(<div id="root"><p>x</p></div>))
      id = find(session, "p").id
      assert session.revision == 0

      {:ok, edited} =
        EditorSession.apply_op(session.token, %{kind: :set_text, node_id: id, text: "y"})

      assert edited.revision == 1

      {:ok, run} =
        EditorSession.apply_ops(session.token, [%{kind: :duplicate, node_id: id}], "duplicate")

      assert run.revision == 2

      {:ok, undone} = EditorSession.undo(session.token)
      assert undone.revision == 3

      {:ok, redone} = EditorSession.redo(session.token)
      assert redone.revision == 4

      {:ok, replaced} =
        EditorSession.put_tree(session.token, Tree.parse!("<article>x</article>"),
          reason: :revert
        )

      assert replaced.revision == 5

      # Looking at something is not changing it.
      {:ok, selected} = EditorSession.select(session.token, hd(Tree.walk(replaced.tree)).id)
      assert selected.revision == 5

      {:ok, hovered} = EditorSession.hover(session.token, hd(Tree.walk(replaced.tree)).id)
      assert hovered.revision == 5

      {:ok, breakpoint} = EditorSession.set_breakpoint(session.token, :tablet)
      assert breakpoint.revision == 5
    end

    # A SNAPSHOT IS HEEx, and parsing it back mints new node ids — so the id the session was holding
    # names nothing, even though the element is still on screen. Everything keyed by node id used to
    # be dropped on every revert and every source edit: the selection, the marks, the locks and the
    # hidden flags.
    test "the selection follows the element across a replacement, under its new id" do
      session = open(~s(<div id="root"><h1>Title</h1><p>hello</p></div>))
      paragraph = find(session, "p")
      {:ok, session} = EditorSession.select(session.token, paragraph.id)

      {:ok, replaced} = EditorSession.put_tree(session.token, reparsed(session), reason: :revert)

      refute replaced.selection == paragraph.id, "the id did not change; this proves nothing"
      assert Tree.get(replaced.tree, replaced.selection).tag == "p"
    end

    test "the marks, the locks and the hidden flags follow it too" do
      session = open(~s(<div id="root"><h1>Title</h1><p>hello</p></div>))
      h1 = find(session, "h1")
      paragraph = find(session, "p")

      {:ok, _} = EditorSession.select(session.token, h1.id)
      {:ok, _} = EditorSession.mark(session.token, paragraph.id)
      {:ok, _} = EditorSession.toggle_lock(session.token, paragraph.id)
      {:ok, session} = EditorSession.toggle_hidden(session.token, h1.id)

      {:ok, replaced} = EditorSession.put_tree(session.token, reparsed(session), reason: :revert)

      assert [marked] = MapSet.to_list(replaced.marked)
      assert [locked] = MapSet.to_list(replaced.locked)
      assert [hidden] = MapSet.to_list(replaced.hidden)

      assert Tree.get(replaced.tree, marked).tag == "p"
      assert Tree.get(replaced.tree, locked).tag == "p"
      assert Tree.get(replaced.tree, hidden).tag == "h1"
    end

    # AN ADDRESS IS A POSITION, so a document that changed shape can have something else sitting
    # where the selection was. Handing that over silently is worse than handing over nothing.
    test "an element of a different kind at the same place is refused, not selected" do
      session = open(~s(<div id="root"><h1>Title</h1><p>hello</p></div>))
      {:ok, session} = EditorSession.select(session.token, find(session, "p").id)

      elsewhere = Tree.parse!(~s(<div id="root"><h1>Title</h1><section>other</section></div>))
      {:ok, replaced} = EditorSession.put_tree(session.token, elsewhere, reason: :revert)

      refute replaced.selection
    end

    # THE CASE THAT MATTERS MOST, because it is the one a position cannot see. Reverting to a
    # snapshot that had a sibling above the selection slides everything up one, so the old address
    # names the neighbour — in bounds, same kind, same tag. Handing the author's lock and hide to an
    # element they never touched is worse than handing them nothing.
    test "a same-tag sibling sitting at the old address is refused, not adopted" do
      session = open(~s(<div id="root"><p>B</p></div>))
      held = find(session, "p")

      {:ok, _} = EditorSession.select(session.token, held.id)
      {:ok, _} = EditorSession.toggle_lock(session.token, held.id)
      {:ok, session} = EditorSession.toggle_hidden(session.token, held.id)

      older = Tree.parse!(~s(<div id="root"><p>A</p><p>B</p></div>))
      {:ok, replaced} = EditorSession.put_tree(session.token, older, reason: :revert)

      refute replaced.selection
      assert MapSet.size(replaced.locked) == 0
      assert MapSet.size(replaced.hidden) == 0
    end

    test "a sibling removed above the selection is refused too" do
      session = open(~s(<ul><li>one</li><li>two</li><li>three</li></ul>))
      {:ok, session} = EditorSession.select(session.token, Enum.at(Tree.walk(session.tree), 2).id)

      shorter = Tree.parse!(~s(<ul><li>two</li><li>three</li></ul>))
      {:ok, replaced} = EditorSession.put_tree(session.token, shorter, reason: :source_edit)

      refute replaced.selection
    end

    # AND STILL CARRIES when only what is inside the elements changed, which is the whole point:
    # undoing a text or a style edit must not cost the author their place.
    test "a document whose shape is unchanged still carries" do
      session = open(~s(<div id="root"><h1>New title</h1><p>hello</p></div>))
      {:ok, session} = EditorSession.select(session.token, find(session, "h1").id)

      older = Tree.parse!(~s(<div id="root"><h1>Old title</h1><p>hello</p></div>))
      {:ok, replaced} = EditorSession.put_tree(session.token, older, reason: :revert)

      assert replaced.selection
      assert Tree.get(replaced.tree, replaced.selection).tag == "h1"
    end

    test "an element that is no longer in the document is dropped" do
      session = open(~s(<div id="root"><h1>Title</h1><p>hello</p></div>))
      {:ok, session} = EditorSession.select(session.token, find(session, "p").id)

      shorter = Tree.parse!(~s(<div id="root"><h1>Title</h1></div>))
      {:ok, replaced} = EditorSession.put_tree(session.token, shorter, reason: :revert)

      refute replaced.selection
    end

    test "a session with nothing selected stays that way" do
      session = open()

      {:ok, replaced} = EditorSession.put_tree(session.token, reparsed(session), reason: :revert)

      refute replaced.selection
      assert MapSet.size(replaced.marked) == 0
    end

    # Loading a draft INTO the editor is not a change to the document — it is how the document
    # arrives — and it is the only caller that says so.
    test "loading a document into the editor is not recorded" do
      session = open()

      {:ok, replaced} =
        EditorSession.put_tree(session.token, Tree.parse!(~s(<article>fresh</article>)),
          reason: :restore,
          dirty?: false
        )

      assert {:ok, []} = EditorSession.drain_pending(replaced.token)
    end
  end

  # FURNISHING IS A PLACEHOLDER, AND A PLACEHOLDER GOES WHEN THE REAL THING ARRIVES. A component
  # dropped empty is a blank strip nobody can identify, so the palette puts "Your content here"
  # inside it. Nothing took the words away when a real child landed, so a list dropped into a flex
  # sat BESIDE the sentence — reported as "it should remove the default text".
  describe "the furnishing a dropped component arrives with" do
    @furnished [
      %{
        name: "boxy",
        template: ~S|<div class="box">{render_slot(@inner_block)}</div>|,
        attrs: [],
        slots: [%{"name" => "inner_block"}]
      }
    ]

    defp furnished_session do
      open(
        ~s(<div id="root"><.component component_name="boxy" site="Global">Your content here</.component></div>),
        %{components: @furnished}
      )
    end

    defp box(session),
      do: Enum.find(Tree.walk(session.tree), &(&1.kind == :component))

    defp texts(session, parent) do
      parent.children
      |> Enum.map(&Tree.get(session.tree, &1))
      |> Enum.filter(&(&1 && &1.kind == :text))
      |> Enum.map(&String.trim(&1.text || ""))
      |> Enum.reject(&(&1 == ""))
    end

    test "goes when something real is dropped in" do
      session = furnished_session()
      parent = box(session)

      assert texts(session, parent) == ["Your content here"]

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          "kind" => "insert",
          "template" => ~s(<ul><li>one</li></ul>),
          "parent_id" => parent.id,
          "index" => "0"
        })

      assert texts(session, box(session)) == [],
             "the placeholder stayed beside the real content"

      assert html(session) =~ "<ul>"
    end

    # `:move` focuses the node that MOVED, so a fix keyed on what is focused skips this entirely —
    # and dragging something that is already on the page into a furnished box is half the report.
    test "and goes just the same when an existing node is dragged in" do
      session =
        open(
          ~s(<div id="root"><.component component_name="boxy" site="Global">Your content here</.component><span id="mover">x</span></div>),
          %{components: @furnished}
        )

      parent = box(session)
      mover = Enum.find(Tree.walk(session.tree), &(&1.tag == "span"))

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          kind: :move,
          node_id: mover.id,
          parent_id: parent.id,
          index: 0
        })

      assert texts(session, box(session)) == []
    end

    # WHAT THE AUTHOR WROTE IS NOT A PLACEHOLDER. Only the exact words the palette put there are
    # taken, and only while nothing else has been typed over them.
    test "but text the author changed is left alone" do
      session =
        open(
          ~s(<div id="root"><.component component_name="boxy" site="Global">My own words</.component></div>),
          %{components: @furnished}
        )

      parent = box(session)

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          "kind" => "insert",
          "template" => ~s(<ul><li>one</li></ul>),
          "parent_id" => parent.id,
          "index" => "0"
        })

      assert texts(session, box(session)) == ["My own words"]
    end

    test "and an empty box keeps its placeholder until something lands" do
      session = furnished_session()

      assert texts(session, box(session)) == ["Your content here"]
    end

    # A FURNISHING IS MARKUP FAR MORE OFTEN THAN IT IS A SENTENCE. Every one of the kit's 136
    # components declares its own, and `chelekom-flex` — the component actually reported — arrives
    # as three bordered divs. Matching one text child against the whole body recognised the
    # placeholder on the components whose furnishing is a bare run of words and on none of the rest,
    # so the sample boxes stayed exactly where the author had just dropped their list.
    @flexish [
      %{
        name: "flexy",
        template: ~S|<div class="flex">{render_slot(@inner_block)}</div>|,
        attrs: [],
        slots: [%{"name" => "inner_block"}],
        furnishing: %{
          "body" =>
            ~S|<div class="box">Research</div>| <>
              "\n" <>
              ~S|<div class="box">Design</div>| <>
              "\n" <> ~S|<div class="box">Build</div>|
        }
      }
    ]

    defp flexy_session(content) do
      open(
        ~s(<div id="root"><.component component_name="flexy" site="Global">#{content}</.component></div>),
        %{components: @flexish}
      )
    end

    defp sample_boxes(session) do
      session
      |> box()
      |> Map.fetch!(:children)
      |> Enum.map(&Tree.get(session.tree, &1))
      |> Enum.filter(&(&1 && &1.tag == "div"))
    end

    @sample ~S|<div class="box">Research</div>
<div class="box">Design</div>
<div class="box">Build</div>|

    test "a furnishing made of markup goes too, which is the one that was reported" do
      session = flexy_session(@sample)
      parent = box(session)

      assert length(sample_boxes(session)) == 3

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          "kind" => "insert",
          "template" => ~s(<ul><li>one</li></ul>),
          "parent_id" => parent.id,
          "index" => "0"
        })

      assert sample_boxes(session) == [],
             "Research / Design / Build stayed beside the list that was dropped in"

      assert html(session) =~ "<ul>"
    end

    # The drop lands where it was aimed, and aiming above the sample is the ordinary gesture — so
    # the run has to be recognised wherever it ends up sitting, not only at the front.
    test "wherever the new content lands among it" do
      for index <- ["0", "1", "3"] do
        session = flexy_session(@sample)
        parent = box(session)

        {:ok, session} =
          EditorSession.apply_op(session.token, %{
            "kind" => "insert",
            "template" => ~s(<ul><li>one</li></ul>),
            "parent_id" => parent.id,
            "index" => index
          })

        assert sample_boxes(session) == [], "the sample survived a drop at index #{index}"
      end
    end

    test "but a sample the author has edited is theirs, and stays" do
      edited = String.replace(@sample, "Design", "Our own step")
      session = flexy_session(edited)
      parent = box(session)

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          "kind" => "insert",
          "template" => ~s(<ul><li>one</li></ul>),
          "parent_id" => parent.id,
          "index" => "0"
        })

      assert length(sample_boxes(session)) == 3
    end

    test "and an untouched sample stays until something joins it" do
      session = flexy_session(@sample)

      assert length(sample_boxes(session)) == 3
    end

    # AGAINST THE FURNISHING THE KIT ACTUALLY SHIPS, not a fixture shaped like it. The comparison is
    # on serialized source, so a real body's long class strings and its own line breaks are the part
    # a hand-written sample cannot vouch for — and `chelekom-flex` is the component that was
    # reported. Read from the bundle so a kit that rewrites its sample content is caught here.
    test "and the real chelekom-flex sample goes, which is what was reported" do
      body =
        MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("components")
        |> Enum.find(&(&1["name"] == "chelekom-flex"))
        |> get_in(["extra", "furnishing", "body"])

      assert is_binary(body) and body =~ "<div",
             "chelekom-flex no longer ships a markup furnishing"

      entry = %{
        name: "chelekom-flex",
        template: ~S|<div class="flex">{render_slot(@inner_block)}</div>|,
        attrs: [],
        slots: [%{"name" => "inner_block"}],
        furnishing: %{"body" => body}
      }

      session =
        open(
          ~s(<div id="root"><.component component_name="chelekom-flex" site="Global">#{body}</.component></div>),
          %{components: [entry]}
        )

      parent = box(session)
      assert sample_boxes(session) != []

      {:ok, session} =
        EditorSession.apply_op(session.token, %{
          "kind" => "insert",
          "template" => ~s(<ul><li>one</li></ul>),
          "parent_id" => parent.id,
          "index" => "0"
        })

      assert sample_boxes(session) == []
      assert html(session) =~ "<ul>"
      refute html(session) =~ "Research"
    end
  end

  # Fields and Send buttons three levels down, card > grid > column, in a core `<.form>` and in a kit
  # wrapper that lends its form through `:let`, on one page.
  describe "forms built deep inside a card" do
    @kit_field %{
      name: "kit-text-field",
      attrs: [
        %{"name" => "bind", "type" => "struct", "struct_name" => "Phoenix.HTML.FormField"},
        %{"name" => "caption", "type" => "string"}
      ],
      slots: [],
      template: "",
      form: %{"role" => "field", "field" => "bind"}
    }

    @kit_form %{
      name: "kit-form",
      attrs: [],
      slots: [%{"name" => "inner_block"}],
      template: "",
      form: %{"role" => "wrapper"}
    }

    @deep_core ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div id="contact-col" class="col"><input type="email" name={f[:email].name} value={f[:email].value} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>)

    @deep_kit ~s(<.component component_name="kit-form" site="Global" :let={g} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div id="news-col" class="col"><input type="email" name={g[:email].name} value={g[:email].value} /></div><div class="col"><button type="submit">Join</button></div></div></div></.component>)

    defp deep,
      do:
        open(~s(<div id="root">#{@deep_core}#{@deep_kit}</div>), %{
          components: [@kit_field, @kit_form]
        })

    defp by_id(session, id),
      do: Enum.find(Tree.walk(session.tree), &(Node.attr_text(&1, "id") == id))

    defp drop(session, template, parent_id),
      do:
        EditorSession.apply_drop(session.token, %{
          "template" => template,
          "parent_id" => parent_id,
          "index" => "0"
        })

    defp deep_specs(session),
      do: session |> html() |> PageForms.declared() |> Map.new(&{&1.as, &1})

    defp keys_of(spec), do: Enum.map(spec.fields, & &1.key)

    test "a field dropped in a core form's column joins that form and no other" do
      session = deep()

      assert {:relocated, session, "Added it to the Contact form."} =
               drop(
                 session,
                 ~s(<input type="text" name="field" />),
                 by_id(session, "contact-col").id
               )

      specs = deep_specs(session)

      assert map_size(specs) == 2
      assert [key, :email] = keys_of(specs["contact"])
      assert html(session) =~ ~s(name={f[:#{key}].name})
      assert keys_of(specs["news"]) == [:email]
    end

    test "a field dropped in a kit wrapper's column joins it, bound to the wrapper's own variable" do
      session = deep()

      assert {:relocated, session, "Added it to the News form."} =
               drop(
                 session,
                 ~s(<input type="text" name="field" />),
                 by_id(session, "news-col").id
               )

      specs = deep_specs(session)

      assert map_size(specs) == 2
      assert [key, :email] = keys_of(specs["news"])
      assert html(session) =~ ~s(name={g[:#{key}].name})
      assert keys_of(specs["contact"]) == [:email]
    end

    test "a kit field dropped deep is bound on the kit's own attribute" do
      session = deep()

      assert {:relocated, session, "Added it to the News form."} =
               drop(
                 session,
                 ~s(<.component component_name="kit-text-field" site="Global" caption="Your name" />),
                 by_id(session, "news-col").id
               )

      assert [key, :email] = keys_of(deep_specs(session)["news"])
      assert html(session) =~ ~s(bind={g[:#{key}]})
    end

    test "a Send button dropped deep inside either form becomes that form's Send button" do
      for {col, id} <- [{"contact-col", "contact-form"}, {"news-col", "news-form"}] do
        buttonless =
          open(
            ~s(<div id="root">#{@deep_core}#{@deep_kit}</div>)
            |> String.replace(~s(<button type="submit">Send</button>), "")
            |> String.replace(~s(<button type="submit">Join</button>), ""),
            %{components: [@kit_field, @kit_form]}
          )

        assert unsent(buttonless) == ~w(contact-form news-form)

        assert {:ok, session} =
                 drop(
                   buttonless,
                   ~s(<button type="submit">Send</button>),
                   by_id(buttonless, col).id
                 )

        assert map_size(deep_specs(session)) == 2
        assert unsent(session) == ~w(contact-form news-form) -- [id]
      end
    end

    # The forms the audit says have no submit button, by their DOM id.
    defp unsent(session) do
      session.tree
      |> PageForms.FormChecks.findings(%{}, session)
      |> Enum.filter(&(&1.rule == "form-no-submit"))
      |> Enum.map(&Node.attr_text(Tree.get(session.tree, &1.node_id), "id"))
    end

    test "a form dropped in a column of another form's card is refused, and nothing changes" do
      form =
        ~s(<.form :let={h} id="quote-form" as={:quote} for={assigns[:quote_form]} phx-change="quote_validate" phx-submit="quote_submit"></.form>)

      for col <- ~w(contact-col news-col) do
        session = deep()
        before = html(session)

        assert {:error, message} = drop(session, form, by_id(session, col).id)
        assert message =~ "cannot go inside another form"

        {:ok, after_refusal} = EditorSession.fetch(session.token)
        assert html(after_refusal) == before
      end
    end

    test "a duplicated deep form gets its own name and token, and keeps its fields' keys" do
      for {id, seed, token} <- [
            {"contact-form", "contact", "k7m2q"},
            {"news-form", "news", "p3xa6"}
          ] do
        session = deep()

        {:ok, session} =
          EditorSession.apply_op(session.token, %{
            kind: :duplicate,
            node_id: by_id(session, id).id
          })

        copy = deep_specs(session)["#{seed}_2"]

        assert copy.submit =~ ~r/^#{seed}_2-[a-z2-7]{5}-submit$/
        refute Naming.token(copy.submit) in [token, "k7m2q", "p3xa6"]
        assert Naming.same_form?(copy.change, copy.submit)
        assert keys_of(copy) == [:email]
        assert deep_specs(session)[seed].submit == "#{seed}-#{token}-submit"
      end
    end
  end

  # TWO FORMS ON ONE PAGE, fields three levels down (card > grid > column): a core `<.form>` whose
  # Send is in the card footer, holding a checkbox and a radio group, and Chelekom's Form Wrapper
  # whose Send is in its `<:actions>` slot.
  describe "fields and forms deep in cards, through the funnel" do
    @core ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit">) <>
            ~s(<.component component_name="chelekom-card" site="Global" id="c-card"><div id="c-grid" class="grid grid-cols-2">) <>
            ~s(<div id="c-col-1"><input id="name-box" type="text" name={f[:name].name} value={f[:name].value} /></div>) <>
            ~s(<div id="c-col-2"><label id="agree-label"><input type="hidden" name={f[:agree].name} value="false" /><input id="agree-box" type="checkbox" name={f[:agree].name} value="true" />I agree</label></div>) <>
            ~s(<div id="c-col-3"><fieldset id="plan-set"><legend>Plan</legend><label><input id="plan-one" type="radio" name={f[:plan].name} value="one" />One</label><label><input type="radio" name={f[:plan].name} value="two" />Two</label></fieldset></div>) <>
            ~s(</div><footer id="c-foot" class="flex"><p>We reply within a day.</p><button id="c-send" type="submit">Send</button></footer></.component></.form>)

    @kit ~s(<.component component_name="chelekom-form-wrapper" site="Global" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">) <>
           ~s(<.component component_name="chelekom-card" site="Global" id="n-card"><div id="n-grid" class="grid">) <>
           ~s(<div id="n-col"><input id="news-email" type="email" name={w[:email].name} value={w[:email].value} /></div>) <>
           ~s(</div></.component><:actions><.component component_name="chelekom-button" site="Global" type="submit">Join</.component></:actions></.component>)

    defp two_forms(chelekom),
      do:
        open(
          ~s(<div id="page">#{@core}#{@kit}<section id="band"><div id="loose"></div></section></div>),
          %{
            components: chelekom
          }
        )

    defp by(session, id),
      do: Enum.find(Tree.walk(session.tree), &(Node.attr_text(&1, "id") == id))

    defp form_specs(session),
      do: session |> html() |> PageForms.declared() |> Map.new(&{&1.as, &1})

    defp keys(spec), do: Enum.map(spec.fields, & &1.key)

    defp newest(before, now) do
      seen = MapSet.new(Tree.walk(before.tree), & &1.id)
      now.tree |> Tree.walk() |> Enum.find(&(not MapSet.member?(seen, &1.id)))
    end

    test "a field dropped on a form's bottom edge joins it before the Send in the card footer", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      form = by(session, "contact-form")

      assert {:relocated, dropped, "Added it to the Contact form."} =
               EditorSession.apply_drop(session.token, %{
                 "template" => ~s(<input type="tel" name="phone" />),
                 "parent_id" => "page",
                 "index" => 1,
                 "anchor_id" => form.id,
                 "anchor_before" => false
               })

      added = newest(session, dropped)
      footer = by(dropped, "c-foot")

      assert added.parent_id == footer.id
      assert Tree.child_ids(dropped.tree, footer.id) |> Enum.at(1) == added.id
      assert keys(form_specs(dropped)["contact"]) == [:name, :agree, :plan, :phone]
    end

    test "a field card clicked while a kit field is selected lands beside that field, not inside it",
         %{chelekom: chelekom} do
      session =
        open(
          ~s(<div id="page"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit">) <>
            ~s(<.component component_name="chelekom-card" site="Global" id="c-card"><div id="c-grid" class="grid"><div id="c-col">) <>
            ~s(<.component component_name="chelekom-text-field" site="Global" id="name-field" field={f[:name]} label="Name" />) <>
            ~s(</div></div><footer id="c-foot"><button id="c-send" type="submit">Send</button></footer></.component></.form></div>),
          %{components: chelekom}
        )

      name = by(session, "name-field")
      {:ok, _armed} = EditorSession.pick(session.token, "chelekom-email-field")

      placed =
        case EditorSession.place_at(session.token, name.id) do
          {:ok, editor} -> editor
          {:relocated, editor, _note} -> editor
        end

      added = newest(session, placed)

      assert Tree.child_ids(placed.tree, name.id) == []
      assert added.parent_id == by(placed, "c-col").id
      assert [:name, _email] = keys(form_specs(placed)["contact"])
      assert html(placed) =~ ~s(component_name="chelekom-email-field")
    end

    test "a field dropped between two fields deep in a card stays there", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      grid = by(session, "c-grid")

      {:relocated, dropped, _joined} =
        EditorSession.apply_drop(session.token, %{
          "template" => ~s(<input type="tel" name="phone" />),
          "parent_id" => grid.id,
          "index" => 1
        })

      assert Enum.at(Tree.child_ids(dropped.tree, grid.id), 1) == newest(session, dropped).id
    end

    test "a field dropped into the Chelekom wrapper's content joins it, outside its actions", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      wrapper = by(session, "news-form")

      assert {:relocated, dropped, "Added it to the News form."} =
               EditorSession.apply_drop(session.token, %{
                 "template" => ~s(<input type="tel" name="phone" />),
                 "parent_id" => wrapper.id,
                 "index" => 99
               })

      added = newest(session, dropped)
      assert added.parent_id == wrapper.id

      refute Enum.any?(Tree.ancestors(dropped.tree, added.id), &(&1.kind == :slot))

      assert keys(form_specs(dropped)["news"]) == [:email, :phone]
      assert html(dropped) =~ ~s(name={w[:phone].name})
    end

    test "a field dropped outside both forms starts a third with a Send button", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      assert {:relocated, dropped, note} =
               EditorSession.apply_drop(session.token, %{
                 "template" => ~s(<input type="tel" name="phone" />),
                 "parent_id" => by(session, "loose").id,
                 "index" => 0
               })

      assert note == FormPlacement.told(:started)
      assert keys(form_specs(dropped)["form"]) == [:phone]
      form = Tree.get(dropped.tree, dropped.selection)
      assert Enum.any?(Tree.walk(Tree.subtree(dropped.tree, form.id)), &(&1.tag == "button"))
    end

    test "the gutter click and a paste go through the same placement", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      {:ok, _armed} = EditorSession.pick(session.token, {:block, "el-input"})

      assert {:relocated, placed, "Added it to the News form."} =
               EditorSession.place(session.token, by(session, "n-col").id, 1)

      assert keys(form_specs(placed)["news"]) == [:email, :field]

      {:ok, _copied} = EditorSession.copy(placed.token, by(placed, "name-box").id)

      assert {:relocated, pasted, note} =
               EditorSession.paste(placed.token, parent_id: by(placed, "loose").id, index: 0)

      assert note == FormPlacement.told(:started)
      assert keys(form_specs(pasted)["form"]) == [:name]
      assert html(pasted) =~ ~s(<input id="name-box" type="text" name={f[:name].name})
    end

    test "a kit form that names its own phx-submit is pasted exactly as it was cut", %{
      chelekom: chelekom
    } do
      session =
        open(
          String.replace(
            ~s(<div id="page">#{@core}#{@kit}<section id="band"><div id="loose"></div></section></div>),
            ~s(<div id="loose"></div>),
            ~s(<div id="loose"></div><div class="card"><div class="grid"><div id="lead-col">) <>
              ~s(<.component component_name="chelekom-form-wrapper" site="Global" id="lead-form" for={%{}} phx-submit="save_lead"><input type="email" name="email" /></.component>) <>
              ~s(</div></div></div>)
          ),
          %{components: chelekom}
        )

      lead = by(session, "lead-form")
      {:ok, _cut} = EditorSession.cut(session.token, lead.id)

      assert {:ok, pasted} =
               EditorSession.paste(session.token, parent_id: by(session, "loose").id, index: 0)

      assert html(pasted) =~
               ~s(<.component component_name="chelekom-form-wrapper" site="Global" id="lead-form" for={%{}} phx-submit="save_lead"><input type="email" name="email" /></.component>)

      assert Map.keys(form_specs(pasted)) |> Enum.sort() == ~w(contact news)
    end

    test "dragging a field into the other form rebinds it there, as one undo step", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      name = by(session, "name-box")

      assert {:relocated, moved, "Added it to the News form."} =
               EditorSession.apply_drop(session.token, %{
                 "node_id" => name.id,
                 "parent_id" => by(session, "n-col").id,
                 "index" => 1
               })

      assert keys(form_specs(moved)["news"]) == [:email, :name]
      assert keys(form_specs(moved)["contact"]) == [:agree, :plan]
      assert Tree.get(moved.tree, name.id).parent_id == by(session, "c-col-1").id
      assert Tree.get(moved.tree, by(session, "c-col-1").id).parent_id == by(moved, "n-col").id
      assert html(moved) =~ ~s(name={w[:name].name})

      {:ok, undone} = EditorSession.undo(moved.token)
      assert html(undone) == html(session)
    end

    test "dragging a field past its own form's Send lands in front of it", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      name = by(session, "name-box")
      footer = by(session, "c-foot")

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => name.id,
          "parent_id" => footer.id,
          "index" => 2
        })

      assert Tree.child_ids(moved.tree, footer.id) |> Enum.at(1) == name.id
      assert Tree.child_ids(moved.tree, footer.id) |> Enum.at(2) == by(moved, "c-send").id
    end

    test "a field dragged from its own row onto the lower half of Send lands in front of it", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      name = by(session, "name-box")
      footer = by(session, "c-foot")

      {:ok, _in_footer} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => name.id,
          "parent_id" => footer.id,
          "index" => 1
        })

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => name.id,
          "parent_id" => footer.id,
          "index" => 3,
          "anchor_id" => by(session, "c-send").id,
          "anchor_before" => false
        })

      assert moved.tree |> Tree.child_ids(footer.id) |> Enum.drop(1) ==
               [name.id, by(moved, "c-send").id]
    end

    test "a field dragged onto the lower half of Send in a flat form lands in front of it" do
      session =
        open(
          ~s(<div id="page"><.form :let={f} id="flat-form" as={:flat} for={assigns[:flat_form]}>) <>
            ~s(<input id="a-box" name={f[:a].name} /><input id="b-box" name={f[:b].name} /><button id="flat-send" type="submit">Send</button></.form></div>)
        )

      form = by(session, "flat-form")

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => by(session, "a-box").id,
          "parent_id" => form.id,
          "index" => 3,
          "anchor_id" => by(session, "flat-send").id,
          "anchor_before" => false
        })

      assert Tree.child_ids(moved.tree, form.id) ==
               Enum.map(~w(b-box a-box flat-send), &by(session, &1).id)
    end

    test "dragging the only field out of a form puts it in a new one and removes the old", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      email = by(session, "news-email")

      assert {:relocated, moved, note} =
               EditorSession.apply_drop(session.token, %{
                 "node_id" => email.id,
                 "parent_id" => by(session, "loose").id,
                 "index" => 0
               })

      assert note == FormPlacement.told(:started) <> " The empty form was removed."
      assert Map.keys(form_specs(moved)) |> Enum.sort() == ~w(contact form)
      assert keys(form_specs(moved)["form"]) == [:email]
      assert Tree.get(moved.tree, moved.selection).tag == "input"
    end

    # A legacy page's loose field, once in a section and once in card > grid > column, outside any form.
    defp loose_rows do
      open(
        ~s(<div id="page"><section id="band"><input id="x-box" name="x" /><p id="p1">1</p><p id="p2">2</p></section>) <>
          ~s(<div id="l-card" class="card"><div id="l-grid" class="grid"><div id="l-col"><input id="y-box" name="y" /><p id="q1">1</p><p id="q2">2</p></div></div></div></div>)
      )
    end

    defp row(session, parent),
      do:
        session.tree
        |> Tree.children(by(session, parent).id)
        |> Enum.map(&((PageForms.form?(&1) && "form") || Node.attr_text(&1, "id")))

    test "a loose field dragged along its own row starts its form exactly where it was aimed" do
      for {field, parent, [first, last]} <- [
            {"x-box", "band", ~w(p1 p2)},
            {"y-box", "l-col", ~w(q1 q2)}
          ],
          {aim, expected} <- [
            {%{"index" => 3}, [first, last, "form"]},
            {%{"anchor_id" => last, "anchor_before" => false}, [first, last, "form"]},
            {%{"anchor_id" => last, "anchor_before" => true}, [first, "form", last]},
            {%{"index" => 2}, [first, "form", last]}
          ] do
        session = loose_rows()

        aim =
          Map.update(aim, "anchor_id", nil, &by(session, &1).id)
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        assert {:relocated, moved, _started} =
                 EditorSession.apply_drop(
                   session.token,
                   Map.merge(
                     %{"node_id" => by(session, field).id, "parent_id" => by(session, parent).id},
                     aim
                   )
                 )

        assert row(moved, parent) == expected, inspect({field, aim})
      end
    end

    test "a field dragged between two forms bound to one variable takes a key free there" do
      session =
        open(
          ~s(<div id="page"><.form :let={f} id="a-form" as={:a} for={assigns[:a_form]}><div id="a-col"><input id="a-email" name={f[:email].name} /></div></.form>) <>
            ~s(<.form :let={f} id="b-form" as={:b} for={assigns[:b_form]}><div id="b-col"><input name={f[:email].name} /></div></.form></div>)
        )

      {:relocated, moved, _joined} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => by(session, "a-email").id,
          "parent_id" => by(session, "b-col").id,
          "index" => 1
        })

      assert keys(form_specs(moved)["b"]) == [:email, :email_2]
    end

    test "a moved field re-keyed on :move when its new form already uses the key" do
      session =
        open(
          ~s(<div id="page"><.form :let={f} as={:a} for={assigns[:a_form]}><input id="a-email" name={f[:email].name} /><p>x</p></.form>) <>
            ~s(<.form :let={f} id="b-form" as={:b} for={assigns[:b_form]}><input name={f[:email].name} /></.form></div>)
        )

      {:ok, moved} =
        EditorSession.apply_op(session.token, %{
          kind: :move,
          node_id: by(session, "a-email").id,
          parent_id: by(session, "b-form").id,
          index: 1
        })

      assert keys(form_specs(moved)["b"]) == [:email, :email_2]
    end

    test "a checkbox dragged into the other form brings its label and hidden twin, one step", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      assert {:relocated, moved, "Added it to the News form."} =
               EditorSession.apply_drop(session.token, %{
                 "node_id" => by(session, "agree-box").id,
                 "parent_id" => by(session, "n-col").id,
                 "index" => 1
               })

      assert Tree.get(moved.tree, by(session, "agree-label").id).parent_id ==
               by(session, "c-col-2").id

      assert Tree.get(moved.tree, by(session, "c-col-2").id).parent_id == by(moved, "n-col").id
      assert keys(form_specs(moved)["news"]) == [:email, :agree]
      assert keys(form_specs(moved)["contact"]) == [:name, :plan]
      assert html(moved) =~ ~s(<input type="hidden" name={w[:agree].name} value="false")

      {:ok, undone} = EditorSession.undo(moved.token)
      assert html(undone) == html(session)
    end

    test "a radio option reordered inside its own group keeps the group's key", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      two = Enum.find(Tree.walk(session.tree), &(Node.attr_text(&1, "value") == "two"))

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => two.parent_id,
          "parent_id" => by(session, "plan-set").id,
          "index" => 1
        })

      assert moved.tree |> Tree.child_ids(by(moved, "plan-set").id) |> Enum.at(1) == two.parent_id
      assert keys(form_specs(moved)["contact"]) == [:name, :agree, :plan]
      refute html(moved) =~ "plan_2"
    end

    test "a checkbox dropped elsewhere in its own form keeps its key", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      box = by(session, "agree-box")

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => box.id,
          "parent_id" => by(session, "c-col-1").id,
          "index" => 1
        })

      assert Tree.get(moved.tree, box.id).parent_id == by(moved, "c-col-1").id
      assert html(moved) =~ ~s(id="agree-box" type="checkbox" name={f[:agree].name})
      assert keys(form_specs(moved)["contact"]) == [:name, :agree, :plan]
    end

    test "an input moved away from its label in its own form keeps its key", %{
      chelekom: chelekom
    } do
      session =
        open(
          String.replace(
            ~s(<div id="page">#{@core}#{@kit}</div>),
            ~s(<div id="c-col-3">),
            ~s(<div id="c-col-4"><label for={f[:email].id}>Email</label><input id="email-box" type="email" name={f[:email].name} /></div><div id="c-col-3">)
          ),
          %{components: chelekom}
        )

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => by(session, "email-box").id,
          "parent_id" => by(session, "c-col-1").id,
          "index" => 1
        })

      assert html(moved) =~ ~s(id="email-box" type="email" name={f[:email].name})
      assert keys(form_specs(moved)["contact"]) == [:name, :email, :agree, :plan]
    end

    test "In form moves a checkbox unit to the other form, rebinding both controls", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      label = by(session, "agree-label")

      assert {:relocated, moved, "Moved it to the News form."} =
               EditorSession.move_to_form(
                 session.token,
                 by(session, "agree-box").id,
                 by(session, "news-form").id
               )

      assert keys(form_specs(moved)["news"]) == [:email, :agree]
      assert html(moved) =~ ~s(<input type="hidden" name={w[:agree].name} value="false")
      assert Tree.get(moved.tree, label.id).parent_id == by(session, "c-col-2").id

      assert Tree.get(moved.tree, by(session, "c-col-2").id).parent_id ==
               by(moved, "news-form").id

      {:ok, undone} = EditorSession.undo(moved.token)
      assert html(undone) == html(session)
    end

    test "In form moves a radio group, and a new form keeps the field selected", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      assert {:relocated, moved, "Moved it to a new form with a Send button."} =
               EditorSession.move_to_form(
                 session.token,
                 by(session, "plan-one").id,
                 FormPlacement.new_target()
               )

      assert keys(form_specs(moved)["form"]) == [:plan]
      assert keys(form_specs(moved)["contact"]) == [:name, :agree]
      selected = Tree.get(moved.tree, moved.selection)
      assert Node.attr_text(selected, "type") == "radio"
      assert Node.attr_text(selected, "value") == "one"
    end

    test "Move its fields into merges a form into another as one step", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      news = by(session, "news-form").id

      assert {:relocated, merged, note} =
               EditorSession.merge_forms(session.token, by(session, "contact-form").id, news)

      assert note == "Moved its fields to the News form. The empty form was removed."
      assert keys(form_specs(merged)["news"]) == [:email, :name, :agree, :plan]
      assert Map.keys(form_specs(merged)) == ["news"]
      assert merged.selection == news

      {:ok, undone} = EditorSession.undo(merged.token)
      assert html(undone) == html(session)
    end

    test "Move its fields into lands every field where all of them may go, past a Send in a <p>",
         %{chelekom: chelekom} do
      alpha =
        ~s(<.form :let={a} id="alpha-form" as={:alpha} for={assigns[:alpha_form]} phx-change="alpha-aaaaa-validate" phx-submit="alpha-aaaaa-submit">) <>
          ~s(<div class="card"><div class="grid"><div id="a-col"><input id="a-name" name={a[:name].name} />) <>
          ~s(<fieldset id="a-plan"><legend>Plan</legend><label><input type="radio" name={a[:plan].name} value="one" />One</label><label><input type="radio" name={a[:plan].name} value="two" />Two</label></fieldset>) <>
          ~s(</div></div></div><button type="submit">Go</button></.form>)

      content =
        ~s(<.component component_name="chelekom-card" site="Global"><div class="grid"><div id="b-col"><input name={b[:email].name} /><p id="b-send-row"><button type="submit">Join</button></p></div></div></.component>)

      names =
        ~s(:let={b} id="beta-form" as={:beta} for={assigns[:beta_form]} phx-change="beta-bbbbb-validate" phx-submit="beta-bbbbb-submit")

      for beta <- [
            ~s(<.form #{names}>#{content}</.form>),
            ~s(<.component component_name="chelekom-form-wrapper" site="Global" #{names}>#{content}</.component>)
          ] do
        session = open(~s(<div id="page">#{alpha}#{beta}</div>), %{components: chelekom})

        assert {:relocated, merged,
                "Moved its fields to the Beta form. The empty form was removed."} =
                 EditorSession.merge_forms(
                   session.token,
                   by(session, "alpha-form").id,
                   by(session, "beta-form").id
                 )

        refute Tree.get(merged.tree, by(session, "a-plan").id).parent_id ==
                 by(session, "b-send-row").id

        assert keys(form_specs(merged)["beta"]) == [:email, :name, :plan]
        assert Map.keys(form_specs(merged)) == ["beta"]
      end
    end

    test "drop_field?/2 answers for a field template and a field node, on a page only", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      assert EditorSession.drop_field?(session.token, %{"template" => ~s(<input name="q" />)})
      assert EditorSession.drop_field?(session.token, %{"node_id" => by(session, "agree-box").id})
      refute EditorSession.drop_field?(session.token, %{"template" => "<p>Hello</p>"})
      refute EditorSession.drop_field?(session.token, %{"node_id" => by(session, "c-grid").id})

      layout = open(~s(<div id="page"><div id="loose"></div></div>), %{section: "layout"})
      refute EditorSession.drop_field?(layout.token, %{"template" => ~s(<input name="q" />)})
    end
  end
end
