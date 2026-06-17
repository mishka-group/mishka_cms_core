defmodule MishkaCmsCore.Runtime.PageBuilder.PlacementTest do
  @moduledoc """
  Where a thing lands: the rule shared by a click, a drag and a template that arrives on its own.

  This is the editor's least-tested and most-visible behaviour. Ten public functions on the session
  had no test of their own — `pick/2`, `place_at/2`, `drop_hints/2` and `apply_drop/2` among them —
  and between them they decide the outcome of every gesture that puts something on the page.

  The two rules being pinned:

    * a LEAF goes inside what you clicked when it will take one and immediately after it when it
      will not. Clicking an `<img>` is not a mistake; it is someone pointing at a place;
    * a BAND — a `<section>`, a block — is a horizontal slice of the page and belongs beside the
      other slices, so a click pointing into one climbs out of the whole branch. Without that, a
      call-to-action clicked while a header was selected became a third item in the header's flex
      row and rendered at a quarter width.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @moduletag :unit

  defp open(template, attrs \\ %{}) do
    {:ok, session} = EditorSession.open(Map.merge(%{section: "page", template: template}, attrs))
    session
  end

  defp find(session, tag), do: Enum.find(Tree.walk(session.tree), &(&1.tag == tag))
  defp id(session, tag), do: find(session, tag).id
  defp parent_of(session, node_id), do: Tree.get(session.tree, node_id).parent_id
  defp tags(session), do: session.tree |> Tree.walk() |> Enum.map(& &1.tag)

  defp source(session), do: Serializer.serialize(session.tree)

  defp scopes(markup),
    do: ~r/pb-[a-f0-9]{8}/ |> Regex.scan(markup) |> List.flatten() |> Enum.uniq()

  defp newest(before, session) do
    seen = before.tree |> Tree.walk() |> MapSet.new(& &1.id)

    session.tree |> Tree.walk() |> Enum.find(&(!MapSet.member?(seen, &1.id)))
  end

  describe "a leaf placed by a click" do
    test "goes inside the element that will hold it" do
      session = open(~s(<div id="root"><section><p>hello</p></section></div>))
      target = id(session, "section")

      {:ok, placed} = EditorSession.place_template(session.token, "<h2>Title</h2>", target)

      assert parent_of(placed, newest(session, placed).id) == target
    end

    test "and immediately after one that will not" do
      session = open(~s(<div id="root"><section><img src="a.png" /></section></div>))
      image = id(session, "img")

      {:ok, placed} = EditorSession.place_template(session.token, "<h2>Title</h2>", image)

      added = newest(session, placed)

      assert added.parent_id == parent_of(session, image)

      assert Enum.find_index(Tree.child_ids(placed.tree, added.parent_id), &(&1 == added.id)) ==
               1
    end

    test "with nothing clicked it goes at the end of the document" do
      session = open(~s(<div id="root"><p>hello</p></div>))

      {:ok, placed} = EditorSession.place_template(session.token, "<h2>Title</h2>", nil)

      assert newest(session, placed).parent_id == nil
      assert List.last(placed.tree.roots) == newest(session, placed).id
    end

    test "and a click on something that is no longer there also goes at the end" do
      session = open(~s(<div id="root"><p>hello</p></div>))

      {:ok, placed} = EditorSession.place_template(session.token, "<h2>Title</h2>", "nzzzzzzzz")

      assert newest(session, placed).parent_id == nil
    end
  end

  describe "a band placed by a click" do
    # THE BUG THIS RULE EXISTS FOR. Clicked deep inside a header, a section must not become a third
    # item in the header's flex row.
    test "climbs out of the branch it was clicked in" do
      session =
        open(~s(<body><header><nav><a href="/">Home</a></nav></header></body>))

      link = id(session, "a")

      {:relocated, placed, note} =
        EditorSession.place_template(session.token, "<section>New</section>", link)

      added = newest(session, placed)

      assert Tree.get(placed.tree, added.parent_id).tag == "body"
      assert note =~ "Sections sit beside each other"
    end

    test "lands inside a host that already holds bands" do
      session =
        open(~s(<body><div id="app"><section>One</section></div></body>))

      wrapper = Enum.find(Tree.walk(session.tree), &(&1.tag == "div"))

      {:ok, placed} =
        EditorSession.place_template(session.token, "<section>Two</section>", wrapper.id)

      assert newest(session, placed).parent_id == wrapper.id
    end

    # An empty box is a hole to put things in — the one container that cannot squeeze a band into a
    # narrow third column, because there is nothing beside it.
    test "and inside an empty box, which is a place waiting to be filled" do
      session = open(~s(<body><div id="empty"></div></body>))
      box = Enum.find(Tree.walk(session.tree), &(&1.tag == "div"))

      {:ok, placed} =
        EditorSession.place_template(session.token, "<section>One</section>", box.id)

      assert newest(session, placed).parent_id == box.id
    end
  end

  describe "arming a card and placing it" do
    test "an armed template lands where the click means" do
      session = open(~s(<div id="root"><section><p>hello</p></section></div>))
      {:ok, armed} = EditorSession.place_template(session.token, "<h2>a</h2>", nil)

      assert Tree.size(armed.tree) > Tree.size(session.tree)
    end

    test "placing with nothing armed is refused rather than guessed at" do
      session = open(~s(<div id="root"></div>))

      assert {:error, :nothing_picked} = EditorSession.place_at(session.token, nil)
    end

    test "picking arms the session and picking nil disarms it" do
      session = open(~s(<div id="root"></div>))

      {:ok, armed} = EditorSession.pick(session.token, "chelekom-alert")
      assert armed.picked == "chelekom-alert"

      {:ok, disarmed} = EditorSession.pick(session.token, nil)
      assert disarmed.picked == nil
    end
  end

  describe "the hints a drag paints with" do
    test "every node is answered, so the canvas can colour all of them" do
      session = open(~s(<div id="root"><section><p>hello</p></section></div>))

      {:ok, hints} = EditorSession.drop_hints(session.token, %{"template" => "<h2>Title</h2>"})

      assert map_size(hints) == length(Tree.walk(session.tree))
      assert Enum.all?(Map.values(hints), &is_boolean/1)
    end

    test "a container that can hold the dragged thing says yes" do
      session = open(~s(<div id="root"><section><p>hello</p></section></div>))

      {:ok, hints} = EditorSession.drop_hints(session.token, %{"template" => "<h2>Title</h2>"})

      assert hints[id(session, "section")]
    end

    test "a locked container says no even though it could hold it" do
      session = open(~s(<div id="root"><section><p>hello</p></section></div>))
      section = id(session, "section")
      {:ok, locked} = EditorSession.toggle_lock(session.token, section)

      {:ok, hints} = EditorSession.drop_hints(locked.token, %{"template" => "<h2>Title</h2>"})

      refute hints[section]
    end

    # Dragging something locked is not a drag at all: nowhere will take it, and saying so everywhere
    # is what stops the canvas painting a line it would then refuse.
    test "and dragging a locked node refuses everywhere at once" do
      session = open(~s(<div id="root"><section><p>hello</p></section></div>))
      paragraph = id(session, "p")
      {:ok, locked} = EditorSession.toggle_lock(session.token, paragraph)

      {:ok, hints} = EditorSession.drop_hints(locked.token, %{"node_id" => paragraph})

      assert Enum.all?(Map.values(hints), &(&1 == false))
    end
  end

  describe "a drop that the tree refuses" do
    test "a legal drop is simply applied" do
      session = open(~s(<div id="root"><section></section></div>))
      section = id(session, "section")

      {:ok, dropped} =
        EditorSession.apply_drop(session.token, %{
          "template" => "<h2>Title</h2>",
          "parent_id" => section,
          "index" => 0
        })

      assert newest(session, dropped).parent_id == section
    end

    # A `<span>` that cannot hold a section still says which section the new one belongs next to, so
    # the gesture is answered rather than dropped on the floor.
    test "is relocated beside the target rather than discarded" do
      session = open(~s(<body><main><span>inline</span></main></body>))
      span = id(session, "span")

      result =
        EditorSession.apply_drop(session.token, %{
          "template" => "<section>New</section>",
          "parent_id" => span,
          "index" => 0
        })

      assert {:relocated, dropped, sentence} = result
      assert sentence =~ "Placed after"
      assert newest(session, dropped).parent_id == parent_of(session, span)
    end

    # No parent named means the document itself, which is what a drop onto empty canvas is.
    test "and a drop naming no parent lands at the top level" do
      session = open(~s(<div id="root"></div>))

      {:ok, dropped} = EditorSession.apply_drop(session.token, %{"template" => "<h2>x</h2>"})

      assert newest(session, dropped).parent_id == nil
    end
  end

  # ONE GESTURE, TWO DOORS. A snippet card is the palette's hook and the palette's `data-template`,
  # so Insert reaches `place_template/3` while a drag of the same card reaches `apply_drop/2` with
  # the markup in the payload. The `pb-` classes it arrives wearing are keys into the element CSS
  # row of the document it was cut from — see `MishkaCmsCore.Runtime.PageBuilder.ElementScopes` —
  # so a door that keeps them hands the author an element styled by a row this document neither owns
  # nor prunes, and an empty CSS box in front of it.
  describe "a template carrying another document's element classes" do
    @carried ~s(<p class="note pb-0a1b2c3d" data-target=".pb-0a1b2c3d">New</p>)

    # The class is a handle as well as a CSS key — an interaction points at `.pb-…` — so the two
    # move together or the interaction is left aiming at nothing.
    test "is minted fresh when it is dragged onto the canvas" do
      session = open(~s(<div id="root"><section></section></div>))
      section = id(session, "section")

      assert {:ok, dropped} =
               EditorSession.apply_drop(session.token, %{
                 "template" => @carried,
                 "parent_id" => section,
                 "index" => 0
               })

      markup = source(dropped)

      assert [minted] = scopes(markup)
      refute minted == "pb-0a1b2c3d"
      assert markup =~ ~s(class="note #{minted}")
      assert markup =~ ~s(data-target=".#{minted}")
    end

    test "and when it is dragged onto empty canvas, where no parent is named" do
      session = open(~s(<div id="root"></div>))

      assert {:ok, dropped} =
               EditorSession.apply_drop(session.token, %{"template" => @carried})

      assert [minted] = scopes(source(dropped))
      refute minted == "pb-0a1b2c3d"
    end

    # THE DEFECT THIS PINS was one door short: clicking Insert minted and dragging did not, so the
    # same card gave the author two different documents depending on how they placed it.
    test "whichever door it comes through" do
      clicked = open(~s(<div id="root"></div>))
      dragged = open(~s(<div id="root"></div>))

      {:ok, clicked} = EditorSession.place_template(clicked.token, @carried, nil)
      {:ok, dragged} = EditorSession.apply_drop(dragged.token, %{"template" => @carried})

      assert [by_click] = scopes(source(clicked))
      assert [by_drag] = scopes(source(dragged))

      refute by_click == "pb-0a1b2c3d"
      refute by_drag == "pb-0a1b2c3d"
    end

    # Two copies of one snippet on one page are two elements, and an author styling the second must
    # not restyle the first.
    test "and a second drag of the same card is a second element" do
      session = open(~s(<div id="root"></div>))

      {:ok, once} = EditorSession.apply_drop(session.token, %{"template" => @carried})
      {:ok, twice} = EditorSession.apply_drop(once.token, %{"template" => @carried})

      assert [first, second] = scopes(source(twice))
      refute first == second
    end
  end

  # A FIELD ON ITS OWN RENDERS PERFECTLY AND SUBMITS NOTHING, which is why the repair happens at the
  # drop rather than in a report the author has to go and read.
  describe "a field that lands with no form around it" do
    test "is wrapped in one, and the author is told" do
      session = open(~s(<div id="root"></div>))

      assert {:relocated, placed, note} =
               EditorSession.place_template(session.token, ~s(<input name="email" />), nil)

      assert note =~ "form"
      assert [%{as: "form", fields: [%{key: :email}]}] = PageForms.declared(source(placed))
    end

    test "and the form and the field leave together, on one undo" do
      session = open(~s(<div id="root"></div>))

      {:relocated, placed, _note} =
        EditorSession.place_template(session.token, ~s(<input name="email" />), nil)

      assert {:ok, undone} = EditorSession.undo(placed.token)
      assert source(undone) == source(session)
      assert undone.past == []
    end

    # A drag carries its template in the payload and lands in `apply_drop/2`, so it never passes the
    # click route — the gesture that needs this most would otherwise be the one that misses it.
    test "a drag from the palette is wrapped too" do
      session = open(~s(<div id="root"><section></section></div>))
      section = id(session, "section")

      assert {:relocated, dropped, _note} =
               EditorSession.apply_drop(session.token, %{
                 "template" => ~s(<input name="email" />),
                 "parent_id" => section,
                 "index" => 0
               })

      assert [%{fields: [%{key: :email}]}] = PageForms.declared(source(dropped))
    end

    test "and a drop naming no parent is wrapped at the top level" do
      session = open(~s(<div id="root"></div>))

      assert {:relocated, dropped, _note} =
               EditorSession.apply_drop(session.token, %{"template" => ~s(<input name="email" />)})

      assert [%{as: "form"}] = PageForms.declared(source(dropped))
    end

    test "anything that is not a field is placed exactly as it arrived" do
      session = open(~s(<div id="root"></div>))

      assert {:ok, placed} = EditorSession.place_template(session.token, "<h2>Title</h2>", nil)
      assert PageForms.declared(source(placed)) == []
    end
  end

  describe "a field that lands inside a form" do
    defp with_form do
      open(
        ~s(<div id="root"><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}></.form></div>)
      )
    end

    test "is bound to that form rather than given one of its own" do
      session = with_form()

      assert {:relocated, placed, "Added it to the Q form."} =
               EditorSession.place_template(
                 session.token,
                 ~s(<input name="email" />),
                 id(session, ".form")
               )

      assert [%{as: "q", fields: [%{key: :email}]}] = PageForms.declared(source(placed))
      assert Enum.count(Tree.walk(placed.tree), &(&1.tag == ".form")) == 1
    end

    test "which means the empty form has to accept a child in the first place" do
      session = with_form()
      form = id(session, ".form")

      {:relocated, placed, _joined} =
        EditorSession.place_template(session.token, ~s(<input name="email" />), form)

      assert parent_of(placed, newest(session, placed).id) == form
    end

    test "and a second form dropped into it is refused, landing beside it instead" do
      session = with_form()
      form = id(session, ".form")

      assert {:relocated, dropped, sentence} =
               EditorSession.apply_drop(session.token, %{
                 "template" => ~s(<.form :let={g} as={:b} for={assigns[:b_form]}></.form>),
                 "parent_id" => form,
                 "index" => 0
               })

      assert sentence =~ "another form"
      assert parent_of(dropped, newest(session, dropped).id) == parent_of(session, form)
    end
  end

  # THE FORM CARD CLICKED WHILE A FIELD DEEP IN A FORM IS SELECTED. The field refuses a form, and so
  # does every box between it and its form; the new form lands after the first ancestor whose parent
  # takes it, which is the form the field is in.
  describe "a form placed by a click on a field deep inside another form" do
    @deep_core ~s(<div id="page"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]}>) <>
                 ~s(<.component component_name="chelekom-card" site="Global"><div class="grid"><div class="col">) <>
                 ~s(<input id="email" name={f[:email].name} /></div></div></.component></.form><p>after</p></div>)

    @deep_kit ~s(<div id="page"><.component component_name="chelekom-form-wrapper" site="Global" :let={w} id="news-form" as={:news} for={assigns[:news_form]}>) <>
                ~s(<.component component_name="chelekom-card" site="Global"><div class="grid"><div class="col">) <>
                ~s(<input id="email" name={w[:email].name} /></div></div></.component></.component><p>after</p></div>)

    setup do
      {:ok,
       chelekom: MishkaCmsCore.Test.Factory.chelekom_rows(~w(chelekom-card chelekom-form-wrapper))}
    end

    test "lands after the form the field is in, and says why", %{chelekom: chelekom} do
      for {source, form_id} <- [{@deep_core, "contact-form"}, {@deep_kit, "news-form"}] do
        session = open(source, %{components: chelekom})
        field = Enum.find(Tree.walk(session.tree), &(Tree.Node.attr_text(&1, "id") == "email"))
        form = Enum.find(Tree.walk(session.tree), &(Tree.Node.attr_text(&1, "id") == form_id))

        assert {:relocated, placed, note} =
                 EditorSession.place_template(
                   session.token,
                   MishkaCmsCore.Runtime.PageBuilder.Elements.get("el-form").template,
                   field.id
                 )

        added = newest(session, placed)

        assert note =~ "A form cannot go inside another form"

        assert note =~
                 "Placed after the #{String.capitalize(String.trim_trailing(form_id, "-form"))} form instead."

        assert added.parent_id == form.parent_id
        assert Tree.index_of(placed.tree, added.id) == Tree.index_of(placed.tree, form.id) + 1
        assert length(PageForms.declared(source(placed))) == 2
      end
    end

    test "calls a form that does not work yet the form, never by its tag or kit name", %{
      chelekom: chelekom
    } do
      deep =
        ~s(<.component component_name="chelekom-card" site="Global"><div class="grid"><div class="col"><input id="email" name="email" /></div></div></.component>)

      unwired_kit =
        ~s(<div id="page"><.component component_name="chelekom-form-wrapper" site="Global" id="news-form" for={%{}}>#{deep}</.component><p>after</p></div>)

      raw =
        ~s(<div id="page"><form id="news-form" action="/signup">#{deep}</form><p>after</p></div>)

      unsourced =
        ~s(<div id="page"><.form :let={f} id="contact-form" as={:contact} for={%{}}>#{String.replace(deep, ~s(name="email"), ~s(name={f[:email].name}))}</.form><p>after</p></div>)

      for source <- [unwired_kit, raw, unsourced] do
        session = open(source, %{components: chelekom})
        field = Enum.find(Tree.walk(session.tree), &(Tree.Node.attr_text(&1, "id") == "email"))

        assert {:relocated, _placed, note} =
                 EditorSession.place_template(
                   session.token,
                   MishkaCmsCore.Runtime.PageBuilder.Elements.get("el-form").template,
                   field.id
                 )

        assert note ==
                 "A form cannot go inside another form — browsers drop the inner one. Placed after the form instead.",
               source
      end
    end

    test "calls anything else it climbed past the element around it", %{chelekom: chelekom} do
      session =
        open(
          ~s(<div id="page"><.component component_name="chelekom-card" site="Global"><div class="grid"><div class="col"><p id="line">Name <input id="email" name="email" /></p></div></div></.component></div>),
          %{components: chelekom}
        )

      field = Enum.find(Tree.walk(session.tree), &(Tree.Node.attr_text(&1, "id") == "email"))

      assert {:relocated, placed, note} =
               EditorSession.place_template(session.token, ~s(<div class="box"></div>), field.id)

      assert note =~ "Placed after the element around it instead."
      refute note =~ ~r/after p /
      line = Enum.find(Tree.walk(placed.tree), &(Tree.Node.attr_text(&1, "id") == "line"))
      added = newest(session, placed)
      assert Tree.index_of(placed.tree, added.id) == Tree.index_of(placed.tree, line.id) + 1
    end
  end

  describe "finding and replacing text" do
    test "finds every node whose text matches, ignoring case" do
      session = open(~s(<div id="root"><p>Hello world</p><h2>hello again</h2></div>))

      found = EditorSession.find_text(session, "hello")

      assert length(found) == 2
    end

    test "a needle that matches nothing finds nothing" do
      session = open(~s(<div id="root"><p>Hello world</p></div>))

      assert EditorSession.find_text(session, "goodbye") == []
    end

    test "replacing rewrites every match and leaves the shape alone" do
      session = open(~s(<div id="root"><p>Hello world</p><h2>hello again</h2></div>))

      {:ok, replaced} = EditorSession.replace_text(session.token, "hello", "goodbye")

      assert tags(replaced) == tags(session)
      assert EditorSession.find_text(replaced, "hello") == []
      assert length(EditorSession.find_text(replaced, "goodbye")) == 2
    end
  end

  # THE TWO SIDES COUNT DIFFERENTLY. `Tree.move/4` reads its index against the siblings with the
  # moving node already removed; the browser reads it against what is on screen, where the node it
  # is dragging is still in the row. Forward drags therefore landed one slot too far while backward
  # drags were correct, which reads as an intermittent bug rather than an off-by-one.
  describe "reordering among the same siblings" do
    defp order(session, parent_tag) do
      parent = Enum.find(Tree.walk(session.tree), &(&1.tag == parent_tag))

      session.tree |> Tree.children(parent.id) |> Enum.map(&label_of(session, &1))
    end

    defp label_of(session, node) do
      case Tree.children(session.tree, node.id) do
        [%{kind: :text, text: text} | _rest] -> String.trim(text)
        _none -> node.tag
      end
    end

    defp drag(session, from_label, to_index) do
      node =
        Enum.find(
          Tree.walk(session.tree),
          &(&1.tag == "li" and label_of(session, &1) == from_label)
        )

      parent = Tree.get(session.tree, node.parent_id)

      EditorSession.apply_drop(session.token, %{
        "node_id" => node.id,
        "parent_id" => parent.id,
        "index" => to_index
      })
    end

    test "dragging forward lands where the pointer said" do
      session = open(~s(<ul><li>a</li><li>b</li><li>c</li><li>d</li></ul>))

      {:ok, moved} = drag(session, "a", 2)

      assert order(moved, "ul") == ~w(b a c d)
    end

    test "dragging to the very end lands last" do
      session = open(~s(<ul><li>a</li><li>b</li><li>c</li></ul>))

      {:ok, moved} = drag(session, "a", 3)

      assert order(moved, "ul") == ~w(b c a)
    end

    # The direction that always worked, kept honest: the removal happens after the target, so
    # nothing shifts and the index means what it says.
    test "dragging backward still lands where the pointer said" do
      session = open(~s(<ul><li>a</li><li>b</li><li>c</li><li>d</li></ul>))

      {:ok, moved} = drag(session, "d", 1)

      assert order(moved, "ul") == ~w(a d b c)
    end

    test "and moving into a different parent is not adjusted at all" do
      session = open(~s(<div><ul><li>a</li><li>b</li></ul><ol><li>x</li></ol></div>))

      node =
        Enum.find(Tree.walk(session.tree), &(&1.tag == "li" and label_of(session, &1) == "a"))

      ol = Enum.find(Tree.walk(session.tree), &(&1.tag == "ol"))

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => node.id,
          "parent_id" => ol.id,
          "index" => 1
        })

      assert order(moved, "ol") == ~w(x a)
    end
  end

  # A DROP THE CLIENT COULD NOT MEASURE. The canvas computes its index with `indexOf`, which answers
  # -1 when the sibling it measured against is not among the children it can see — every drag inside
  # a runtime component's slot, because slot children render through the component's own markup and
  # have no wrapper to be found in. Sending that to the end of the list threw the node clean out of
  # the slot it was dropped into.
  describe "a drop whose index could not be worked out" do
    test "lands at the start of the parent rather than at the end of it" do
      session = open(~s(<div id="root"><p>one</p><p>two</p><h2>moving</h2></div>))
      moving = Enum.find(Tree.walk(session.tree), &(&1.tag == "h2"))
      root = Tree.get(session.tree, moving.parent_id)

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => moving.id,
          "parent_id" => root.id,
          "index" => -1
        })

      assert moved.tree |> Tree.child_ids(root.id) |> List.first() == moving.id
    end
  end
end
