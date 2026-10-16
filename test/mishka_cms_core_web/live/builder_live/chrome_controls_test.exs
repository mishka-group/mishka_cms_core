# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.ChromeControlsTest do
  @moduledoc """
  The editor's chrome controls: toolbar, command palette, drawer, layers, breakpoints and installs.
  """
  use MishkaCmsCore.BuilderLiveCase

  describe "chrome controls" do
    test "the device switcher changes the frame", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-device-mobile") |> render_click()
      assert has_element?(view, "#pb-frame-mobile")

      view |> element("#pb-device-frames") |> render_click()
      assert has_element?(view, "#pb-frame-1180")
      assert has_element?(view, "#pb-frame-560")
    end

    # The drawer is the sliver under the canvas, opened from its own strip or ⌘/. The TOP bar's Code
    # is a different surface now — see "the page source window" below.
    test "the code drawer opens and shows the serialized template", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_code", %{})

      html = render(view)
      assert html =~ "pb-codetab-html"

      assert html =~ "Contact Us"

      # The panes are inside `phx-no-curly-interpolation`, which is exactly where a `{…}` writes
      # itself out instead of rendering — so assert the placeholder never reaches the page.
      refute html =~ "{text}"
      refute html =~ "{number}"
    end

    # THE RIGHT PANE FOLLOWS THE SELECTION AND TAKES WHAT YOU TYPE. It used to render every styled
    # node on the page, ignoring the selection completely — so clicking an element changed the left
    # pane and left the right one showing a wall of other people's rules, with no way to type in it.
    test "the drawer's CSS pane shows the selected element's own CSS, and writes it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      assert has_element?(view, "[data-role=pb-drawer-css]"), "the box is there for a plain tag"

      view
      |> element("#pb-drawer-css-form")
      |> render_submit(%{"node_id" => heading.id, "css" => "letter-spacing: 3px;"})

      scope = Tree.scope(editor(view).tree, heading.id)
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules[scope] =~ "letter-spacing"
    end

    # THE LEFT PANE TAKES WHAT YOU TYPE TOO. It was a picture of the markup: the reader could see
    # the button's label and the `px-4` beside it and change neither.
    test "the drawer's HEEx pane holds the selected element's markup, and rewrites it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      assert view |> element("[data-role=pb-drawer-heex]") |> render() =~ "Contact Us"

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{
        "node_id" => heading.id,
        "source" => ~s(<h1 class="text-3xl">Talk To Us</h1>)
      })

      source = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()
      assert source =~ "Talk To Us"
      assert source =~ "text-3xl"
      refute source =~ "Contact Us"
    end

    # THE FIELD'S ID MUST MOVE WITH ITS WRAPPER. `phx-update="ignore"` means a changing wrapper id is
    # the only way new text reaches the editor — but morphdom matches by `id` first, so a CONSTANT id
    # on the textarea inside let the re-keyed wrapper adopt the old element and copy the server's
    # value over whatever had been typed. Invisibly: the textarea is hidden under CodeMirror, so the
    # screen kept showing the edit while the field that gets submitted had been reverted.
    test "the editor's field is keyed with its wrapper, not fixed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      first = view |> element("[data-role=pb-drawer-heex]") |> render()

      paragraph = node_with_tag(view, "p")
      render_click(view, "select", %{"id" => paragraph.id})
      second = view |> element("[data-role=pb-drawer-heex]") |> render()

      assert [_, one] = Regex.run(~r/id="([^"]+)"/, first)
      assert [_, two] = Regex.run(~r/id="([^"]+)"/, second)
      refute one == two, "a fixed id lets morphdom copy the server's text over what was typed"
    end

    # AN APPLY THAT CHANGED NOTHING MUST NOT LOOK LIKE ONE THAT WORKED. Re-submitting the markup a
    # node already carries used to record a history entry, mark the document dirty and broadcast —
    # so undo had a step in it that undid nothing.
    test "re-applying the same markup is not an edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      before = length(editor(view).past)
      same = Serializer.serialize_node(editor(view).tree, heading.id)

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => same})

      assert length(editor(view).past) == before
    end

    # WORDS INSIDE A COMPONENT THAT TAKES NO CHILDREN. `<.link navigate="/">Home</.link>` holds a
    # text node whose parent declares no slot, so replacing it as an element is rightly refused —
    # and retyping one word is not replacing an element.
    test "a text node's words can be rewritten inside a slotless component", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      link = ~s(<nav><.link navigate="/">Home</.link></nav>)
      render_click(view, "apply_source", %{"source" => link})

      text = node_with_kind(view, :text)
      render_click(view, "toggle_code", %{})
      render_click(view, "select", %{"id" => text.id})

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => text.id, "source" => "Start"})

      refute has_element?(view, "#pb-drawer-heex-error")
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Start"
    end

    # ONE UNDO STEP, not a delete and an insert the reader has to undo twice.
    test "rewriting an element is a single change", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      before = length(editor(view).past)

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => "<h1>Talk To Us</h1>"})

      assert length(editor(view).past) == before + 1

      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Contact Us"
    end

    # WHAT WAS TYPED SURVIVES A REFUSAL. Losing a page of hand-written markup is not a way to report
    # a missing brace — and the pane is `phx-update="ignore"`, so the text stays in the box while the
    # error is drawn under it.
    test "markup that will not parse is refused, and the document is untouched", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => "<h1>{@user.name</h1>"})

      assert view |> element("#pb-drawer-heex-error") |> render() =~ "expected closing"
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Contact Us"
    end

    # THE TOKENIZER IS NOT THE COMPILER. This tokenizes perfectly — it is a component tag like any
    # other — and 500s the first visitor, so the check that catches it is a real compile.
    @tag :slow
    test "markup that will not COMPILE is refused, and the document is untouched", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => "<h1><.no_such_thing /></h1>"})

      error = view |> element("#pb-drawer-heex-error") |> render()
      assert error =~ "undefined function no_such_thing/1"

      # The rehearsal module is called `C80201` and nothing else calls the page that.
      refute error =~ "CodeCheck.C"

      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Contact Us"
    end

    # ONE VALUE, TWO SURFACES. The Inspector sets a property, the drawer gives room to write a
    # block — but a second copy of the same CSS is a second thing to keep in step, so there is
    # only one.
    test "the drawer's CSS pane holds the same value the Inspector's box does", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 7px;"})

      assert view |> element("[data-role=pb-drawer-css]") |> render() =~ "gap: 7px"
      assert view |> element("#pb-css-text") |> render() =~ "gap: 7px"

      # And writing from the drawer reaches the Inspector's box, because there is one value and not
      # a copy of it in each surface.
      view
      |> element("#pb-drawer-css-form")
      |> render_submit(%{"node_id" => heading.id, "css" => "gap: 9px;"})

      assert view |> element("#pb-css-text") |> render() =~ "gap: 9px"
      refute view |> element("#pb-css-text") |> render() =~ "gap: 7px"
    end

    test "the drawer's CSS pane follows the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      paragraph = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 7px;"})
      assert render(view) =~ "gap: 7px"

      render_click(view, "select", %{"id" => paragraph.id})
      refute render(view) =~ "gap: 7px", "the other element's rule is not shown here"
    end

    test "the drawer's CSS pane says so when nothing is selected", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      refute has_element?(view, "[data-role=pb-drawer-css]")
      assert render(view) =~ "Select an element to write CSS for it."
    end

    # The same question the Inspector asks, asked through the same function, so the two surfaces
    # can never disagree about which elements can hold a rule.
    test "the drawer's CSS pane refuses a component that takes no class", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})
      render_click(view, "select", %{"id" => node_with_kind(view, :component).id})

      refute has_element?(view, "[data-role=pb-drawer-css]")
      assert has_element?(view, "#pb-drawer-css-note")
    end

    test "the drawer's CSS pane refuses CSS that would escape the element", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      view
      |> element("#pb-drawer-css-form")
      |> render_submit(%{"node_id" => heading.id, "css" => "gap: 1px; } body { display: none; "})

      assert has_element?(view, "#pb-drawer-css-error")
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules == %{}
    end

    # The upper Code menu. What it shows has to be what a save WRITES, which is `to_heex/1`
    # (serialised, re-parsed, formatted) and not the drawer's raw `serialize/1`.
    # ATTACHING A HOOK, NOT WRITING ONE. Writing stays on Runtime → JS hooks — the right amount of
    # friction for shipping executable JavaScript — and this saves someone hand-typing `phx-hook`
    # into Advanced and getting the compiled name's capitalisation wrong.
    test "an element can be attached to a runtime hook", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      render_click(view, "select", %{"id" => p.id})

      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks
      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})

      node = Tree.get(editor(view).tree, p.id)
      assert Node.attr(node, "phx-hook") == {:string, hook.name}
      assert has_element?(view, "#flash-info", "Hook attached.")

      # LiveView silently never mounts a hook on an element with no id.
      assert {:string, "el-" <> _rest} = Node.attr(node, "id")
    end

    test "an id the author already set is left alone", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p id="mine">One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})

      assert Node.attr(Tree.get(editor(view).tree, p.id), "id") == {:string, "mine"}
    end

    test "choosing None detaches it, and takes back only the id it minted", %{
      conn: conn,
      site: site
    } do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})
      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => ""})

      node = Tree.get(editor(view).tree, p.id)
      refute Node.attr(node, "phx-hook")
      refute Node.attr(node, "id"), "the minted id went with the hook"
      assert has_element?(view, "#flash-info", "Hook removed.")
    end

    # An id the author wrote may be the target of a link or a stylesheet, so it stays.
    test "detaching leaves an id the author wrote", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p id="mine">One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})
      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => ""})

      assert Node.attr(Tree.get(editor(view).tree, p.id), "id") == {:string, "mine"}
    end

    # A name the site does not have must not be written as though it did — a hook archived in
    # another tab, or a value posted by hand. AND IT IS SAID OUT LOUD: the refusal used to report
    # "Hook attached.", which is the sentence an author reads before going to look for the hook.
    test "a hook this site does not have is refused", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => "NotARealHook"})

      refute Node.attr(Tree.get(editor(view).tree, p.id), "phx-hook")
      assert has_element?(view, "#flash-error", "no longer available")
      refute has_element?(view, "#flash-info")
    end

    # REFUSED MEANS NOTHING CHANGES, and this is the case that cost work. An unknown name fell to
    # the same branch as None, so Apply took the attached hook off along with the minted id — which
    # a link or a stylesheet may point at — and reported success. The element had a hook a moment
    # ago and the author has no reason to check.
    test "and the hook already on the element survives it, id and all", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})
      minted = Node.attr(Tree.get(editor(view).tree, p.id), "id")
      assert {:string, "el-" <> _rest} = minted

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => "NotARealHook"})

      node = Tree.get(editor(view).tree, p.id)
      assert Node.attr(node, "phx-hook") == {:string, hook.name}
      assert Node.attr(node, "id") == minted
      assert has_element?(view, "#flash-error", "no longer available")
    end

    # AND A HOOK AN EXTENSION CONTRIBUTES APPLIES LIKE ANY OTHER. The picker read the appended list
    # and the write read the site's own rows, so a contributed hook was drawn in the select and then
    # refused by Apply — for every contribution, every time, with nothing archived anywhere.
    test "a hook an extension contributes is offered and applies", %{conn: conn, site: site} do
      {:ok, _} =
        Event.write(%{
          name: BuilderJsHookPlugin,
          event: "builder:js_hooks",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:js_hooks", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderJsHookPlugin, false) end)

      contributed = BuilderJsHookPlugin.hook()
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      offered = :sys.get_state(view.pid).socket.assigns.js_hooks

      assert contributed.name in Enum.map(offered, & &1.name)

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => contributed.name})

      assert Node.attr(Tree.get(editor(view).tree, p.id), "phx-hook") ==
               {:string, contributed.name}
    end

    # `is_global` IS A CALCULATION. Unloaded it is `%Ash.NotLoaded{}`, which is truthy, so
    # `browser_name/2` named every hook `Global…` — a site's own would have been written into
    # `phx-hook` under a name nothing registers and would silently never mount.
    test "a site's own hook is named for the site, not as a global", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "mine")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      hooks = :sys.get_state(view.pid).socket.assigns.js_hooks
      own = Enum.find(hooks, &(&1.hook == "mine"))

      refute own.global?
      refute String.starts_with?(own.name, "Global"), "got #{own.name}"
      assert String.ends_with?(own.name, "Mine")
    end

    test "a site with no hooks says so instead of showing an empty picker", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      assert render(view) =~ "pb-hook-empty"
    end

    # WHAT AN ELEMENT DOES WHEN CLICKED, without anyone writing JavaScript. Under LiveView a script
    # that changes a class is undone by the next patch that touches the element; a declared JS
    # command is part of what the server rendered and survives.
    test "an element can be given a click action", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      tree = editor(view).tree
      scope = Tree.scope(tree, section.id)
      html = Serializer.serialize(tree)

      assert html =~ ~s|phx-click={JS.toggle_class("is-open", to: ".#{scope}")}|
    end

    test "the action reads back into the panel", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "hide",
        "class" => ""
      })

      node = Tree.get(editor(view).tree, section.id)

      assert {:ok, "hide", %{}} =
               MishkaCmsCore.Runtime.PageBuilder.Interactions.read(Node.attr(node, "phx-click"))
    end

    # AIMING SURVIVES EDITING THE THING IT AIMS AT. The scope class is the entire link between a
    # button and the dialog it opens, and the inspector shows it in the target's own class box —
    # where it reads as junk and invites being typed over. Doing that used to take the aim with it:
    # the button kept a command pointing at a class nothing carried, the target `<select>` fell
    # silently back to "This element", and the next Apply overwrote the aim for good.
    test "editing the target's class does not un-aim the button", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      dialog = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => dialog.id,
        "action" => "show",
        "class" => ""
      })

      aim = Tree.scope(editor(view).tree, dialog.id)
      assert is_binary(aim)

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => dialog.id,
        "name" => "class",
        "value" => "shadow-2xl"
      })

      tree = editor(view).tree

      assert Tree.scope(tree, dialog.id) == aim, "the target lost the class the button names"

      assert Interactions.target(Node.attr(Tree.get(tree, button.id), "phx-click")) == aim

      assert Serializer.serialize(tree) =~ "shadow-2xl",
             "the author's own class was not written"
    end

    # A FIELD THAT IS NOT ON THE PAGE POSTS NOTHING, and nothing is not the same answer as "".
    # The target `<select>` renders only when the document has something to aim at, so while the
    # palette was still loading — or after it failed — pressing Apply to change the ACTION posted no
    # target at all, and "no target" meant "aim at yourself". A working "open the dialog" quietly
    # became "show this button", under a flash reading "Click action set."
    test "changing the action alone keeps the target it already had", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      dialog = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => dialog.id,
        "action" => "show",
        "class" => ""
      })

      aim = Tree.scope(editor(view).tree, dialog.id)

      # Exactly what the browser posts when the select is not rendered: no `target` key at all.
      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "action" => "hide",
        "class" => ""
      })

      written = Node.attr(Tree.get(editor(view).tree, button.id), "phx-click")

      assert Interactions.read(written) == {:ok, "hide", %{}}

      assert Interactions.target(written) == aim,
             "the aim was silently moved to the button itself"
    end

    # AND AN EMPTY ONE IS STILL AN ANSWER — the author choosing "This element" from a select that is
    # on the page. The two must not be read as the same thing.
    test "choosing This element does re-aim it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      dialog = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => dialog.id,
        "action" => "show",
        "class" => ""
      })

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => "",
        "action" => "show",
        "class" => ""
      })

      tree = editor(view).tree
      written = Node.attr(Tree.get(tree, button.id), "phx-click")

      assert Interactions.target(written) == Tree.scope(tree, button.id)
    end

    test "choosing nothing takes the action and the scope back off", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle",
        "class" => ""
      })

      assert Tree.scope(editor(view).tree, section.id)

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "",
        "class" => ""
      })

      refute Serializer.serialize(editor(view).tree) =~ "phx-click"
    end

    # SAYING SOMETHING IS THE ONE VERB THE CLIENT CANNOT DO ALONE. The other six move classes and
    # visibility around with `Phoenix.LiveView.JS`; a message is Phoenix's own flash, so this one
    # pushes and the page answers with `put_flash/3`.
    test "a click can say something", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "action" => "say",
        "kind" => "info",
        "message" => "Thanks — we'll be in touch."
      })

      written = Node.attr(Tree.get(editor(view).tree, button.id), "phx-click")

      assert Interactions.read(written) ==
               {:ok, "say", %{"kind" => "info", "message" => "Thanks — we'll be in touch."}}

      assert Serializer.serialize(editor(view).tree) =~ ~s|JS.push("pb:say"|
    end

    test "with nothing to say it changes nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "action" => "say",
        "kind" => "info",
        "message" => "   "
      })

      refute Serializer.serialize(editor(view).tree) =~ "phx-click"
    end

    # A BOX IS IDENTIFIED BY ITS NAME, NOT BY THE VERB IT WAS FILLED IN UNDER. All three class verbs
    # ask for a field called `class`, so changing your mind between them must not empty it — it did,
    # and pressing Apply then refused the whole thing for want of a class nobody had removed.
    test "changing your mind between two class verbs keeps the class", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_click(view, "save_interaction", %{
        "node_id" => heading.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_change(view, "pick_interaction", %{"action" => "add_class"})

      assert inspector_html(view) =~ ~s(id="pb-act-class"),
             "the class box is not the box the chosen verb asks for"

      assert inspector_html(view) =~ ~s(value="is-open"),
             "the author's own class was cleared by changing the verb"
    end

    # And a box the new verb does not have starts empty rather than inheriting a stranger's word.
    test "but a different box starts empty", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_click(view, "save_interaction", %{
        "node_id" => heading.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_change(view, "pick_interaction", %{"action" => "say"})
      html = inspector_html(view)

      assert html =~ ~s(id="pb-act-message")
      refute html =~ ~s(id="pb-act-class"), "the class box is drawn for a verb that wants words"
      refute html =~ ~s(value="is-open"), "a class ended up in the message box"
    end

    # THE VERB DECIDES WHICH BOX SITS UNDER IT, and the box for the verb somebody just left is a box
    # that describes the previous element. Both halves reset when the selection moves.
    test "the verb mid-pick belongs to the element it was picked on", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      other = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})
      render_change(view, "pick_interaction", %{"action" => "say"})
      assert :sys.get_state(view.pid).socket.assigns.act_action == "say"

      render_click(view, "select", %{"id" => other.id})
      assert :sys.get_state(view.pid).socket.assigns.act_action == nil
      assert :sys.get_state(view.pid).socket.assigns.aim_target == nil
    end

    # WHEN AN ELEMENT IS ON THE PAGE AT ALL. HEEx already has the feature, so the panel writes the
    # `:if` a developer would have written — and the author who later learns Elixir finds their own
    # condition in Advanced rather than a setting kept somewhere else.
    test "an element can be shown only to signed-in visitors", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => "signed_in"})

      node = Tree.get(editor(view).tree, heading.id)

      assert Conditions.read(Node.attr(node, Conditions.attribute())) == {:ok, "signed_in"}
      assert Serializer.serialize(editor(view).tree) =~ ":if="
    end

    test "and Always takes it back off", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => "said_ok"})
      assert Serializer.serialize(editor(view).tree) =~ ":if="

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => ""})
      refute Serializer.serialize(editor(view).tree) =~ ":if="
    end

    # A CONDITION IS NOT A WAY TO LOSE AN ELEMENT. The canvas renders the document, not the document
    # running, so an element that is conditionally absent on the published page is still drawn here —
    # otherwise setting the condition would be the last time its author could reach it.
    test "the canvas still draws a conditional element", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => "signed_in"})

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us", "the element the condition is on went missing from the canvas"
    end

    # CSS FOR ONE ELEMENT — the thing the panel above it cannot offer, because a panel can only
    # offer what somebody thought to add to it. Every builder in the field answers this with a
    # per-element CSS box; this one keys the rule on a class minted into the markup, so it survives
    # a save and travels with the node.
    test "an element can be given its own CSS", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "padding: 20px;\n\n&:hover { opacity: .8; }"
      })

      tree = editor(view).tree
      scope = Tree.scope(tree, section.id)

      assert scope =~ ~r/^pb-[a-f0-9]{8}$/, "the element was named"
      assert Serializer.serialize(tree) =~ scope, "and the name is in the markup"

      css = :sys.get_state(view.pid).socket.assigns.element_css_rules[scope]
      assert css =~ "padding: 20px;"
      assert css =~ "&:hover"
    end

    # A COMPONENT IS ONE NODE AND MANY ELEMENTS, and the rule is keyed on a class written into the
    # node — which reaches the DOM only if the component declares `class`. Offering the box anyway
    # took CSS that could never match anything, which is how this was found in the browser.
    test "a component that takes no class says so instead of taking CSS", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      html = render(view)
      assert html =~ "pb-css-unreachable"
      refute has_element?(view, "#pb-css-text")
    end

    # A DEAD END WITH A DOOR IN IT. Telling the reader to "put it inside a container" and leaving
    # them to work out how is the same as telling them no — the wrapper is an op the editor already
    # has, so it is offered rather than described.
    test "a component that takes no class is offered the wrapper that would work", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      assert has_element?(view, "#pb-css-wrap")
      render_click(view, "op", %{"kind" => "wrap", "node_id" => component.id, "tag" => "div"})

      wrapped = Tree.get(editor(view).tree, component.id)
      parent = Tree.get(editor(view).tree, wrapped.parent_id)

      assert parent.tag == "div"
      assert parent.id != component.id, "a new wrapper, not the one it was already in"

      render_click(view, "select", %{"id" => parent.id})
      assert has_element?(view, "#pb-css-text"), "and the wrapper can take CSS"
    end

    # `& > .badge` on a component aims a rule at markup the kit owns and the page does not. Not
    # refused — sometimes it is the only way — but said out loud, and named with the kit and version
    # so the reader knows what they are betting on.
    test "a rule reaching into a component's own markup says whose markup it is", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "badged",
        template: ~s(<div class={@class}><span class="badge">1</span></div>),
        attrs: [%{"name" => "class", "type" => "string", "opts" => %{}}],
        extra: %{"ui_kit" => "chelekom", "ui_kit_version" => "0.0.9"}
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="badged" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => component.id,
        "css" => "padding: 2px;\n&:hover { opacity: .9; }"
      })

      refute has_element?(view, "#pb-css-reaching"), "its own element and its own hover are fine"

      render_click(view, "save_element_css", %{
        "node_id" => component.id,
        "css" => "& > .badge { color: red; }"
      })

      # NOT the html `render_click` returned. Applying CSS announces the tree through the session, and
      # that message reaches this LiveView after the click handler has already replied — so the
      # snapshot the click hands back predates the panel that reads it.
      html = render(view)

      assert has_element?(view, "#pb-css-reaching")
      assert html =~ "chelekom 0.0.9", "named, so the reader knows what they are betting on"
      assert html =~ "&gt; .badge", "and which selector it was"
    end

    test "a plain tag's own markup belongs to the author, so nothing is said", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "& > .badge { color: red; }"
      })

      refute has_element?(view, "#pb-css-reaching")
    end

    test "the canvas is given the rule so it paints without a recompile", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 13px;"})

      html = render(canvas)
      assert html =~ "pb-canvas-element-css"
      assert html =~ "gap: 13px;"
    end

    test "clearing the box takes the name back off", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      assert Tree.scope(editor(view).tree, section.id)

      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => ""})

      refute Tree.scope(editor(view).tree, section.id),
             "nothing is left carrying a name for a rule that no longer exists"
    end

    # The one structural rule: the text is wrapped in `.pb-xxxxxxxx { … }`, and a `}` typed at the
    # top level closes that wrapper early and puts everything after it on the whole site.
    test "CSS that would escape the element is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      html =
        render_click(view, "save_element_css", %{
          "node_id" => section.id,
          "css" => "gap: 1px; } body { display: none; "
        })

      assert html =~ "unmatched"
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules == %{}
    end

    # A RULE IS KEYED ON A CLASS IN THE MARKUP, so deleting the element takes the only reference to
    # it away — and the rule stayed in the row, compiled into the site's stylesheet and served to
    # every visitor, for as long as the page existed. `live_rules/2` was written and tested for this
    # and had no caller at all.
    test "saving drops the CSS of an element that is no longer there", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, heading.id)

      # The stage says Draft, so the rule is held until a publish writes the markup carrying its
      # class. That publish is the one that puts it in the row for the delete below to take out.
      render_click(view, "publish", %{})

      assert stored_element_css(view, page)[scope] =~ "gap: 9px",
             "it was written in the first place"

      render_click(view, "op", %{"kind" => "delete", "node_id" => heading.id})
      render_click(view, "publish", %{})

      refute Map.has_key?(stored_element_css(view, page), scope), "the rule went with the element"
    end

    # THROUGH THE SAVE ITSELF. Paste styles used to carry the source's minted class onto the target,
    # which made the target answer with the source's name — and the prune then rewrote the row to
    # hold only the names the tree still answers with, so the author's CSS on the target went with
    # the paste. The unit tests for this ask `live_rules/2`; this one asks the row.
    test "styles pasted from one element leave the other's CSS alone", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      p = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "save_element_css", %{"node_id" => h1.id, "css" => "gap: 9px;"})
      render_click(view, "select", %{"id" => p.id})
      render_click(view, "save_element_css", %{"node_id" => p.id, "css" => "gap: 11px;"})

      source = Tree.scope(editor(view).tree, h1.id)
      target = Tree.scope(editor(view).tree, p.id)

      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})
      render_click(view, "ctx", %{"action" => "paste_styles", "node_id" => p.id})

      assert Tree.scope(editor(view).tree, p.id) == target,
             "the target still answers to its own name"

      render_click(view, "publish", %{})

      stored = stored_element_css(view, page)
      assert stored[target] =~ "gap: 11px", "the target kept the CSS the author wrote on it"
      assert stored[source] =~ "gap: 9px", "and the source's is untouched"
    end

    # Pruning against the tree in the editor rather than the tree that was saved would drop the CSS
    # of an element the author is one ⌘Z away from bringing back.
    test "an element still in the saved page keeps its CSS", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "publish", %{})

      assert stored_element_css(view, page)[scope] =~ "gap: 9px"
    end

    # WRITTEN BY ONE SESSION, READ BY THE NEXT — and both name the row through `css_owner/1`, which
    # is `ElementScopes.owner/2`. A second spelling anywhere in the round trip is an author shown an
    # empty CSS box in front of rules the page is visibly wearing, and a next save that prunes them
    # as belonging to no element at all.
    test "and is shown them again the next time the document is opened", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "publish", %{})

      {:ok, reopened, _html} = open_builder(conn, page)
      rules = :sys.get_state(reopened.pid).socket.assigns.element_css_rules

      assert Map.has_key?(rules, scope),
             "the open read a different row than the save wrote"

      assert rules[scope] =~ "gap: 9px"
    end

    # A CONTROL THAT HAS BEEN OVERRULED SAYS SO. Custom CSS is emitted last and unlayered, so where
    # the two name one property the CSS wins and dragging the control moves nothing — which, unmarked,
    # reads as a control that is broken rather than one that has been overridden.
    test "a control whose property the element's own CSS also sets is marked", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      refute has_element?(view, "#pb-css-wins-padding")

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "padding: 20px;"
      })

      assert has_element?(view, "#pb-css-wins-padding"), "the control it beats outright"
      assert has_element?(view, "#pb-css-wins-pt"), "and the longhands the shorthand swallows"
      refute has_element?(view, "#pb-css-wins-gap"), "but nothing it does not set"
    end

    # A hover rule does NOT beat `hover:p-4` — that carries a pseudo-class and therefore more
    # specificity — so the mark belongs to the bucket wearing the same selector and to no other.
    test "the mark follows the bucket the declaration was written for", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "&:hover { opacity: .5; }"
      })

      refute has_element?(view, "#pb-css-wins-opacity"), "not while Normal is the open state"

      render_click(view, "set_pseudo", %{"value" => "hover"})
      assert has_element?(view, "#pb-css-wins-opacity")
    end

    test "a declaration a control could hold is offered, and one it could not is not", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "border-image: url(x);\ngap: 4px !important;\nalign-items: center;"
      })

      assert has_element?(view, "#pb-css-movable")
      assert has_element?(view, "#pb-css-move-2"), "align-items has a control"
      refute has_element?(view, "#pb-css-move-0"), "border-image has none"
      refute has_element?(view, "#pb-css-move-1"), "and !important could not survive the move"
    end

    # THE ROW HAS TO NAME ITS LINE, or "Move to controls" is a button that moves something unnamed.
    # `phx-no-curly-interpolation` on the `<code>` printed the interpolation itself, and the author
    # read the template's own source where their declaration should have been.
    test "the movable row shows the declaration, not the interpolation", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "background-color: #dadada;"
      })

      row = view |> element("#pb-css-movable") |> render()

      assert row =~ "background-color: #dadada"
      refute row =~ "declaration.text"

      assert has_element?(view, "#pb-css-wins-background"),
             "and the control it overrules says so — once, or LiveViewTest raises on the id"
    end

    # `main { … }` parses, saves and matches nothing, so the box has no reason to refuse it and the
    # page simply does not change. The advice is the only thing that names the mistake, and it was
    # reaching the code drawer alone — `inspector/1` received it and passed it no further.
    test "advice about a selector that misses is shown in the box it was typed in", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "color: red;"
      })

      refute has_element?(view, "#pb-css-advice"), "a declaration on its own aims at the element"

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "main { color: red }"
      })

      advice = view |> element("#pb-css-advice") |> render()

      assert advice =~ "INSIDE this element"
      assert advice =~ "start the selector with"
    end

    # A BODY THAT WILL NOT PARSE HAS NO AIM TO COMMENT ON. The error and the advice share the slot
    # under the box, so the one the author has to fix first is the one that gets it.
    test "a refused body shows the error there instead of advice", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "main { color: red"
      })

      assert has_element?(view, "#pb-css-error")
      refute has_element?(view, "#pb-css-advice")
    end

    # ONE LINE, MOVED: written as the override the control holds, and taken out of the text. The two
    # never competed for storage, so nothing has to be merged — and what is left is a page that looks
    # exactly the same with one fewer place to change it.
    test "moving a declaration sets the control and takes the line out", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "align-items: center;\nborder-image: url(x);"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert Tree.get(editor(view).tree, section.id).meta.styles[:base]["align"] == "items-center"

      scope = Tree.scope(editor(view).tree, section.id)
      css = :sys.get_state(view.pid).socket.assigns.element_css_rules[scope]

      refute css =~ "align-items"
      assert css =~ "border-image", "the line it could not take is left where it was"
      refute has_element?(view, "#pb-css-wins-align"), "and the mark goes with it"

      # …and the control it landed in is on screen, on a `<section>` that is not a flex row. It was
      # not: the four flex rows were drawn only for a row, so this override had nowhere to be read
      # or undone.
      assert has_element?(view, "#pb-style-pics-base-align")

      view |> element("#pb-style-pic-base-align-items-center") |> render_click()
      assert styles_of(view, section.id) == %{}
    end

    # THE LINE THAT STARTED THIS. `#dadada` is none of the five swatches, so the swatch row showed
    # nothing selected, no field held the value, and the only way to take it off again was to clear
    # the whole bucket — a control that cannot represent what was moved into it.
    test "a moved background can be seen, changed and cleared", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "background-color: #dadada;"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert styles_of(view, section.id) == %{base: %{"background" => "#dadada"}}
      assert view |> element("#pb-style-base-background") |> render() =~ "#dadada"

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#101010"})
      assert styles_of(view, section.id) == %{base: %{"background" => "#101010"}}

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => ""})
      assert styles_of(view, section.id) == %{}
    end

    # A DECLARATION NAMES ITS OWN BUCKET, and the panel was left wherever it happened to be. The
    # State section is folded by default and carries no count, so a `&:hover` line moved into the
    # hover bucket left the author looking at a panel that had not changed.
    test "moving a hover line puts the panel on the state that holds it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "&:hover { opacity: .5; }"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert styles_of(view, section.id) == %{hover: %{"opacity" => ".5"}}
      assert has_element?(view, "#pb-state-recorded")
      assert view |> element("#pb-style-hover-opacity") |> render() =~ ~s(value=".5")
    end

    # THE AUDIT, RUN. Every line the panel offers to move has to land in a control the author can
    # then see — background landed in a swatch row with no swatch for it, and the four flex rows
    # landed on an element that drew none of them.
    test "every declaration a control can hold lands where the panel shows it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      for prop <- Styles.properties() do
        {css_prop, css_value} = Styles.declaration(prop, sample_style(prop))

        # Every property meets the same plain `<section>`: one that has moved a `display: flex` a
        # moment ago is a different element, and the four flex rows would draw for that reason
        # rather than for the value they now hold.
        render_click(view, "op", %{
          "kind" => "reset_styles",
          "node_id" => section.id,
          "bucket" => "base"
        })

        render_click(view, "save_element_css", %{
          "node_id" => section.id,
          "css" => "#{css_prop}: #{css_value};"
        })

        assert has_element?(view, "#pb-css-move-0"),
               "#{css_prop} is not offered, though #{prop} is a control"

        render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

        # `render/1` and not the click's own return: the op is announced to the LiveView rather than
        # assigned inside the handler, so the reply is drawn from the tree as it was BEFORE the move
        # and every picture row would read as missing.
        html = render(view)

        assert control_for?(html, prop),
               "#{css_prop} moved into #{prop}, and nothing on screen holds it"
      end
    end

    test "a stale index moves nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      html =
        render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "7"})

      assert html =~ "no longer there"
      scope = Tree.scope(editor(view).tree, section.id)
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules[scope] =~ "gap: 4px"
    end

    # Moving the last line empties the box, and an empty box takes the scope class back off — but
    # that class is also what an interaction on the same element points at.
    test "the name survives when a click action still points at it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert Tree.scope(editor(view).tree, section.id) == scope
      assert Serializer.serialize(editor(view).tree) =~ scope
    end

    test "and clearing the click action leaves the name when CSS still uses it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})
      scope = Tree.scope(editor(view).tree, section.id)

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "",
        "class" => ""
      })

      assert Tree.scope(editor(view).tree, section.id) == scope,
             "the rule keyed on this name is still there"
    end

    # THE PAGE'S OWN ELIXIR, in the window that already holds its markup. `events`, `infos` and
    # `helpers` have been Page attributes since the resource was written and the compiler has always
    # turned them into `handle_event/3`, `handle_info/2` and plain `def`s — the only way to reach
    # them was the Pages form, which is not where anyone is when they need a handler for the button
    # they just placed.
    test "the code window has a tab for each thing a page can hold", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      html = view |> element("#pb-code") |> render_click()

      for {id, label} <- [
            {"pb-sourcetab-template", "Template"},
            {"pb-sourcetab-events", "Handlers"},
            {"pb-sourcetab-infos", "Messages"},
            {"pb-sourcetab-helpers", "Helpers"},
            {"pb-sourcetab-styles", "Styles"}
          ] do
        assert has_element?(view, "##{id}")
        assert html =~ label
      end
    end

    # AN INDEX, NOT A FIFTH CODE BOX. An author who styled six elements had six panels to reopen to
    # find out what they had written; this lists them, and the only thing you can do to one is go to
    # the element that owns it — which is the one place it can be edited.
    test "the Styles tab lists this page's element rules", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})

      scope = Tree.scope(editor(view).tree, heading.id)
      view |> element("#pb-code") |> render_click()

      assert render_click(view, "source_tab", %{"tab" => "styles"}) =~ "gap: 11px"
      assert has_element?(view, "#pb-style-rule-#{scope}")
      assert has_element?(view, "#pb-style-rule-go-#{scope}")
    end

    test "the empty state says where to write one", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      assert render_click(view, "source_tab", %{"tab" => "styles"}) =~ "No element on this page"
    end

    # A rule whose element has been deleted is still being served. Hiding it would make the prune on
    # the next save look like the editor losing something.
    test "a rule whose element is gone is shown, and says what will happen to it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})

      scope = Tree.scope(editor(view).tree, heading.id)
      render_click(view, "op", %{"kind" => "delete", "node_id" => heading.id})

      view |> element("#pb-code") |> render_click()
      html = render_click(view, "source_tab", %{"tab" => "styles"})

      assert html =~ "saving drops this rule"
      assert has_element?(view, "#pb-style-rule-#{scope}")
      refute has_element?(view, "#pb-style-rule-go-#{scope}"), "there is nothing to select"
    end

    test "selecting from the index closes the window on the element's inspector", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})
      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "styles"})
      render_click(view, "select_from_code", %{"id" => heading.id})

      refute has_element?(view, "#pb-source-modal")
      assert editor(view).selection == heading.id
      assert :sys.get_state(view.pid).socket.assigns.left_tab == :inspector
    end

    test "a handler can be added, written and kept", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "source_tab", %{"tab" => "events"})
      assert render(view) =~ "No handlers yet"

      render_click(view, "add_code", %{"tab" => "events"})
      assert has_element?(view, "#pb-code-entry-events-0")

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "events",
          "entry" => %{"0" => %{"name" => "save", "code" => "{:noreply, socket}"}}
        })

      assert html =~ "Saved to the page"
      assert [%{"name" => "save"}] = fragments(view).events
    end

    # The wrapper is shown and not editable, because the compiler splices what is typed between
    # those two lines — an author who writes the whole clause gets a definition inside a definition.
    test "the generated wrapper is shown around the box", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      render_click(view, "add_code", %{"tab" => "events"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "entry" => %{"0" => %{"name" => "save", "code" => "{:noreply, socket}"}}
      })

      html = render(view)
      assert html =~ "def handle_event(&quot;save&quot;, params, socket) do"
    end

    test "code that will not compile is refused where it was typed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      render_click(view, "add_code", %{"tab" => "events"})

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "events",
          "entry" => %{"0" => %{"name" => "save", "code" => "{:noreply, socket"}}
        })

      assert html =~ "missing terminator"
      assert [%{"code" => "{:noreply, socket"}] = fragments(view).events, "the text is not lost"

      reloaded =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert reloaded.events == [], "nothing that will not compile reached the page"
    end

    test "a helper takes a name, an argument list and a body", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "helpers",
          "entry" => %{"0" => %{"name" => "add", "args" => "a, b", "code" => "a + b"}}
        })

      assert html =~ "Saved to the page"
      assert [%{"args" => "a, b"}] = fragments(view).helpers
    end

    test "an entry can be removed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "infos"})
      render_click(view, "add_code", %{"tab" => "infos"})

      assert has_element?(view, "#pb-code-entry-infos-0")
      render_click(view, "remove_code", %{"tab" => "infos", "index" => "0"})
      refute has_element?(view, "#pb-code-entry-infos-0")
    end

    # WRITTEN ON ITS OWN. Code is page configuration rather than document content: the draft stage
    # writes a Draft holding only the tree, so anything merely held in an assign would be lost when
    # the tab closed — and restoring an old draft would revert today's handlers.
    test "saving code writes it to the page immediately", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "helpers",
        "entry" => %{"0" => %{"name" => "shout", "args" => "t", "code" => "String.upcase(t)"}}
      })

      reloaded =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert [%{name: "shout", args: "t"}] = reloaded.helpers
    end

    test "the page source window shows what would be stored, and can be edited", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-source-modal")

      html = view |> element("#pb-code") |> render_click()
      assert html =~ "pb-source-modal"
      assert html =~ "Page code"

      {:ok, expected} =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.to_heex()

      assert render(view) =~ Phoenix.HTML.html_escape(expected) |> Phoenix.HTML.safe_to_string()

      # Editing it replaces the whole document, through the same call a draft restore makes.
      view
      |> element("#pb-source-form")
      |> render_submit(%{
        "source" => ~s(<section class="from-source"><h2>Rewritten</h2></section>)
      })

      refute has_element?(view, "#pb-source-modal")

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize() =~ "from-source"

      # …and it is one undo away, like any other edit.
      render_click(view, "undo", %{})

      refute view
             |> editor()
             |> Map.fetch!(:tree)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize() =~ "from-source"
    end

    test "unparseable source is refused without losing what was typed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      before = editor(view).tree

      view
      |> element("#pb-source-form")
      |> render_submit(%{"source" => "<div><span></div>"})

      assert has_element?(view, "#pb-source-modal"), "the window stays open"
      assert has_element?(view, "#pb-source-error")
      assert editor(view).tree == before
    end

    # The lower drawer is explicitly out of scope for this change and must still be there.
    test "the code drawer is untouched by the source window", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_code", %{})
      assert has_element?(view, "#pb-code-minimize")
      refute has_element?(view, "#pb-source-modal")
    end

    test "the command palette opens and filters", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_command", %{})
      assert has_element?(view, "#pb-command-input")
      assert has_element?(view, "#pb-cmd-publish")

      # By the command's own id, not by its text: "Publish" is also the label on the top bar's
      # button, so a whole-page text match would pass whether the palette filtered or not.
      render_change(view, "command_query", %{"value" => "undo"})
      assert has_element?(view, "#pb-cmd-undo")
      refute has_element?(view, "#pb-cmd-publish")
    end

    # The prototype's palette is two groups, and "Go to" is the real admin menu rather than a list of
    # routes retyped here — so it can never offer a page the viewer would be refused.
    test "the palette offers Go-to targets from the real admin menu", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      html = render(view)
      assert html =~ "Actions"
      assert html =~ "Go to"
      assert has_element?(view, ~s(a[href="/admin/dashboard/runtime/pages"]))
    end

    test "a query filters both groups, and no match says so", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      render_change(view, "command_query", %{"value" => "stylesheet"})
      html = render(view)
      assert has_element?(view, ~s(a[href="/admin/dashboard/runtime/stylesheets"]))
      refute html =~ "Actions"

      render_change(view, "command_query", %{"value" => "zzzznothing"})
      assert render(view) =~ "No matches."
    end

    test "a command's hint and shortcut both render", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      html = view |> element("#pb-cmd-save") |> render()
      assert html =~ "Write the draft"
      assert html =~ "⌘S"
    end

    # NOTHING SELECTED IS THE STATE THE BUILDER OPENS IN, and the palette offers "Delete selection"
    # in it — a plain button, no keyboard needed. It used to push a nil node id into the op funnel
    # and hand the author `Op.build/1`'s own complaint about the payload.
    test "a selection command with nothing selected answers in words", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)
      render_click(view, "toggle_command", %{})

      for id <- ~w(pb-cmd-delete pb-cmd-duplicate) do
        refute has_element?(clear_flashes(view), "#flash-info"), id
        view |> element("##{id}") |> render_click()

        assert flashes(view) =~ "Select an element on the page first.", id
        refute internals?(flashes(view)), id
        refute flashes(view) =~ "node_id", id
      end

      assert node_count(view) == before
    end

    test "the palette's delete removes the element that is selected", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "toggle_command", %{})

      view |> element("#pb-cmd-delete") |> render_click()
      refute node_with_tag(view, "h1")
    end

    # THE OTHER HALF OF THE SAME LEAK, and the one an author reaches by holding two elements and
    # clicking the bar above the page: the reason is a bare atom, which used to be printed as one.
    test "wrapping elements that are not side by side says so", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<header><h1>Title</h1></header><footer><a href="/x">Link</a></footer>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "a").id})

      view |> element("#pb-multi-wrap") |> render_click()

      refute internals?(flashes(view))
      assert flashes(view) =~ "side by side"
    end

    # THE WHOLE TABLE, SERVER-SIDE. The hook sends a name and nothing else — it knows nothing about
    # the selection or the clipboard — so every name it can send has to be answered in the author's
    # words: never an inspected struct, and never an internal field the author has no word for.
    #
    # The names are `PB_SHORTCUTS`' own (assets/js/admin_hooks.js), which is the whole list the two
    # key handlers and the preview bar can push. `code` and `preview` are toggles, so each is
    # pressed twice and the view ends where it started.
    test "every shortcut the hook can send is answered without internals", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)

      keys = ~w(undo redo save copy cut paste duplicate delete fit code code preview preview)

      for key <- keys ++ ["nosuchkey"] do
        clear_flashes(view)
        render_click(view, "shortcut", %{"key" => key})
        refute internals?(flashes(view)), key
        refute flashes(view) =~ "node_id", key
      end

      # None of them edits the page when nothing is selected and the clipboard is empty.
      assert node_count(view) == before

      render_click(view, "shortcut", %{"key" => "command"})
      assert has_element?(view, "#pb-command-input")

      render_click(view, "shortcut", %{"key" => "escape"})
      refute has_element?(view, "#pb-command-input")
    end

    # The toggle mirrors the PAGE, not the panels around it: an author checking a Persian or Arabic
    # layout wants the document flipped. It rides on the session, which is how it reaches the canvas
    # inside the iframe.
    # The all-breakpoints view is the whole page shown smaller — not a short window onto it. Its
    # frames therefore carry no fixed height and nothing scrolls inside them; the height is measured
    # in the browser and the box is simply the real width scaled down.
    test "each frame is a real device viewport, scaled", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      html = view |> element("#pb-framerow") |> render()

      # Each box is its real width times the zoom, and each frame is a real screen shown at it.
      assert html =~ "width:calc(1180px * var(--pb-frame-zoom))"
      assert html =~ "width:1180px;height:820px;zoom:var(--pb-frame-zoom)"
      assert html =~ "width:560px;height:844px;zoom:var(--pb-frame-zoom)"
      assert view |> element("#pb-canvas-scroll") |> render() =~ "--pb-frame-zoom:0.3"
    end

    # The frame row hugs the left edge in both directions. Centring it meant the frames slid sideways
    # as the zoom changed, and stacking them re-centred each one under the last.
    test "the frames view is left-aligned, in a row and stacked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      # The row's OWN opening tag: each frame's label line is legitimately `items-center`.
      row_class = fn -> view |> element("#pb-framerow") |> render() |> opening_tag() end

      assert row_class.() =~ "items-start"
      refute row_class.() =~ "items-center"
      assert view |> element("#pb-canvas-scroll") |> render() =~ "justify-start"

      view |> element("#pb-framedir") |> render_click()
      assert row_class.() =~ "flex-col"
      assert row_class.() =~ "items-start"
      refute row_class.() =~ "items-center"
    end

    test "a single frame stays centred", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert view |> element("#pb-canvas-scroll") |> render() =~ "justify-center"
    end

    # The zoom is the frame's `zoom` style, and the chrome scales a canvas right-click by exactly the
    # ratio that style paints — so the bounds it can reach are load bearing, not decoration.
    test "the canvas zoom steps, resets and stops at its bounds", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      note = fn -> view |> element("[data-role='pb-viewnote']") |> render() end
      frame = fn -> view |> element("#pb-canvas-scroll") |> render() |> opening_tag() end

      assert note.() =~ "100%"
      assert frame.() =~ "--pb-single-zoom:1.0"

      render_click(view, "zoom", %{"step" => "10"})
      assert note.() =~ "110%"
      assert frame.() =~ "--pb-single-zoom:1.1"

      render_click(view, "zoom_reset", %{})
      assert note.() =~ "100%"

      for _ <- 1..8, do: render_click(view, "zoom", %{"step" => "-10"})
      assert note.() =~ "40%"
      assert frame.() =~ "--pb-single-zoom:0.4"

      for _ <- 1..17, do: render_click(view, "zoom", %{"step" => "10"})
      assert note.() =~ "200%"
      assert frame.() =~ "--pb-single-zoom:2.0"

      # "Fit to screen" is the same reset under another name, from the keyboard.
      render_click(view, "shortcut", %{"key" => "fit"})
      assert note.() =~ "100%"
      assert frame.() =~ "--pb-single-zoom:1.0"
    end

    # The zoom is drawn once, as a custom property on the canvas scroll, and the frame reads it: a
    # zoom change re-renders no frame, and `PbZoom` can repaint the whole canvas with one write.
    test "the single frame reads the zoom from the canvas scroll", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 130})

      [scroll, frame] =
        view |> element("#pb-canvas-scroll") |> render() |> String.split(">", parts: 2)

      assert scroll =~ ~s(phx-hook="PbZoom")
      assert scroll =~ ~s(data-single-zoom="130")
      assert scroll =~ "--pb-single-zoom:1.3"
      assert frame =~ "zoom:var(--pb-single-zoom)"
      refute frame =~ "1.3"
      assert view |> element("[data-role='pb-viewnote']") |> render() =~ "130%"
    end

    # The buttons are stepped in the browser; the server hears the settled value once, so they carry
    # no `phx-click` of their own.
    test "the More menu zoom is a client control bounded by the server", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      controls = view |> element("#pb-zoom") |> render()

      assert opening_tag(controls) =~ ~s(phx-hook="PbZoom")
      assert opening_tag(controls) =~ ~s(data-min="40")
      assert opening_tag(controls) =~ ~s(data-max="200")
      assert opening_tag(controls) =~ ~s(data-event="zoom_set")
      refute controls =~ "phx-click"
      assert view |> element("#pb-zoom-in") |> render() =~ ~s(data-zoom-step="10")
      assert view |> element("#pb-zoom-out") |> render() =~ ~s(data-zoom-step="-10")
      assert view |> element("#pb-zoom-reset") |> render() =~ ~s(data-zoom-reset="100")

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 40})
      assert has_element?(view, "#pb-zoom-out[disabled]")
      refute has_element?(view, "#pb-zoom-in[disabled]")

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 200})
      assert has_element?(view, "#pb-zoom-in[disabled]")
      refute has_element?(view, "#pb-zoom-out[disabled]")
      assert view |> element("#pb-zoom-reset") |> render() =~ "200%"
    end

    test "zoom_set clamps to the bounds and ignores anything but an integer", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      zoom = fn -> :sys.get_state(view.pid).socket.assigns.zoom end

      set = fn value ->
        render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => value})
      end

      set.(150)
      assert zoom.() == 150

      set.(5)
      assert zoom.() == 40

      set.(900)
      assert zoom.() == 200

      set.("70")
      assert zoom.() == 70

      for garbage <- ["abc", "80px", "", 80.5, nil, true, %{"v" => 1}, [90]] do
        set.(garbage)
        assert zoom.() == 70, inspect(garbage)
      end

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{})
      assert zoom.() == 70
    end

    test "the frames view gets its own zoom and a row/column toggle", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      refute has_element?(view, "#pb-frzoom-in")

      render_click(view, "set_device", %{"device" => "frames"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "30%"

      controls = view |> element("#pb-frzoom") |> render()
      assert opening_tag(controls) =~ ~s(phx-hook="PbZoom")
      assert opening_tag(controls) =~ ~s(data-min="20")
      assert opening_tag(controls) =~ ~s(data-max="100")
      assert opening_tag(controls) =~ ~s(data-event="frame_zoom_set")
      refute controls =~ "phx-click"
      assert view |> element("#pb-frzoom-in") |> render() =~ ~s(data-zoom-step="10")
      assert view |> element("#pb-frzoom-out") |> render() =~ ~s(data-zoom-step="-10")
      assert view |> element("#pb-frzoom-reset") |> render() =~ ~s(data-zoom-reset="100")

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 40})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "40%"

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 100})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "100%"

      assert view |> element("#pb-framedir") |> render() =~ "In a row"
      view |> element("#pb-framedir") |> render_click()
      assert view |> element("#pb-framedir") |> render() =~ "Stacked"
    end

    test "zoom stops at the prototype's bounds", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      for _ <- 1..12, do: render_click(view, "frame_zoom", %{"step" => "-10"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "20%"
      assert has_element?(view, "#pb-frzoom-out[disabled]")

      for _ <- 1..14, do: render_click(view, "frame_zoom", %{"step" => "10"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "100%"
      assert has_element?(view, "#pb-frzoom-in[disabled]")
      refute has_element?(view, "#pb-frzoom-out[disabled]")
    end

    test "frame_zoom_set clamps to the bounds and ignores anything but an integer", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})
      zoom = fn -> :sys.get_state(view.pid).socket.assigns.frame_zoom end

      set = fn value ->
        render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => value})
      end

      set.(60)
      assert zoom.() == 60

      set.(0)
      assert zoom.() == 20

      set.(400)
      assert zoom.() == 100

      set.("50")
      assert zoom.() == 50

      for garbage <- ["abc", "60%", "", 60.0, nil, false, %{"v" => 1}, [70]] do
        set.(garbage)
        assert zoom.() == 50, inspect(garbage)
      end

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{})
      assert zoom.() == 50
    end

    # The frames never carry the zoom themselves: a zoom change rewrites the one custom property on
    # the canvas scroll and leaves every frame's markup exactly as it was.
    test "the frames read the zoom from the canvas scroll", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})
      row = view |> element("#pb-framerow") |> render()

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 60})

      scroll = view |> element("#pb-canvas-scroll") |> render() |> opening_tag()

      assert view |> element("#pb-framerow") |> render() == row
      assert scroll =~ ~s(data-frame-zoom="60")
      assert scroll =~ "--pb-frame-zoom:0.6"
      refute row =~ "zoom:0."
    end

    # The frame matching the breakpoint being edited is ringed and names the selection, so the row
    # doubles as a reminder of where an override would land.
    test "the frame for the breakpoint being edited is marked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "set_device", %{"device" => "frames"})

      html = view |> element("#pb-framerow") |> render()
      assert html =~ "border-[#8481de]"
      assert html =~ "&lt;h1&gt;"

      render_click(view, "set_breakpoint", %{"value" => "mobile"})
      assert view |> element("#pb-framerow") |> render() =~ "border-[#8481de]"
    end

    test "the direction toggle flips the canvas, not the editor chrome", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-dir-rtl") |> render_click()

      assert editor(view).dir == "rtl"

      # The chrome's own root tag only — `phx-value-dir="rtl"` on the toggle itself contains that
      # same string, so a whole-page match would pass no matter what.
      [_before, after_id] = view |> render() |> String.split("pb-root", parts: 2)
      [opening_tag, _rest] = String.split(after_id, ">", parts: 2)
      refute opening_tag =~ "dir="

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ ~s(dir="rtl")

      view |> element("#pb-dir-ltr") |> render_click()
      assert editor(view).dir == "ltr"
    end

    # Preview has to reach the CANVAS — that is where the outlines, chips and floating toolbar are
    # drawn. Held in the chrome, the button lit up and the page looked exactly the same.
    # Preview cleans the CANVAS — outlines, chips, the floating toolbar, the drop tail — and leaves
    # the editor around it alone, which is what the prototype does. Folding the panels away as well
    # made "see the page without chrome" mean "leave the editor", and there is a full-page preview
    # for that already.
    # Under 900px both panels are gone, so the bar is the only way to reach them. Four of its tabs
    # are overlays rather than panels, and one is the direction toggle.
    # Searching and filtering the library belong to the Gervaz table now — they are declared on
    # `Runtime.Media` and work the same here as on the Media page. What this pins is that the sheet
    # did not quietly lose them by mounting the component without its chrome.
    test "the library keeps the resource's own search and filters", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_media!(site_id: site.id, name: "hero-bg", type: :images)
      create_media!(site_id: site.id, name: "team-photo", type: :images)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "hero-bg"
      assert html =~ "team-photo"

      state = :sys.get_state(view.pid).socket.assigns
      refute state[:media_query], "the sheet no longer keeps a search of its own"
    end

    test "the registry search narrows the package list", %{conn: conn, page: page} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      assert has_element?(view, "#pb-pkg-chelekom-datatable")

      render_keyup(view, "studio_query", %{"value" => "charts"})

      refute has_element?(view, "#pb-pkg-chelekom-datatable")
      assert has_element?(view, "#pb-pkg-chelekom-charts")
    end

    # The mock adapter cannot install anything and says so; the button must surface that rather than
    # looking like it worked.
    # The default adapter is the kits on disk, so Install is a real operation: it adds the component
    # AND what it depends on, and the palette has to notice — a component you cannot then place is
    # not installed as far as the author is concerned.
    test "Install adds the component, its dependencies, and the palette entry", %{
      conn: conn,
      page: page,
      site: site
    } do
      # The on-disk kits adapter, named explicitly: the shipped default is the prototype's sample
      # catalogue, which by design has nothing real to install.
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      refute has_element?(view, "#pb-comp-chelekom-card")

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      # A master is asked where it lands; "This site" is the answer this test is about.
      view |> element("#pb-pkg-install-site-chelekom-card") |> render_click()

      html = render(view)
      assert html =~ "chelekom-card installed"

      # `card` draws an icon, so the flash says what came with it rather than only what was clicked.
      assert html =~ "it depends on"

      names = site_component_names(site)
      assert "chelekom-card" in names
      assert "chelekom-icon" in names

      # …and it is placeable now, without a reload.
      assert has_element?(view, "#pb-comp-chelekom-card")
    end

    # WHO INSTALLED IT. Every row the Registry writes went in with `authorize?: false`, so the
    # Component policy never ran on the one surface in the admin that installs a package, and its
    # version history recorded nobody. The site it lands on was already derived from the actor —
    # `UiKitHandler.install_scope/2` — and now the write is theirs too.
    test "Install is written as the admin who pressed it", %{conn: conn, page: page, site: site} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      actor = :sys.get_state(view.pid).socket.assigns.current_user
      assert is_nil(actor.site_id), "this suite logs in a master"

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      # WHAT THIS CLICK WROTE, and not what the fixture did: everything already on this site was
      # written by a seed or a fixture with no actor, which is correct and is not what is on trial.
      before = MapSet.new(component_versions(site), & &1.id)

      view |> element("#pb-pkg-install-site-chelekom-card") |> render_click()

      written = Enum.reject(component_versions(site), &MapSet.member?(before, &1.id))

      refute written == [], "the install wrote no component versions at all"

      assert Enum.all?(written, &(&1.user_id == actor.id)),
             "a component this admin installed is attributed to nobody in its own history"
    end

    # AND THE SECOND GATE IS THE RESOURCE'S OWN. `install_scope/2` decides WHICH site a package may
    # land on; whether this actor may write a component there at all is `Component`'s policy, and
    # with the write unauthorized it was never asked. Driven below the LiveView because nobody who
    # fails that policy can open the builder in the first place — which is exactly why the write
    # had never been tested against it.
    test "Install is refused to an actor the component resource refuses", %{site: site} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      nobody = create_user_without_permissions("registry-nobody@example.com")

      assert_raise Ash.Error.Forbidden, fn ->
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.install(
          :package,
          "chelekom-card",
          site.id,
          nobody
        )
      end

      refute "chelekom-card" in site_component_names(site),
             "a refused install left components behind"
    end

    test "Install reports what the configured registry can actually do", %{conn: conn, page: page} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      view |> element("#pb-pkg-install-site-chelekom-charts") |> render_click()

      assert render(view) =~ "cannot be installed from the mock registry"
    end

    # An audit that only lists failures reads as "not checked". The prototype lists what passed too,
    # and a green row here means a real check ran over the real document.
    test "the audit lists what passed, not only what failed", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>Title</h1><a href="/x">Read more</a></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Interactive elements are labelled"
      assert html =~ "Page opens at h1"
      # A pass is not an issue, and it has nothing to fix.
      assert html =~ "healthy"
      refute has_element?(view, "#pb-audit-fix-ok-link-text")
    end

    test "a failed check replaces its passing row", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>T</h1><a href="/x"></a></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Link has no visible text"
      refute html =~ "Interactive elements are labelled"
    end

    test "a preset card offers Apply for free presets and Unlock for paid ones", %{
      conn: conn,
      page: page
    } do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-presets") |> render_click()

      assert has_element?(view, "#pb-preset-apply-editorial")
      assert has_element?(view, "#pb-preset-unlock-docs-portal")
      # Paid presets are the ones that carry the lock, so the two must agree.
      refute has_element?(view, "#pb-preset-apply-docs-portal")

      # The button is honest about the adapter rather than silently doing nothing.
      view |> element("#pb-preset-apply-editorial") |> render_click()
      assert render(view) =~ "Connect a registry"
    end

    test "the mobile bar swaps the body for the panel it names", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      # Nothing is duplicated: the same panels are re-pointed by the media query, so the layers panel
      # is the one that was already there.
      assert view |> element("#pb-right") |> render() =~ "max-[900px]:hidden"

      view |> element("#pb-mobtab-layers") |> render_click()

      assert view |> element("#pb-right") |> render() =~ "max-[900px]:flex"
      assert view |> element("#pb-left") |> render() =~ "max-[900px]:hidden"
      assert has_element?(view, "#pb-layers")

      view |> element("#pb-mobtab-canvas") |> render_click()
      assert view |> element("#pb-right") |> render() =~ "max-[900px]:hidden"
    end

    test "a mobile panel tab also selects that panel's tab", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-mobtab-inspector") |> render_click()

      assert has_element?(view, "#pb-lefttab-inspector.bg-white")
    end

    test "the mobile bar's overlay tabs open overlays, not panels", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-mobtab-assets") |> render_click()
      assert has_element?(view, "#pb-sheet")
      refute has_element?(view, "#pb-mobpanel")

      view |> element("#pb-mobtab-palette") |> render_click()
      assert has_element?(view, "#pb-command")
    end

    test "the mobile bar's direction tab flips the canvas", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert editor(view).dir == "ltr"

      view |> element("#pb-mobtab-dir") |> render_click()

      assert editor(view).dir == "rtl"
      assert view |> element("#pb-mobtab-dir") |> render() =~ "RTL"
    end

    test "preview strips the canvas's editor overlays and keeps the panels", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ "pb-el-toolbar"

      view |> element("#pb-preview") |> render_click()

      assert editor(view).preview?
      refute render(canvas) =~ "pb-el-toolbar"
      refute render(canvas) =~ "pb-canvas-tail"
      assert has_element?(view, "#pb-left")
      assert has_element?(view, "#pb-right")
      assert has_element?(view, "#pb-code-strip")

      view |> element("#pb-preview") |> render_click()

      refute editor(view).preview?
      assert has_element?(view, "#pb-left")
      assert render(canvas) =~ "pb-el-toolbar"
    end

    # A comment renders nothing on the live page, so preview must not show one — not even one the
    # author unfolded. An expression is the opposite: something real will be there, and hiding its
    # chip would show a gap the page lacks.
    test "preview hides comment chips but keeps expression chips", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><%!-- EDITORNOTE --%><p><%= @title %></p><!-- HTMLNOTE --></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      for kind <- [:eex_comment, :html_comment] do
        render_click(view, "toggle_hidden", %{"id" => node_with_kind(view, kind).id})
      end

      unfolded = render(canvas)
      assert unfolded =~ "EDITORNOTE"
      assert unfolded =~ "HTMLNOTE"

      view |> element("#pb-preview") |> render_click()

      previewed = render(canvas)
      refute previewed =~ "EDITORNOTE"
      refute previewed =~ "HTMLNOTE"
      assert previewed =~ "@title"
    end

    # A COMMENT IS A NOTE TO THE AUTHOR, not a thing on the page, so its chip starts folded and the
    # eye on its layers row is what unfolds it. An expression is the opposite — something real WILL
    # render there — so its chip is drawn from the first paint.
    test "comment chips start folded and the eye unfolds one", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><%!-- EDITORNOTE --%><p><%= @title %></p><!-- HTMLNOTE --></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "EDITORNOTE"
      refute html =~ "HTMLNOTE"
      assert html =~ "@title", "an expression is not a comment"

      render_click(view, "toggle_hidden", %{"id" => node_with_kind(view, :eex_comment).id})

      unfolded = render(canvas)
      assert unfolded =~ "EDITORNOTE"
      refute unfolded =~ "HTMLNOTE", "the other note was not asked for"
    end

    # A FOLDED NODE IS STILL A DOM CHILD. The canvas drop resolver reads an insertion index by
    # counting `[data-node-id]` children in order, so a folded note that left no trace would land the
    # next drop one position early — and `data-ws` is what stops it counting as content, or the `div`
    # holding nothing but a note would never get its drop floor.
    test "a folded comment keeps its place among the canvas children", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><!-- HTMLNOTE --><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      note = node_with_kind(view, :html_comment)

      assert html =~ ~s(data-node-id="#{note.id}"), "the slot is still a DOM child"
      assert html =~ ~s(data-ws="true" data-folded="true")
      assert html =~ ~s([data-folded="true"] { display: none; })
      refute html =~ "HTMLNOTE", "but nothing of it is drawn"
      refute html =~ ~s(phx-value-id="#{note.id}"), "and it cannot be clicked on the canvas"
    end

    # THE ROW IS THE WAY BACK. Fold the chip and the tree must still say the note is there, or the
    # only thing left pointing at it is the saved source.
    test "a comment's layers row is listed with its eye already off", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<div><%!-- EDITORNOTE --%><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      note = node_with_kind(view, :eex_comment)

      row = view |> element(~s([data-layer-row="#{note.id}"])) |> render()
      assert row =~ "Show on canvas"
      refute row =~ "Fold away on canvas"

      sibling = view |> element(~s([data-layer-row="#{node_with_tag(view, "p").id}"])) |> render()

      assert sibling =~ "Fold away on canvas",
             "nothing changed for anything that is not a comment"

      render_click(view, "toggle_hidden", %{"id" => note.id})

      assert view |> element(~s([data-layer-row="#{note.id}"])) |> render() =~
               "Fold away on canvas"
    end

    test "an open canvas follows the direction without being reloaded", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ ~s(dir="ltr")

      view |> element("#pb-dir-rtl") |> render_click()

      assert render(canvas) =~ ~s(dir="rtl")
    end

    # Filtering the view must not change which point in history a Revert button restores — the index
    # stays the one from the full list.
    test "the history sheet filters by kind without moving the revert points", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      # THE ROW IS WRITTEN ASYNCHRONOUSLY, so the delete has to be flushed before the next op or the
      # sheet opens over a list this one has not reached yet — which is what made this test pass in
      # file order and fail on its own. Its neighbour below already flushes for the same reason.
      _flushed = render_async(view)

      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => p.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "8px"
      })

      render_click(view, "open_sheet", %{"sheet" => "history"})

      html = render_async(view)
      assert html =~ "Every change to this page"
      assert html =~ "Deleted element"
      assert html =~ "Set gap (base)"

      # The pills are the resource's own filter, so they are driven the way Gervaz drives it rather
      # than by a bespoke event — and a row keeps its own id, so nothing depends on its position.
      styled = filter_history(view, "style")
      assert styled =~ "Set gap (base)"
      refute styled =~ "Deleted element"

      content = filter_history(view, "content")
      assert content =~ "Deleted element"
      refute content =~ "Set gap (base)"
    end

    test "a filter that matches nothing offers nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      _flushed = render_async(view)

      render_click(view, "open_sheet", %{"sheet" => "history"})
      assert render_async(view) =~ "Deleted element"

      # One content change and no style change: the style pill has to come back with nothing to
      # restore, rather than with the content row it was asked to exclude.
      styled = filter_history(view, "style")

      assert styled =~ "No changes recorded yet"
      refute styled =~ "Deleted element"
      refute styled =~ "history_revert"
    end

    test "the history sheet lists the session's edits", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      _flushed = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "history"})

      assert render_async(view) =~ "Deleted element"
    end

    test "collapsing a panel hides it and leaves a rail", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_left", %{})
      refute has_element?(view, "#pb-left")
      assert render(view) =~ "Components"
    end
  end
end
