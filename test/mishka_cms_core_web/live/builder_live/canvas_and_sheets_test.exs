# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.CanvasAndSheetsTest do
  @moduledoc """
  The builder's mount, its canvas LiveView, and the Studio, Assets and Review sheets.
  """
  use MishkaCmsCore.BuilderLiveCase

  describe "mount" do
    test "renders the editor shell", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-root")
      assert has_element?(view, "#pb-left")
      assert has_element?(view, "#pb-right")

      # The top bar has the prototype's stage split-button and no Save — the editor autosaves, and
      # "Save draft now" lives in the ••• menu, which is folded away in the markup rather than
      # fetched: `#pb-more-btn` toggles it in the browser and never reaches this process.
      assert has_element?(view, "#pb-stage")
      assert has_element?(view, "#pb-stage-menu")
      assert has_element?(view, "#pb-more-menu.hidden")
      assert view |> element("#pb-more-btn") |> render() =~ "#pb-more-menu"

      assert has_element?(view, "#pb-save")
      assert has_element?(view, "#pb-undo")
      assert has_element?(view, "#pb-redo")
    end

    # The editor takes the whole viewport, like the prototype: no admin sidebar, no admin topbar, no
    # 1340px content column. It is a `h-screen` three-column workspace, and nesting it in the admin
    # shell's scrolling, padded, width-capped `<main>` costs it the canvas and adds a second
    # scrollbar. Every other admin page keeps the shell — this is the one exception, so it is pinned.
    test "the editor is a full page: no admin sidebar, topbar or content column", %{
      conn: conn,
      page: page
    } do
      {:ok, view, html} = open_builder(conn, page)

      refute has_element?(view, "#admin-sidebar")
      refute html =~ "max-w-[1340px]"
      refute html =~ "Admin console"

      # The shell's own two contributions are still there: the theme treatment and flashes.
      assert html =~ "data-theme=dark"
      assert has_element?(view, "#pb-root")
    end

    test "an error still surfaces without the admin shell's flash group", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{"kind" => "delete", "node_id" => "nnotanode"})

      assert has_element?(view, "#flash-error")
    end

    test "parses the page's template into a session tree", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      tags = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.tag)

      assert "section" in tags
      assert "h1" in tags
      assert "p" in tags
    end

    test "embeds the canvas iframe addressed by the session token", %{conn: conn, page: page} do
      {:ok, view, html} = open_builder(conn, page)

      assert html =~ "/admin/dashboard/runtime/builder-canvas/#{token(view)}"
      assert has_element?(view, "#pb-frame-desktop")
    end

    test "every device button is present", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      for device <- ~w(frames desktop tablet mobile) do
        assert has_element?(view, "#pb-device-#{device}")
      end
    end

    test "an unknown section redirects instead of crashing", %{conn: conn} do
      assert {:error, {:redirect, _redirect}} =
               live(conn, "/admin/dashboard/runtime/builder/spreadsheet")
    end

    test "a new page opens an empty document", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")

      assert view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) == []
    end
  end

  describe "the canvas LiveView" do
    # WHAT AN EMPTY PAGE OFFERS. The dashed well this replaces told the reader to "pick a
    # component on the left", which asks someone who has never built a page to already know what the
    # first thing should be. The chooser answers that question once and then gets out of the way.
    test "an empty page offers the starter, and picking one fills it", %{conn: conn, site: site} do
      empty =
        create_page!(
          site_id: site.id,
          template: MishkaCmsCore.Runtime.PageBuilder.PageStarter.blank()
        )

      {:ok, view, _html} = open_builder(conn, empty)

      # Emptied right back out — the same state a page created with no markup opens in once its one
      # container is removed.
      render_click(view, "op", %{"kind" => "delete", "node_id" => hd(editor(view).tree.roots)})
      assert editor(view).tree.roots == []

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-page-starter"
      assert html =~ "This page is empty"
      assert html =~ "pb-starter-two"
      refute html =~ "Choose a layout", "Runtime's Layout is a different thing entirely"

      render_click(canvas, "page_starter", %{"structure" => "two"})

      tree = editor(view).tree
      assert length(tree.roots) == 1, "a structure arrives as ONE undoable insert"
      assert MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize(tree) =~ "grid-cols-2"
    end

    # AND A STARTER AN EXTENSION BROUGHT IS ONE OF THEM. The chooser has always drawn the merged
    # list, while the click was resolved against the core's four alone — so a plugin's card was a
    # button with nothing behind it: no structure, no error, and nothing in the log either.
    test "a contributed starter lays out its own structure", %{conn: conn, site: site} do
      register_plugin(PageStarterPlugin, "builder:page_starters")
      structure = PageStarterPlugin.structure()

      empty = create_page!(site_id: site.id, template: PageStarter.blank())
      {:ok, view, _html} = open_builder(conn, empty)
      render_click(view, "op", %{"kind" => "delete", "node_id" => hd(editor(view).tree.roots)})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-starter-#{structure.id}")
      assert has_element?(canvas, "#pb-starter-two"), "beside the core's own"

      canvas |> element("#pb-starter-#{structure.id}") |> render_click()

      tree = editor(view).tree
      assert length(tree.roots) == 1, "a structure arrives as ONE undoable insert"
      assert Serializer.serialize(tree) =~ "grid-cols-[2fr_1fr]"
    end

    test "an unknown structure is a no-op, not a crash", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      before = editor(view).tree
      render_click(canvas, "page_starter", %{"structure" => "no-such-thing"})
      assert editor(view).tree == before
    end

    # A page with something on it is a page someone is already working on.
    test "a page with content is not interrupted by the chooser", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ ~s(id="pb-page-starter")
    end

    # THE FORMATTER PUTS A NEWLINE BETWEEN EVERY PAIR OF CHILDREN, so a grid authored tight comes
    # back from its first save with a whitespace run between each card. Those runs are real nodes and
    # cannot be dropped — `<a>one</a> <a>two</a>` would lose its space — but a box around one is a
    # grid ITEM: an empty cell in the middle of the card row, selectable, and with nothing in the
    # layers panel to match it, because the panel has always hidden them.
    #
    # They stay in the DOM: the drop resolver counts DOM children to work out an insertion index, so
    # a child missing here shifts every index after it.
    test "indentation between tags gets no box of its own", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: "<div class=\"grid\">\n  <p>One</p>\n  <p>Two</p>\n</div>"
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      nodes = Tree.walk(editor(view).tree)
      blanks = Enum.filter(nodes, &(&1.kind == :text and &1.meta[:whitespace?]))

      assert length(blanks) == 3, "the fixture is indented, so the grid has runs around each <p>"

      for node <- blanks do
        assert html =~ ~s(data-node-id="#{node.id}"), "the run must still be a DOM child"
        refute html =~ ~s(phx-value-id="#{node.id}"), "and must not be selectable"
      end

      # `display: contents` is a rule in `#pb-canvas-ui` now rather than a `style` attribute — a
      # Content-Security-Policy has no nonce to offer an attribute — so the marker the rule is keyed
      # on is what there are three of.
      assert length(String.split(html, ~s(data-kind="text" data-ws="true"))) - 1 == length(blanks)
      assert html =~ ~s([data-ws="true"] { display: contents; })

      words = Enum.find(nodes, &(&1.kind == :text and &1.text == "One"))
      assert html =~ ~s(phx-value-id="#{words.id}"), "text with words in it is still selectable"
    end

    # AND A CONTAINER THAT HAS BEEN EMPTIED IS STILL EMPTY. Taking the last thing out of one leaves
    # the indentation that used to sit around it, so `children` reads as a list of blanks rather than
    # `[]` — and the floor that makes a 0px box droppable disappeared at the exact moment it was
    # needed most.
    test "a container holding nothing but indentation still gets a floor", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: "<section id=\"hero\">\n</section>")

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      tree = editor(view).tree
      [root] = tree.roots

      assert Tree.get(tree, root).children != [], "the fixture is meant to keep its newline"
      assert html =~ "min-height:56px", "the emptied section needs somewhere to aim"
    end

    # THE CANVAS DOES NOT WANT THE ADMIN'S STYLESHEET. It renders a SITE's document, and its own
    # chrome — the selection ring, the component chip, the "needs id" placeholder — is inline styles
    # computed from session state. It used to download all 2.5 MB of `admin.css` anyway, because one
    # `full_tailwind` assign gated the stylesheet and the two web fonts together, and the frames view
    # mounts three of these iframes at once.
    #
    # Asserted on the ASSIGNS rather than the rendered head: the root layout belongs to the host app,
    # which the test endpoint does not use. The layout's half of the contract is one `:if` per link
    # (`assigns[:admin_css]`, `assigns[:admin_fonts]`, `assigns[:live_tailwind]`), so pinning what the
    # canvas sets pins what it loads.
    # AN IFRAME IS BLANK UNTIL ITS DOCUMENT PAINTS, and the canvas frame loads a whole LiveView —
    # with nothing behind it the editor shows an empty rectangle and no reason for the wait. The
    # spinner sits UNDER the frame rather than replacing it: swapping the element out would restart
    # the load, so it could never finish.
    test "the canvas frame shows why it is empty while it loads", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert html =~ "Loading the canvas",
             "the canvas frame renders with nothing to explain the blank rectangle"
    end

    test "asks for fonts and the generator, never the admin stylesheet", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assigns = :sys.get_state(canvas.pid).socket.assigns

      refute assigns[:admin_css], "the canvas must not pull the dashboard's stylesheet"
      assert assigns[:admin_fonts], "its chrome names the admin faces in inline `font:` shorthand"
      assert assigns[:live_tailwind], "a class typed in the inspector must exist a frame later"
    end

    # THE FAST WAY TO THE ONE THING PEOPLE CHANGE. Everything else on the element toolbar acts at
    # once; layout is a choice, so the bar grows a row of shapes rather than sending the reader off
    # to the Inspector. It offers only what the component itself declares.
    test "the toolbar's layout button opens column shapes for a grid", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "tbgrid",
        template: ~s|<div class="grid">g</div>|,
        attrs: [
          %{
            "name" => "cols",
            "type" => "string",
            "opts" => %{"values" => ~w(one two three four), "default" => "two"}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-tbgrid") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-eltb-layout"), "the four-way arrow is on the toolbar"

      # The row is RENDERED with the selection and revealed in the browser — asking the server to
      # show a row already on the page would patch the toolbar and drop it out of the top layer.
      assert has_element?(canvas, "#pb-eltb-cols"), "the row ships with the selection"

      assert render(canvas) =~ "#pb-eltb-cols { display: none;",
             "and starts hidden, for the hook to open"

      assert has_element?(canvas, "#pb-eltb-cols-four")

      refute render(canvas) =~ ~s(id="pb-eltb-layout" phx-click),
             "the arrow carries no server event at all"

      # THE VALUE MUST RIDE THE BUTTON'S OWN `value`. LiveView's `extractMeta` writes
      # `meta.value = el.value` AFTER collecting `phx-value-*`, so `phx-value-value` on a button is
      # always overwritten with "". `render_click/1` sends the attribute map WITHOUT that override,
      # so it passes either way — this is the only thing that catches it.
      shape = canvas |> element("#pb-eltb-cols-four") |> render()

      assert shape =~ ~s(value="four"),
             "the shape carries its value where the browser will read it"

      refute shape =~ "phx-value-value", "and never where the browser will blank it"

      # THE PANEL MUST OUTLIVE A CHOICE. Choosing writes to the document, so the server re-renders
      # this element — and a patch takes back the `display` the hook wrote, leaving the rule's own
      # `none` underneath. The hook holds the open flag and re-applies it in `placeToolbar`, which
      # `updated()` already calls, so a reader can try six options without reopening between each
      # one. All the server may ever say is "shut"; rendering it open would fight the browser for
      # the same property.
      assert render(canvas) =~ "#pb-eltb-cols { display: none;",
             "the server always renders the panel shut and never tries to render it open"

      canvas |> element("#pb-eltb-cols-four") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Map.fetch!(:attrs)
             |> Map.new()
             |> Map.get("cols") == {:string, "four"}
    end

    # DIRECTION, SPREAD, ALIGN AND WRAP, each drawn as a picture of what it does — and each writing
    # the same `:set_style` op the Inspector writes, so the two panels cannot disagree and the
    # Tailwind class is `Styles`' business rather than the toolbar's.
    test "the layout panel writes flex classes into the chosen breakpoint", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # Direction only means something once the container is a row, so it appears with it.
      refute has_element?(canvas, "#pb-eltb-direction-flex-row")
      canvas |> element("#pb-eltb-display-flex") |> render_click()
      assert has_element?(canvas, "#pb-eltb-direction-flex-row")

      canvas |> element("#pb-eltb-justify-justify-between") |> render_click()
      canvas |> element("#pb-eltb-align-items-center") |> render_click()

      assert styles_of(view, node.id) == %{
               base: %{
                 "display" => "flex",
                 "justify" => "justify-between",
                 "align" => "items-center"
               }
             }

      # …and the same control, aimed at Mobile, writes a bucket of its own.
      canvas |> element("#pb-eltb-at-mobile") |> render_click()
      canvas |> element("#pb-eltb-direction-flex-col") |> render_click()

      assert styles_of(view, node.id)[:mobile] == %{"direction" => "flex-col"}
    end

    # Pressing the chosen one again clears it, so an element can go back to inheriting.
    test "choosing the same layout option twice clears it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      canvas |> element("#pb-eltb-display-grid") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"display" => "grid"}}

      canvas |> element("#pb-eltb-display-grid") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    # A DEAD BUTTON IS WORSE THAN NO BUTTON. Display works on any element, so the arrow always has
    # something to show; column shapes follow only when the component says which counts it lays out.
    test "a plain element still gets a layout row, without columns", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-eltb-display-flex"), "display is offered on anything"
      refute has_element?(canvas, "#pb-eltb-cols-four"), "but a section has no column count"

      canvas |> element("#pb-eltb-display-grid") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> then(& &1.meta.styles) == %{base: %{"display" => "grid"}}
    end

    # The composer is a Gervaz form: `phx-submit="save"` on the component, params under "form".
    #
    # The trailing `render/1` is not decoration. Saving sends `{:form_saved, …}` to the LiveView, and
    # the badge is recomputed when THAT is handled — one message after the submit's own reply. Without
    # a render in between, the test client is still holding the HTML from before the note existed.
    # THE THREAD RE-READS ASYNCHRONOUSLY. Gervaz loads through `start_async`, so the note is in the
    # database before it is in the HTML; `render_async/1` is the wait, and the only alternative is a
    # sleep that is either flaky or slow.
    defp post_note(view, body, type) do
      view
      |> element("#pb-comment-form")
      |> render_submit(%{"form" => %{"body" => body, "type" => type}})

      render_async(view)
    end

    # A REPLY IS POSTED WITH ONLY A BODY, on purpose. In reply mode the composer has no type select
    # — it has a hidden `information` — so passing a type here would test the test's opinion rather
    # than the form's.
    defp post_reply(view, body) do
      view
      |> element("#pb-comment-form")
      |> render_submit(%{"form" => %{"body" => body}})

      render_async(view)
    end

    # THE BADGE, READ OFF A FRESH RENDER. `element/2` renders from the HTML the test client last
    # applied a diff to, and the count changes when `{:form_saved, …}` is HANDLED — one message after
    # the event's own reply — so the element path reads the value from before the note existed.
    defp review_badge(view) do
      case Regex.run(~r/pb-review-count[^>]*>\s*(\d+)\s*</s, render(view)) do
        [_all, count] -> count
        nil -> nil
      end
    end

    # The avatar letters and the name on a note's first line.
    defp byline(view, note) do
      [avatar, name | _rest] =
        view
        |> element("#pb-comment-#{note.id} > div:first-child")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("span")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      {avatar, name}
    end

    defp note_mentions(view, note),
      do:
        view
        |> element("#pb-comment-#{note.id} > p")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="pb-mention"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    defp resolver_line(view, note),
      do:
        view
        |> element("#pb-comment-resolver-#{note.id}")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.split()
        |> Enum.join(" ")

    # What actually landed in the database, newest first — the only thing that can prove a note
    # outlives the session that wrote it.
    defp notes(site, document) do
      MishkaCmsCore.Runtime.PageBuilder.Review.list(%{
        site_id: site.id,
        section: :page,
        document_id: document.id
      })
    end

    # The builder SHELL is admin chrome and keeps all three.
    test "the builder shell keeps the admin stylesheet", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns[:admin_css]
      assert assigns[:admin_fonts]
      assert assigns[:live_tailwind]
    end

    # A heroicon is a CLASS with no glyph in the markup — `<span class="hero-wrench-screwdriver">`
    # and a CSS mask. The canvas emits the rules for the icons it is about to render, and it derived
    # them from the tree in the EDITING session, then let the preview swap the tree without swapping
    # the rules. So an example's icon appeared only when the page underneath happened to use the
    # same one: `chelekom-alert`'s maintenance example asks for `hero-wrench-screwdriver`, the page
    # did not, and the reader saw a blank space beside the heading with the class sitting there in
    # the code pane.
    test "an example's own icons get their rules, not the edited page's", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "iconic",
        template: "<div><span class={@icon}></span>{render_slot(@inner_block)}</div>",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}],
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}],
        extra: %{
          "examples" => [
            %{
              "source" =>
                ~s(<.component component_name="iconic" site="#{site.name}" icon="hero-wrench-screwdriver">Hi</.component>)
            }
          ]
        }
      )

      # The page uses a DIFFERENT icon, so nothing about it can supply the example's rule.
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="iconic" site="#{site.name}" icon="hero-bell">Page</.component></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}?name=iconic&index=0")

      assert html =~ "hero-wrench-screwdriver{",
             "the example's icon class was rendered with no rule behind it"
    end

    # The icon control is a COMBOBOX: the catalogue suggests, it does not gate. It can only ever hold
    # the sets this install registered, so an author naming a glyph from one it was never told about
    # — a second kit's own icons, a class the host ships itself — must still be able to write it
    # down. Before this the trigger was a button and the only reachable values were catalogued ones.
    test "an icon field accepts a value no installed set ships", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "iconish",
        template: "<div><span class={@icon}></span></div>",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="iconish" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_tag(view, ".component")

      render_click(view, "inspect", %{"id" => component.id})

      render_change(view, "icon_typed", %{
        "name" => "icon",
        "node_id" => component.id,
        "value" => "lucide-rocket"
      })

      edited = view |> editor() |> Map.fetch!(:tree) |> Tree.get(component.id)

      assert {"icon", {:string, "lucide-rocket"}} in edited.attrs
    end

    # Picking is a decision, so the popover has answered its question and gets out of the way. Typing
    # is not — there the list is a filter being narrowed, and closing it on every keystroke would
    # make the grid useless.
    test "picking an icon writes it and closes the picker; typing keeps it open", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "picky",
        template: "<div><span class={@icon}></span></div>",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="picky" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_tag(view, ".component")
      render_click(view, "inspect", %{"id" => component.id})

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")

      render_change(view, "icon_typed", %{
        "name" => "icon",
        "node_id" => component.id,
        "value" => "bell"
      })

      assert has_element?(view, "#pb-icon-picker-icon"), "typing must not close the list"

      render_click(view, "icon_picked", %{
        "node_id" => component.id,
        "name" => "icon",
        "value" => "hero-bell"
      })

      refute has_element?(view, "#pb-icon-picker-icon")

      edited = view |> editor() |> Map.fetch!(:tree) |> Tree.get(component.id)
      assert {"icon", {:string, "hero-bell"}} in edited.attrs
    end

    test "renders the document with the site's scope", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us"
      assert html =~ "pb-canvas-root"
      assert html =~ "data-node-id"
    end

    # A site's page routinely embeds a GLOBAL component — `<.component component_name="global-footer"
    # site="Global" />` — and the compiled module's name is hashed from that attribute. Scoping it to
    # the page's own site instead named a module nobody ever compiled, so the canvas painted the
    # runtime's red "failed to render" over a component that renders fine on the live site.
    test ~s(a component declaring site="Global" resolves the global module), %{
      conn: conn,
      site: site
    } do
      define_component!("pb-global-footer", nil, "<footer>global footer rendered</footer>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="pb-global-footer" site="Global" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "global footer rendered"
      refute html =~ "failed to render"
    end

    # A COMPONENT IS BUILT ON FIRST USE, and reading its metadata is a use. The canvas asks the
    # compiled module which attributes the component declares so a database-sourced name never mints
    # an atom — and a module that has never been built declares none, so every attribute the author
    # set was dropped and the node rendered with its defaults. The live site was unaffected, which is
    # what made it invisible: the same page looked right to a visitor and wrong to its author.
    test "a lazy component renders on the canvas WITH the attributes the author set", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          site_id: site.id,
          name: "pb-lazy-badge",
          template: ~s(<span class={"badge-" <> @tone}>lazy badge</span>),
          attrs: [%{name: "tone", type: "string", default: "quiet"}],
          precompile: false
        )

      refute Helpers.loaded?(Helpers.module_name(component.name, site.name, "Component"))

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div><.component component_name="pb-lazy-badge" site="#{site.name}" tone="loud" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      # THE FIRST PAINT, not the connected one. Rendering the component builds it as a side effect,
      # so by the second render the module exists and the attributes come back — the bug heals
      # itself one frame too late, after the author has already seen the wrong thing (or, when a
      # missing attribute makes the component raise, an error box where their component should be).
      html =
        conn
        |> get("/admin/dashboard/runtime/builder-canvas/#{token(view)}")
        |> html_response(200)

      # The component's OWN rendered markup, not the node's stored attributes — the canvas echoes
      # those into the DOM as well, so a looser match passes with the component rendering nothing.
      assert html =~ ~s(<span class="badge-loud">lazy badge</span>)
    end

    test "a component with no site attribute still resolves against the site being edited", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-site-hero", site, "<section>site hero rendered</section>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="pb-site-hero" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "site hero rendered"
      refute html =~ "failed to render"
    end

    # `Tree.Styles` lifts recognised utilities out of the authored class attribute and into
    # `meta.styles`, so rendering the authored attribute raw loses them. That dropped `flex` off a
    # nav and the menu stacked, while the SAVED template stayed correct — only serialization was
    # merging them back, so the whole suite stayed green.
    test "absorbed layout classes survive onto the canvas, not just into the save", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<header class="flex justify-between"><nav class="flex gap-6">x</nav></header>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # BOTH are absorbed now — `justify-between` joined the vocabulary with the layout panel — so
      # they come back in the serialiser's own order rather than authored-then-generated. Same
      # classes, and no two utilities here compete on specificity, so order carries nothing.
      assert html =~ ~s(class="flex justify-between")
      assert html =~ ~s(class="gap-6 flex")
    end

    test "a node with no class at all gains none", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section><p>hi</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      [_before, after_tag] = String.split(html, "<section", parts: 2)
      [opening, _rest] = String.split(after_tag, ">", parts: 2)
      refute opening =~ "class="
    end

    # The site's asset URL is keyed on its name and a content hash; a site that is inactive or has
    # never been compiled has neither, so linking it rendered the editor unstyled for exactly the
    # sites people open it on. The bytes are inlined from `AssetsState` instead.
    # The bundle is 3.6 MB on a real site. Inlining it put every byte in the document of every
    # preview the modal opened; linking it by content hash means brotli, an immutable year-long
    # cache, and a frame that paints once already styled.
    test "the canvas links the site's compiled CSS by content hash", %{conn: conn, page: page} do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: "abc",
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # THE LINK ITSELF IS IN THE ROOT LAYOUT'S `<head>` now, above the browser generator, so that
      # the classes the editor generates are appended after the bundle and win. What the canvas
      # still owes is the ADDRESS, and that is what is checked here — the test endpoint renders a
      # bare layout, so the tag is not observable from a LiveView test.
      assert css_hrefs(canvas) == ["/assets/css/__shared_base__/abc.css"]
      refute html =~ ".from-shared-base{color:#123456}"
    end

    # The reason the inline path still exists: a site that has never compiled has bytes in
    # `AssetsState` but no hash to address them by, and that is exactly the site someone opens the
    # editor on.
    test "a bundle with no content hash is inlined instead", %{conn: conn, page: page} do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: nil,
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-canvas-css"
      assert html =~ ".from-shared-base{color:#123456}"
      refute html =~ "/assets/css/"
    end

    # Tailwind's browser build generates a utility the moment its class appears, but only for tokens
    # it knows — without the kit's `@theme` every `text-natural-*` class comes out blank.
    test "the kit's @theme travels to the browser generator", %{
      conn: conn,
      page: page,
      site: site
    } do
      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "kit-theme",
          content: "@theme { --color-natural-x: #abcdef; }\n.other { color: red }",
          kind: :theme,
          active: true
        },
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(type="text/tailwindcss")
      assert html =~ "--color-natural-x: #abcdef;"
      # Only the @theme block travels; the rest is already in the compiled bundle.
      refute html =~ ".other { color: red }"
    end

    # THE ORDER IS THE WHOLE FIX. The site's compiled bundle is base styling and belongs in `<head>`;
    # the browser generator injects what it makes into `<head>` too, after the markup already there.
    # Rendered in THIS LiveView's template — which is `<body>` — the bundle came last and overruled
    # every class the editor generated: an author typed `pl-[30px]` onto an element whose page said
    # `px-8`, the class landed, the rule was written, and the padding did not move.
    #
    # The link lives in `root.html.heex` now, above the generator's script. What is checkable here is
    # the half that was wrong: it must not be in the frame's body any more. The test endpoint renders
    # a bare layout, so the head itself is not observable from here.
    test "the compiled bundle is not rendered into the frame's body", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ ~r|<link[^>]+rel="stylesheet"[^>]+/assets/css/|

      # The frame's own chrome is still the frame's, so this is the bundle moving out and not the
      # whole head going missing.
      assert html =~ "pb-canvas-chrome"
    end

    # A node's own LiveView bindings must not reach the frame. `phx-click` would fight the canvas's
    # selection binding, and `phx-hook` names a hook from the SITE's bundle, which this frame does not
    # load — LiveView logged "unknown hook found" in the console for every one.
    test "a node's phx-* bindings are not emitted into the canvas", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<button id="c" phx-hook="SiteClipboard" phx-click="copy" data-x="1" class="btn">Copy</button>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "SiteClipboard"
      refute html =~ ~s(phx-click="copy")
      # Everything that is not a binding still renders, and the attribute stays in the document.
      assert html =~ ~s(data-x="1")
      assert html =~ "btn"
      assert editor_html(view) =~ ~s(phx-hook="SiteClipboard")
    end

    # A link in the document must select, not navigate. `<.link navigate>` renders `data-phx-link`,
    # which LiveView's own interceptor treats as a live redirect — clicking one to select it took the
    # canvas away from the document being edited. The hook cancels it in the capture phase, before
    # that interceptor runs, and pushes the selection itself.
    test "the canvas keeps a page's links selectable rather than live", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<nav><.link navigate="/">Home</.link></nav>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # The href stays — it is the document's content, and the inspector edits it.
      assert html =~ ~s(href="/")
      # The hook is what cancels the navigation, so the canvas must be carrying it.
      assert html =~ ~s(phx-hook="PbCanvas")
    end

    test "an expired session says so rather than erroring", %{conn: conn} do
      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

      assert html =~ "session has expired"
    end

    # A `phx-click="select"` on the canvas container would fire on the way up from every node's own
    # click and immediately clear the selection that just happened. Deselecting on background clicks
    # is the hook's job precisely because it can tell whether the click landed on a node.
    test "the canvas container carries no deselect binding of its own", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # Only the container's OWN opening tag — everything up to its first `>`. Its children carry
      # `phx-click="select"` and should.
      [_before, after_id] = String.split(html, ~s(id="pb-canvas-root"), parts: 2)
      [opening_tag, _children] = String.split(after_id, ">", parts: 2)

      refute opening_tag =~ ~s(phx-click="select")
      assert opening_tag =~ ~s(phx-hook="PbCanvas")
    end

    test "a selection made in the canvas survives — it is not cleared by its own click", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(canvas, "select", %{"id" => h1.id})

      assert editor(view).selection == h1.id
      assert render(view) =~ "h1"
    end

    test "selecting in the canvas updates the chrome over PubSub", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(canvas, "select", %{"id" => h1.id})

      assert editor(view).selection == h1.id
    end

    # A FORM IS AUTHORED ON THIS SURFACE, so it has to render on it. Every part of one is an
    # expression the canvas refuses to evaluate: `for={assigns[:contact_form]}` reads an assign the
    # canvas does not have, `field={f[:email]}` reads a variable only a real `:let` could bind, and
    # `<.form>` itself is a function component called by `apply/3` — so it never receives the
    # defaults and the `:global` map HEEx would have built at a call site. Each of the three ends in
    # a `KeyError` inside LiveView's diff, and what the author sees is the red placeholder.
    #
    # The shape is honoured rather than the value: the bindings are parsed, a blank form field is
    # built from the form's own `as`, and the field renders carrying the input name it will really
    # submit under.
    #
    # The document is put into the SESSION rather than saved on the page, because saving compiles
    # the template for real and `input/1` is not yet among a compiled page's imports — a separate
    # question from what the canvas can draw, and the canvas resolves it through its own module list.
    test "a form with bound fields renders its real input names", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, tree} =
        Tree.parse("""
        <.form
          :let={f}
          id="contact-form"
          as={:contact}
          for={assigns[:contact_form]}
          phx-change="contact_validate"
          phx-submit="contact_submit"
        >
          <.input field={f[:name]} type="text" label="Your name" />
          <.input field={f[:email]} type="email" label="Email" />
        </.form>
        """)

      {:ok, _session} = EditorSession.put_tree(token(view), tree)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "<form", "the wrapper renders a real form element"
      assert html =~ ~s(name="contact[name]"), "the first field submits under the form's own name"
      assert html =~ ~s(name="contact[email]")
      assert html =~ ~s(id="contact_name"), "and carries the id its label points at"
      assert html =~ "Your name"
      assert html =~ "Email"

      refute html =~ "could not render", "nothing in a form is allowed to be a placeholder"

      refute html =~ "set it in the inspector to render this",
             "and no field is reported as missing the attribute the canvas synthesises"

      refute html =~ "contact_submit",
             "and the canvas still strips every binding — a form here is not a running page"

      refute html =~ "contact_validate"
    end

    # THE OTHER HALF OF THE SAME SURFACE, and the half the installed kit never reaches. All 23 of
    # Chelekom's fields take a `%Phoenix.HTML.FormField{}`, so `field={f[:email]}` is the only thing
    # the editor writes for them. A kit on the documented fallback gets the pair instead —
    # `name={f[:email].name}` and `value={f[:email].value}` — and both used to arrive as the whole
    # struct, because the key `:email` is the same fact for all three expressions and the canvas
    # resolved nothing further. `name={%Phoenix.HTML.FormField{}}` is
    # `protocol Phoenix.HTML.Safe not implemented`, which is the red box, on the surface the form is
    # authored on.
    test "a field that binds by name and value renders its real input name", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]}>) <>
              ~s(<MishkaCmsCore.Test.PairFieldComponent.text name={f[:email].name} value={f[:email].value} />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(name="contact[email]"),
             "the pair path has to reach the input name, not the struct that carries it"

      refute html =~ "could not render"
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # THE COMPONENT BUILDER COULD NOT SHOW A MODAL'S OWN CONTENTS. Every Chelekom dialog wraps its
    # title, close button and body in `<.focus_wrap id={"#{@id}-container"}>`, and opening that
    # component in the builder means rendering it with no page assigns — so `@id` folded to nothing,
    # `attr_value/1` dropped the attribute, and Phoenix met its own `focus_wrap` without the one
    # thing it declares required. `key :id not found`, raised from inside LiveView's diff and caught
    # by `contain/2` as a red box where the dialog should have been.
    test "a required attribute written as an expression renders rather than raising", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          name: "dialog-shell",
          site_id: site.id,
          template:
            ~s(<div id="wrap"><.focus_wrap id={"\#{@id}-container"}>) <>
              ~s(<h2 id="dialog-title">Are you sure?</h2></.focus_wrap></div>)
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute has_element?(canvas, ~s([data-render-error="true"])),
             "the canvas used to red-box every dialog it was asked to open"

      refute html =~ "key :id not found"

      # And the point of not refusing: what the author came to edit is on the canvas.
      assert html =~ "Are you sure?"
      assert has_element?(canvas, "#dialog-title")
    end

    # A KIT'S OPTIONAL ATTRIBUTE WITH NO DEFAULT IS A KEY ITS TEMPLATE STILL READS. Chelekom's form
    # wrapper declares `for` that way, and a wrapper bound to its page form
    # (`for={assigns[:contact_form]}`) lost the attribute on the canvas, which cannot read page
    # assigns, so every render ended in `key :for not found`.
    test "a kit attribute with no default, written as an expression, renders rather than raising",
         %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "bound-shell",
        template: ~s(<div id="bound-shell">{if @for, do: "bound", else: "not bound yet"}</div>),
        attrs: [%{"name" => "for", "type" => "any", "opts" => %{"required" => false}}]
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="bound-shell" site="#{site.name}" for={assigns[:contact_form]} /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "key :for not found"
      refute has_element?(canvas, ~s([data-render-error="true"]))
      assert has_element?(canvas, "#bound-shell", "not bound yet")
    end

    test "Chelekom's own form wrapper, wired to its page form, draws on the canvas", %{
      conn: conn,
      site: site
    } do
      wrapper =
        MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("components")
        |> Enum.find(&(&1["name"] == "chelekom-form-wrapper"))

      create_component!(
        site_id: site.id,
        name: wrapper["name"],
        template: wrapper["template"],
        attrs: wrapper["attrs"],
        slots: wrapper["slots"],
        helpers: wrapper["helpers"]
      )

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root">
            <.component component_name="chelekom-form-wrapper" site="#{site.name}" :let={f}
              id="contact-form" as={:contact} for={assigns[:contact_form]}
              phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit">
              <input id="wrapped-name" name={f[:name].name} value={f[:name].value} />
            </.component>
          </div>
          """
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "key :for not found"
      refute has_element?(canvas, ~s([data-render-error="true"]))
      assert has_element?(canvas, "form#contact-form")
    end

    # A WORKING FORM'S `for` IS SUPPLIED BY THE PAGE, so a kit that declares it required draws its
    # form. Chelekom's Simple Form does, and every one the editor wired showed "needs for" instead.
    test "Chelekom's Simple Form, wired to its page form, draws on the canvas", %{
      conn: conn,
      site: site
    } do
      rows =
        MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("components")

      for name <- ~w(chelekom-form-wrapper chelekom-simple-form),
          row = Enum.find(rows, &(&1["name"] == name)) do
        create_component!(
          site_id: site.id,
          name: name,
          template: row["template"],
          attrs: row["attrs"],
          slots: row["slots"],
          helpers: row["helpers"]
        )
      end

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root">
            <.component component_name="chelekom-simple-form" site="#{site.name}" :let={f}
              id="news-form" as={:news} for={assigns[:news_form]}
              phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">
              <input id="simple-email" name={f[:email].name} value={f[:email].value} />
            </.component>
          </div>
          """
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "needs for"
      refute has_element?(canvas, ~s([data-incomplete="true"]))
      refute has_element?(canvas, ~s([data-render-error="true"]))
      refute html =~ "failed to render"
      assert has_element?(canvas, ~s(form#news-form input#simple-email[name="news[email]"]))
    end

    test "a required `for` that is not the page's own form still says it is needed", %{
      conn: conn,
      site: site
    } do
      kit_rows!(site, chelekom_rows(~w(chelekom-simple-form)))

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="chelekom-simple-form" site="#{site.name}" for={@changeset} /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-incomplete="true"]))
      assert html =~ "needs for"
    end

    # WRITTEN IS SUPPLIED; UNWRITTEN IS NOT. A required attribute the author never wrote is a real
    # gap, and the placeholder is how they are told — the same words a kit component gets, and
    # still selectable so the click lands on the node.
    test "a required attribute nobody wrote is named rather than rendered", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><.focus_wrap>nothing named it</.focus_wrap></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-incomplete="true"]))
      assert html =~ "needs id"
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # A HALF-TYPED EXPRESSION IS NOT A CRASH. The author is editing, and `f[:email].nam` is a
    # keystroke away from `f[:email].name` — so a path the form field does not carry supplies no
    # assign, and the attribute falls back to whatever the component declared.
    test "a binding naming nothing the form field carries supplies no assign at all", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]}>) <>
              ~s(<MishkaCmsCore.Test.PairFieldComponent.text name={f[:email].name} value={f[:email].nonsense} />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(name="contact[email]")
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # WHAT THE VALIDATION SECTION WRITES HAS TO BE VISIBLE ON THE CANVAS. `required`, `minlength` and
    # `data-format` are none of them declared by `<.input>`: HEEx routes such a name into the
    # component's `:global` attribute at the call site, and the canvas has no call site, so all three
    # were dropped on the way in. The author set Required, the code drawer showed `required` written,
    # and the field on the canvas rendered exactly as it had before.
    test "a global attribute the component never declared still reaches its rendered input", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]}>) <>
              ~s(<.input field={f[:email]} type="email" label="Email" required minlength="5" data-format="email" />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(minlength="5")
      assert html =~ ~s(data-format="email")
      assert html =~ "required"
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # A RAW TAG'S BINDING IS SHOWN THE WAY THE PUBLISHED PAGE WILL SHOW IT. A checkbox bound to its
    # form carries `name={f[:agree].name}`, which reads an assign, so the canvas refused it and the
    # input rendered with NO name — correct in the stored source, blank on the surface the author
    # looks at, and indistinguishable from the unbound field the audit warns about.
    test "a raw input bound to its form renders the name the visitor will submit", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="signup-form" as={:signup} for={assigns[:signup_form]}>) <>
              ~s(<input type="checkbox" name={f[:agree].name} value="true" />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(name="signup[agree]")
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # READING THE SOURCE WHILE AUTHORING IS THE POINT OF THE DRAWER. Selecting another element is not
    # a change to the document and must not close it — an author checking what a form's markup looks
    # like had to reopen the drawer after every click.
    test "the code drawer survives selecting another element", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><p>one</p><span>two</span></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-code-strip") |> render_click()
      refute has_element?(view, "#pb-code-strip")

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "span"))

      render_click(view, "select", %{"id" => node.id})

      refute has_element?(view, "#pb-code-strip")
    end

    # The whole struct is not a string, so it is left out rather than interpolated into markup.
    test "and a raw tag bound to the struct itself is left alone", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="signup-form" as={:signup} for={assigns[:signup_form]}>) <>
              ~s(<input type="text" name={f[:agree]} />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # EVERY CHELEKOM FIELD DECLARES A BARE `attr :rest, :global`, with no `:include` — so filtering
    # the canvas by `Phoenix.Component.Declarative.__global__?/3` would have kept `required` off all
    # 23 of them while the published page rendered it, which is the whole Validation section for the
    # fields people actually build forms out of.
    test "a kit's undeclared attribute reaches its rest, the way the published page renders it",
         %{
           conn: conn,
           site: site
         } do
      create_component!(
        site_id: site.id,
        name: "restfield",
        template: ~s|<input type="text" {@rest} />|,
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="restfield" required minlength="5" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(minlength="5")
      assert html =~ "required"

      refute html =~ "component_name=",
             "the wrapper's own two attributes are addressed to `.component`, not to the kit"
    end

    # A COMPONENT THAT DECLARES NO GLOBAL TAKES NOTHING EXTRA. Handing an undeclared assign to one is
    # a `KeyError` waiting inside LiveView's diff at best, and this component's whole point is that
    # `name` carries no default.
    test "a component with no global declaration is handed nothing it did not declare", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><MishkaCmsCore.Test.PairFieldComponent.text name="plain" data-wibbles="17" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "wibbles"
    end

    # A `phx-` binding names a hook that lives in the SITE's bundle, which this frame deliberately
    # does not load, and its click would fight the canvas's own selection binding. It is global as far
    # as LiveView is concerned, so only the canvas can refuse it — for a component exactly as for a tag.
    test "a component's own phx- binding is not forwarded into the frame", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.input type="text" name="plain" phx-click="author_click" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "author_click"
    end

    # AN EMPTY CONTAINER CANNOT BE FILLED IF IT IS ZERO PIXELS TALL, and a component that declares
    # its slot required could not render at all until something was already inside it.
    test "an empty component container renders and gets a floor", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<.form :let={f} as={:quote} for={assigns[:quote_form]}></.form>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "<form", "an empty form is still a form"
      assert html =~ "min-height:56px", "and is somewhere to aim at"
      refute html =~ "could not render"
    end
  end

  describe "the Studio, Assets and Review sheets" do
    # These assert the SHIPPED SAMPLE catalogue, so they name the adapter that provides it rather
    # than depending on which one happens to be the default. The real default reads the kits on
    # disk — covered separately below.
    setup do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)
      :ok
    end

    test "Studio opens on Tokens and shows a real generated export", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      html = render(view)
      assert html =~ "Studio"
      assert html =~ "Iris"
      assert html =~ "theme.colors.iris"

      # The generated file names itself on the shut drawer, and the drawer holds the real thing —
      # the fold is a JS toggle, so the source is rendered whether or not it is on screen.
      assert html =~ "tailwind.config.js"
      assert has_element?(view, "#pb-token-export-body.hidden")
      assert html =~ "module.exports = {"
    end

    test "switching the export format regenerates the file", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      view |> element("#pb-tokfmt-css") |> render_click()
      html = render(view)
      assert html =~ ":root {"
      assert html =~ "--iris: #5b57d6;"
      assert html =~ "tokens.css"

      view |> element("#pb-tokfmt-ex") |> render_click()
      assert render(view) =~ "defmodule MishkaWeb.Theme do"
    end

    test "the Studio has all five tabs and a scope filter", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      for tab <- ~w(tokens presets snippets registry settings) do
        assert has_element?(view, "#pb-studio-#{tab}")
      end

      html = render(view)
      assert html =~ "Design tokens"
      assert html =~ "One source of truth"

      # The scope filter belongs to the two tabs that list things you can own — asking "Downloaded"
      # of the site's own tokens means nothing.
      refute has_element?(view, "#pb-studio-scope-downloaded")

      view |> element("#pb-studio-registry") |> render_click()
      assert has_element?(view, "#pb-studio-scope-downloaded")
      assert render(view) =~ "1 installed"
    end

    # Custom tokens are the ones this site added on top of the kit, and the row says so.
    # The prototype's switches are decoration; these are the site's own settings, so a flick has to
    # survive the next read.
    test "a Studio option toggle writes the site's setting", %{conn: conn, page: page, site: site} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      refute MishkaCmsCore.Settings.get("cms_builder.studio.dark_pair", false, site.id) == true

      view |> element("#pb-studio-opt-cms_builder\\.studio\\.dark_pair") |> render_click()

      assert MishkaCmsCore.Settings.get("cms_builder.studio.dark_pair", false, site.id) == true

      assert view |> element("#pb-studio-opt-cms_builder\\.studio\\.dark_pair") |> render() =~
               "aria-checked=\"true\""
    end

    test "the registry source is stored, not just displayed", %{
      conn: conn,
      page: page,
      site: site
    } do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      view
      |> form("#pb-registry-source-form", %{"registry" => %{"source" => "hex.pm/chelekom"}})
      |> render_change()

      assert MishkaCmsCore.Settings.get("cms_builder.studio.registry_source", nil, site.id) ==
               "hex.pm/chelekom"
    end

    # A licence token is a credential: the field shows what is stored and refuses to take a new one
    # here, because this editor is not where a secret should be typed.
    test "the licence field is read-only and points at Settings", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      html = view |> element("#pb-license-token") |> render()
      assert html =~ "readonly"
      assert render(view) =~ "Not connected"
    end

    # WHICHEVER TOKENS THIS SITE IS BEING SHOWN, read through the same function the sheet reads.
    # `Marketplace.tokens(nil)` is a different list: it asks the adapter for the GLOBAL set, while
    # the Studio asks `studio_token_list/1` for the site's own and falls back to the adapter only
    # when the site declares none. They agree today because this block forces the sample adapter,
    # and they stop agreeing the moment the fixture grows a stylesheet.
    test "a custom token is marked and an unused one is called out", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      shown = Panels.studio_token_list(page.site_id)

      # The list pages at 30, so a token is reached by narrowing rather than by scrolling — which is
      # what the Custom chip is for.
      view |> element("#pb-tokcat-custom") |> render_click()

      custom = Enum.find(shown, & &1.custom?)

      assert custom, "the sheet is showing no custom token, so there is nothing to mark"
      assert view |> element("#pb-token-#{custom.key}") |> render() =~ "Custom"

      unused = Enum.find(shown, &(&1.usage == 0))

      if unused do
        # Narrow to its own category for the same reason: one page is 30 rows.
        view |> element("#pb-tokcat-#{unused.category}") |> render_click()
        assert view |> element("#pb-token-#{unused.key}") |> render() =~ "Unused"
      end
    end

    # The row shows what Copy would actually give you, so it follows the selected format.
    #
    # WHICH TOKENS EXIST IS NOT THIS TEST'S BUSINESS. It named `iris` from the sample set, which the
    # Studio shows only while the site declares none of its own — so it passed or failed on whether
    # some earlier test had left a theme stylesheet behind, and reported that as a formatting bug.
    # The subject is the FORMAT, so it reads whichever token is listed and follows that one.
    test "a token's reference follows the export format", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      assert [_match, key] = Regex.run(~r/theme\.colors\.([a-z0-9-]+)/, render(view))

      view |> element("#pb-tokfmt-css") |> render_click()
      html = render(view)

      assert html =~ "--#{key}"
      refute html =~ "theme.colors."
    end

    # ONLY THE LIST WAITS. The sheet's own skeleton note promises that "the tabs and the filters
    # above are real and clickable from the first frame" — and the chips ARE filters. They used to
    # be drawn only in the table's LOADED state, so every first read blinked the whole row out and
    # put it back: a jump in the one part of the sheet that was meant not to move.
    #
    # ASKED OF THE LOADING STATE DIRECTLY, because it cannot be caught from the outside. Two waits
    # are stacked here — the sheet's own `:studio_data`, then the table's first read — so the frame
    # `render_click` returns is the sheet's skeleton with no table in it at all, and the one frame
    # that matters is gone by the time any assertion can look at it.
    test "the loading state draws the chips beside the shape of the list" do
      skeleton =
        %{
          state: %{path_params: %{token_categories: [{"all", "All", 3}, {"color", "Color", 2}]}},
          myself: nil,
          __changed__: nil
        }
        |> MishkaCmsCoreWeb.Templates.StudioTokens.render_loading()
        |> rendered_to_string()

      assert skeleton =~ "pb-token-skel-1", "the list still waits as a shape"
      assert skeleton =~ ~s(id="pb-tokcat-all")
      assert skeleton =~ ~s(id="pb-tokcat-color")
    end

    # A TABLE WITH NO STATE AT ALL is what the renderer draws on the very first paint, before it has
    # one to hand over. Nothing to count is not a crash.
    test "and draws none when there is no state to read them from" do
      skeleton =
        %{state: nil, myself: nil, __changed__: nil}
        |> MishkaCmsCoreWeb.Templates.StudioTokens.render_loading()
        |> rendered_to_string()

      assert skeleton =~ "pb-token-skel-1"
      refute skeleton =~ "pb-tokcat-"
    end

    test "tokens group under category headings with counts", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      assert has_element?(view, "#pb-tokcat-all")
      assert has_element?(view, "#pb-tokcat-color")

      view |> element("#pb-tokcat-color") |> render_click()
      html = render(view)
      assert html =~ "Ink"
      # Narrowed to one category, the others are gone.
      refute html =~ "Tight"
    end

    test "Settings names the licence, the source and the theme options", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      html = render(view)
      assert html =~ "License token"
      assert html =~ "Not connected"
      assert html =~ "registry.mishka.tools"
      assert html =~ "Generate dark pair"
      assert html =~ "Lock tokens"
      # The scope filter belongs to the catalogues, not to settings.
      refute has_element?(view, "#pb-studio-scope-all")
    end

    # WHERE AN INSTALL LANDS. The Registry is the only surface in the admin that installs a package,
    # and it passed the editor's `site_id` unconditionally — a master could not share one across
    # sites, and nothing stopped a tenant's event asking for every site.
    test "a master is asked where, on the package they are installing", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-registry") |> render_click()
      _loaded = render_async(view)

      actor = :sys.get_state(view.pid).socket.assigns.current_user
      assert is_nil(actor.site_id), "this suite logs in a master"

      package = first_uninstalled_package(view)

      # The question is asked at the moment of installing: the menu ships folded, and Install is a
      # JS toggle of it — the choice is one click away and no round trip away.
      assert has_element?(view, "#pb-pkg-install-menu-#{package}.hidden")

      assert view |> element("#pb-pkg-install-#{package}") |> render() =~
               "#pb-pkg-install-menu-#{package}"

      assert has_element?(view, "#pb-pkg-install-site-#{package}")
      assert has_element?(view, "#pb-pkg-install-global-#{package}")
    end

    test "the menu belongs to one package, not the panel", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-registry") |> render_click()
      _loaded = render_async(view)

      package = first_uninstalled_package(view)

      # EACH PACKAGE OWNS ITS MENU. The button carries its own package's id, so one row's Install
      # cannot unfold another's — which is the whole reason the id is built from the package.
      assert has_element?(view, "#pb-pkg-install-menu-#{package}")

      assert view |> element("#pb-pkg-install-#{package}") |> render() =~
               "#pb-pkg-install-menu-#{package}"
    end

    # THE GUARD, not the control. A tenant never sees the buttons, so the only way to exercise this
    # is the way an attacker would: send the event anyway. A REAL tenant session, because the actor
    # is what the guard reads — standing the assign down in the process is not the same thing, and
    # an earlier version of this test did that and passed while proving nothing.
    test "a tenant's forged global install is refused", %{conn: conn, page: page, site: site} do
      tenant = create_admin("tenant@example.com", site.id)
      assert tenant.site_id == site.id

      {:ok, view, _html} = conn |> log_in(tenant) |> open_builder(page)
      view |> element("#pb-studio") |> render_click()
      view |> element("#pb-studio-registry") |> render_click()

      assert has_element?(view, "#pb-studio-registry"), "the Registry tab is open"

      refute has_element?(view, "#pb-pkg-install-menu-chelekom-alert"),
             "a tenant is not offered the choice in the first place"

      render_click(view, "install_package", %{"package" => "chelekom-alert", "scope" => "global"})

      assert render(view) =~ "cannot install for that site"
    end

    # The registry lists whatever the kits on disk have not installed yet, so the fixture cannot name
    # a package — it reads the first one the panel actually drew an Install button for.
    defp first_uninstalled_package(view) do
      view
      |> render()
      |> then(&Regex.run(~r/id="pb-pkg-install-([a-z0-9-]+)"/, &1))
      |> case do
        [_full, id] -> id
        nil -> flunk("the Registry drew no Install button to click")
      end
    end

    test "switching tab resets the category filter", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-tokcat-color") |> render_click()

      # "color" means nothing to a package, so carrying it across would hide the catalogue.
      view |> element("#pb-studio-registry") |> render_click()
      assert render(view) =~ "Chelekom Datatable"
    end

    # Save → list → insert → delete, through the panel's own controls. The snippet store is the one
    # place in the Studio holding THIS install's content rather than a registry's, so the round trip
    # is what proves it: a saved snippet has to come back as an ordinary insert.
    test "a snippet saves what is selected and inserts it back", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "insert",
        "parent_id" => "root",
        "index" => "0",
        "template" => "<section id=\"kept\">Say hello</section>"
      })

      placed =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.tag == "section"))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-studio") |> render_click()
      view |> element("#pb-studio-snippets") |> render_click()

      # The markup rides in on a hidden input that `Panels` associates with the form by id, so it
      # stays fresh as the canvas changes without rebuilding the form under a half-typed name.
      assert render(view) =~ ~s(form="pb-snippet-form")

      view
      |> element("#pb-snippet-form")
      |> render_submit(%{
        "form" => %{
          "name" => "Greeting block",
          "source" => ~s(<section id="kept">Say hello</section>),
          "visibility" => "page"
        }
      })

      html = render_async(view)
      assert html =~ "Greeting block"
      # Blocks and size are read off the markup, not stored beside it.
      assert html =~ "1 block ·"

      [snippet] = saved_snippets(site, page)

      render_click(view, "op", %{"kind" => "delete", "node_id" => placed.id})
      view |> element("#pb-snippet-insert-#{snippet.id}") |> render_click()

      assert editor_html(view) =~ "Say hello"
      # It went through history, so it is undoable like any other insert.
      refute editor(view).past == []

      view |> element("#pb-snippet-delete-#{snippet.id}") |> render_click()
      assert saved_snippets(site, page) == []
    end

    # The scope used to be decided FOR the author — a selection saved `:page`, a whole page saved
    # `:shared`, and there was no way to say otherwise. Now the radio decides, and "All sites" is a
    # `site_id` choice rather than a third `scope`.
    test "the author chooses who a snippet is for", %{conn: conn, page: page, site: site} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-snippets") |> render_click()

      save = fn name, visibility ->
        view
        |> element("#pb-snippet-form")
        |> render_submit(%{
          "form" => %{
            "name" => name,
            "source" => "<section>#{name}</section>",
            "visibility" => visibility
          }
        })
      end

      save.("Beside this page", "page")
      save.("Across this site", "shared")
      save.("Everywhere", "global")

      stored =
        site
        |> saved_snippets(page)
        |> Map.new(&{&1.name, &1.scope})

      assert stored["Beside this page"] == "This page"
      assert stored["Across this site"] == "Shared"

      # "All sites" is the one choice that is not a `scope` at all: it writes a nil `site_id`, which
      # `scope_label/1` reads back as "All sites". Every default is merged over a blank param, so
      # the editor's site deliberately does NOT travel under that name — see `editor_site_id`.
      assert stored["Everywhere"] == "All sites"
      assert has_element?(view, "#pb-snippet-scope-global")
    end

    # A `:page` snippet with no document to sit beside is unreachable forever, so the choice is not
    # offered rather than offered and quietly ignored.
    test "there is no This page choice until there is a page", %{conn: conn, page: page} do
      {:ok, new_view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")
      new_view |> element("#pb-studio") |> render_click()
      new_view |> element("#pb-studio-snippets") |> render_click()

      refute has_element?(new_view, "#pb-snippet-scope-page")
      assert has_element?(new_view, "#pb-snippet-scope-shared")

      view = open_studio(conn, page)
      view |> element("#pb-studio-snippets") |> render_click()

      assert has_element?(view, "#pb-snippet-scope-page")
    end

    # A name is the only thing the author supplies, so an empty one has to say so rather than write a
    # row nobody can find again.
    test "saving a snippet without a name says so", %{conn: conn, page: page, site: site} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-snippets") |> render_click()

      view
      |> element("#pb-snippet-form")
      |> render_submit(%{"form" => %{"name" => "  ", "source" => "<section>x</section>"}})

      assert render(view) =~ "Give the snippet a name first."
      assert saved_snippets(site, page) == []
    end

    test "the Studio tabs show presets, the registry and snippets", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      view |> element("#pb-studio-presets") |> render_click()
      assert render(view) =~ "Commerce Pro"

      view |> element("#pb-studio-registry") |> render_click()
      html = render(view)
      assert html =~ "Chelekom Datatable"
      assert html =~ "Installed"

      view |> element("#pb-studio-snippets") |> render_click()
      # The list is a Gervaz table now, so its empty state appears once the read has actually come
      # back — not as markup that was always there and merely hidden.
      assert render_async(view) =~ "No snippets saved yet."
    end

    # Presets and packages come from the configured adapter, and the shipped one is a SAMPLE. A card
    # that looks installable next to an Install button that refuses is the demo lying about itself,
    # so the two tabs that show adapter data say where it comes from. Tokens and snippets do not —
    # they are this site's own.
    test "the sample catalogue says it is one, on the tabs that show it", %{
      conn: conn,
      page: page
    } do
      view = open_studio(conn, page)

      view |> element("#pb-studio-presets") |> render_click()
      assert has_element?(view, "#pb-sample-catalogue")

      view |> element("#pb-studio-registry") |> render_click()
      assert has_element?(view, "#pb-sample-catalogue")

      view |> element("#pb-studio-tokens") |> render_click()
      refute has_element?(view, "#pb-sample-catalogue")

      view |> element("#pb-studio-snippets") |> render_click()
      refute has_element?(view, "#pb-sample-catalogue")
    end

    # THE SHEET IS THE MEDIA SYSTEM. Not a hand-rolled mirror of it: the browse half is
    # `MishkaGervaz.Table.Web.Live` on `Runtime.Media` with the resource's own MediaGallery template,
    # and the upload half is `MishkaGervaz.Form.Web.Live`, which registers its own `allow_upload`.
    test "Assets mounts the Gervaz gallery and the Gervaz upload form", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_media!(site_id: site.id, name: "brochure")

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      assert has_element?(view, "#pb-assets-gallery"), "the library is Gervaz's table"
      assert has_element?(view, "#pb-media-upload"), "uploading happens here, not on another page"
      assert render(view) =~ "brochure"
    end

    # The dropzone, the accept list, the size limit, the progress bar and the write all belong to
    # Gervaz's `uploads do … style :dropzone … end` block on the resource. Registering a second
    # uploader for the same name here would be a second media system.
    test "the upload half is Gervaz's, uploader and all", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      assert render(view) =~ "drag and drop", "Gervaz's own dropzone copy"

      refute :sys.get_state(view.pid).socket.assigns[:uploads],
             "BuilderLive must not register an uploader of its own"
    end

    # An `image_url` attribute is not a link an author types — it is a file in this site's library. The
    # library is browsable on its own, so the pick has to say who it is picking FOR, and the answer
    # has to land on the attribute that asked.
    test "an image attribute picks from the library and writes what it picked", %{
      conn: conn,
      page: page,
      site: site
    } do
      media_id =
        create_media!(site_id: site.id, name: "hero-shot", relative_path: "/uploads/hero.png").id

      create_component!(
        site_id: site.id,
        name: "banner-box",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-banner-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The library has no Use button until something is choosing.
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)
      refute has_element?(view, "#pb-media-target")

      view |> element("#pb-attr-pick-image_url") |> render_click()
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "Choosing for"
      assert html =~ "image_url"

      # AND HOW. Naming the target and stopping there left the reader in front of a grid of files
      # with a tick box on each, and the tick box is for Archive and Featured — it picks nothing.
      assert html =~ "press <b>Use</b> on a file below"

      # The Use button is the resource's own row action, rendered by the Gervaz gallery (see
      # `AssetsSheetRoutesTest`). It reaches this LiveView as
      # `{:row_action, "use_media", %{"id" => id}}`.
      send(view.pid, {:row_action, "use_media", %{"id" => media_id}})
      _rendered = render(view)

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Node.attr_text("image_url") ==
               "/uploads/hero.png"

      # The sheet closes and stops offering to pick, so browsing later writes nothing.
      refute has_element?(view, "#pb-media-target")
    end

    # A BROKEN GLYPH IS NOT AN ANSWER. A media field whose path points at nothing drew the browser's
    # own torn-page icon, which says the same thing about a deleted file, a mistyped name and a URL
    # that was never right. Reported alongside "can we put an image inside a card?" — the card was
    # fine; the path in it was not, and nothing on screen said so.
    test "a media field says when its path loads nothing", %{conn: conn, page: page, site: site} do
      html = media_field_html(conn, page, site, "shot-a", "/uploads/gone.png")

      assert html =~ "Nothing loads from this path"

      assert html =~ ~s(phx-hook="MediaThumb"),
             "without the hook the sentence never gets uncovered"
    end

    # And a half-typed value is not worth a box at all — an empty frame appearing under every
    # keystroke reads as something failing.
    test "and draws no preview box for a value that is not a path yet", %{
      conn: conn,
      page: page,
      site: site
    } do
      refute media_field_html(conn, page, site, "shot-b", "upl") =~ "Nothing loads from this path"
    end

    # A WRONG DOOR IS WORSE THAN A LOCKED ONE. The sheet listed every file whatever was asking, so
    # pressing Use on the first card put `/uploads/documents/10.docx` into an `<img src>` — taken
    # without complaint and drawn on the page as a broken picture. `type` is a Media attribute, so it
    # filters the gallery through the same channel `site_id` already rides.
    test "picking for a picture shows only pictures", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "shot-c",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-shot-c") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})
      _loaded = render_async(view)

      assert :sys.get_state(view.pid).socket.assigns.media_target.accepts == :images
      assert media_filter(view)[:type] == :images
    end

    # `<video src>` is not a picture, and hiding every video from the one field that takes one would
    # be the same fault pointing the other way.
    test "and picking for something that plays does not", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><video src="/a.mp4"></video></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      video = node_with_tag(view, "video")

      render_click(view, "pick_media", %{"node_id" => video.id, "name" => "src"})
      _loaded = render_async(view)

      assert :sys.get_state(view.pid).socket.assigns.media_target.accepts == :any
      refute Map.has_key?(media_filter(view), :type)
    end

    # The still frame on a video IS a picture — the exception inside the exception.
    test "and a video's poster is a picture again", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><video src="/a.mp4"></video></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      video = node_with_tag(view, "video")

      render_click(view, "pick_media", %{"node_id" => video.id, "name" => "poster"})
      _loaded = render_async(view)

      assert media_filter(view)[:type] == :images
    end

    # A background is always a picture.
    test "and a background is a picture too", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      root = view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) |> List.first()

      render_click(view, "pick_background", %{"node_id" => root, "bucket" => "desktop"})
      _loaded = render_async(view)

      assert media_filter(view)[:type] == :images
    end

    # What the gallery is actually scoped by, read where the sheet hands it over.
    defp media_filter(view) do
      view
      |> render()
      |> then(fn _html -> :sys.get_state(view.pid).socket.assigns end)
      |> then(&MishkaCmsCoreWeb.Live.Admin.Builder.Panels.media_scope_params/1)
    end

    # AND THE BOX SAYS WHAT IT TAKES. Every length field said "unset", so an author who typed a bare
    # number, got pixels, and had no reason to try anything else reported the fields as pixels-only.
    test "a length field says it takes any length", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      root = view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) |> List.first()

      render_click(view, "select", %{"id" => root})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert view |> element("#pb-style-base-width") |> render() =~ "any length, e.g. 2rem"
    end

    # Opacity is a NUMBER, not a length — telling somebody to type `2rem` into it would be wrong.
    test "and a field that is not a length does not", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      root = view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) |> List.first()

      render_click(view, "select", %{"id" => root})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute view |> element("#pb-style-base-opacity") |> render() =~ "any length"
    end

    # NOTHING VANISHES WITHOUT A REASON. A master's library read excludes files whose site is switched
    # off, so editing a page that belongs to such a site shows an empty sheet however many files that
    # site really has. An empty shelf with no notice reads as a bug — or as files somebody deleted.
    #
    # The admin itself stays reachable because it is served on the MASTER host, which is active;
    # `SiteLookupPlug` 503s a disabled site's OWN host, so this case only arises for a master editing
    # somebody else's site — which is exactly what `?site_id=` exists for.
    test "the Assets sheet says when the edited site is switched off", %{conn: conn} do
      n = System.unique_integer([:positive])
      off = create_site!(name: "off-#{n}", host: "off-#{n}.test", active: false)
      page = create_page!(site_id: off.id)
      create_media!(site_id: off.id, name: "kept-while-off")

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: off.id,
        name: off.name,
        host: off.host,
        priority: off.priority,
        active: false,
        master: off.master
      })

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{off.id}")

      _loaded = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      assert has_element?(view, "#pb-assets-site-off")
      assert render(view) =~ "Its files are here for you to work with"
      assert render(view) =~ "kept-while-off", "the master still works with the site's own files"
    end

    # A GLOBAL DOCUMENT IS RENDERED BY EVERY SITE, so its gallery offers only files of sites that are
    # up: an inactive or offline site's file would not load for anyone else.
    test "a global document offers only files of sites that are up", %{conn: conn, site: site} do
      n = System.unique_integer([:positive])
      off = create_site!(name: "off-#{n}", host: "off-#{n}.test", active: false)
      quiet = create_site!(name: "quiet-#{n}", host: "quiet-#{n}.test", active: true)
      Enum.each([off, quiet], &cache_site/1)
      {:ok, _} = MishkaCmsCore.Settings.put("cms.offline", true, site_id: quiet.id)

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SettingsState.delete(quiet.id, "cms.offline")
      end)

      create_media!(site_id: site.id, name: "shared-hero")
      create_media!(site_id: off.id, name: "switched-off-hero")
      create_media!(site_id: quiet.id, name: "offline-hero")

      component =
        create_component!(name: "global-banner-#{n}", site_id: nil, template: "<p>hi</p>")

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      render_click(view, "open_sheet", %{"sheet" => "assets"})
      html = render_async(view)

      assert html =~ "shared-hero"
      refute html =~ "switched-off-hero"
      refute html =~ "offline-hero"
    end

    test "and says nothing of the sort while the site is on", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      refute has_element?(view, "#pb-assets-site-off")
    end

    # UPLOADING DURING A PICK IS PICKING. Something asked for a file, which is the only reason the
    # reader opened the library and uploaded at all — and then the sheet stayed open, said
    # "Uploaded", and left them to find the card they had just made and press Use on it.
    test "a file uploaded while something is picking is used straight away", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "shot-up",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-shot-up") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})
      _loaded = render_async(view)

      picture =
        create_media!(
          site_id: site.id,
          name: "just-uploaded",
          type: :images,
          relative_path: "/uploads/new.png"
        )

      send(view.pid, {:form_saved, :create, picture})
      html = render(view)

      assert html =~ "and used it"

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Node.attr_text("image_url") == "/uploads/new.png"

      refute has_element?(view, "#pb-media-target"), "the sheet stayed open after answering"
    end

    # A file the field cannot show is NOT placed, and says so: the gallery is filtered to what the
    # field accepts, so a document uploaded during a picture pick vanishes from the grid the moment
    # it saves — uploaded, invisible, and apparently lost.
    test "and one the field cannot show is kept but not used", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "shot-doc",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-shot-doc") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})
      _loaded = render_async(view)

      doc =
        create_media!(
          site_id: site.id,
          name: "a-contract",
          type: :documents,
          relative_path: "/uploads/deal.pdf"
        )

      send(view.pid, {:form_saved, :create, doc})
      html = render(view)

      assert html =~ "is a document"
      assert html =~ "saved in the library"

      refute view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Node.attr_text("image_url") == "/uploads/deal.pdf"
    end

    # With nothing picking, an upload is just an upload.
    test "and an upload with nothing picking only reports itself", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      shot = create_media!(site_id: site.id, name: "idle-upload")

      send(view.pid, {:form_saved, :create, shot})
      html = render(view)

      assert html =~ "Uploaded"
      refute html =~ "and used it"
    end

    # A component with one media attribute: placed, selected, given a value, Inspector rendered.
    defp media_field_html(conn, page, site, name, value) do
      create_component!(
        site_id: site.id,
        name: name,
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-#{name}") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "image_url",
        "value" => value
      })

      render(view)
    end

    test "Assets says so plainly when the library is empty", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "Assets"

      # The sheet's own words, because its empty state is a folder rather than a whole library: the
      # rail may be sitting on one that happens to have nothing in it.
      assert html =~ "No files in this folder yet"
    end

    # THE SHEET IS A FOLDER RAIL AND A GRID, and the rail is what answers the question the library's
    # Type and Site filters answer on a page — which is why the sheet draws neither.
    test "Assets has a folder rail and only search above the grid", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      html = render_async(view)

      assert html =~ ~s(data-role="pb-assets-folders")
      assert html =~ ~s(id="pb-folder-all")
      assert html =~ ~s(id="pb-assets-search")

      refute html =~ "All types", "the library's Type filter is a page control, not a sheet one"
    end

    test "choosing a folder scopes the grid to it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      refute :sys.get_state(view.pid).socket.assigns.assets_category

      render_click(view, "select_asset_category", %{
        "id" => "6c5cf4ee-0000-4000-8000-000000000001"
      })

      assert :sys.get_state(view.pid).socket.assigns.assets_category ==
               "6c5cf4ee-0000-4000-8000-000000000001"

      # …and "All files" puts it back, rather than filtering for a folder called "__all__".
      render_click(view, "select_asset_category", %{"id" => "__all__"})
      refute :sys.get_state(view.pid).socket.assigns.assets_category
    end

    # A FOLDER INSIDE ANOTHER SITS UNDER IT in the rail, stepped in by how deep it is — the library's
    # tree, read in the one query the rail already makes.
    test "the folder rail nests a folder under the one it is in", %{
      conn: conn,
      page: page,
      site: site
    } do
      photos = create_media_category!(site_id: site.id, name: "Photos")
      videos = create_media_category!(site_id: site.id, name: "Videos")
      year = create_media_category!(site_id: site.id, name: "Year", parent_id: photos.id)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      html = render_async(view)

      rail =
        Regex.scan(~r/id="pb-folder-([0-9a-f-]{36})" data-depth="(\d)"/, html,
          capture: :all_but_first
        )

      assert rail == [[photos.id, "0"], [year.id, "1"], [videos.id, "0"]]
    end

    # WHAT THE SHEET MAKES, IT MAKES IN THE FOLDER IT HAS OPEN — a new folder and an upload alike.
    test "a new folder and an upload start in the folder the rail has open", %{
      conn: conn,
      page: page,
      site: site
    } do
      dir = Path.join(System.tmp_dir!(), "pb_assets_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:mishka_cms_core, :media_static_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :media_static_dir)
        File.rm_rf(dir)
      end)

      photos = create_media_category!(site_id: site.id, name: "Photos")

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      render_async(view)
      render_click(view, "select_asset_category", %{"id" => photos.id})

      render_click(view, "new_folder", %{})

      view
      |> element("#pb-folder-modal #media_category_form-form")
      |> render_submit(%{"form" => %{"name" => "Inner"}})

      inner =
        MishkaCmsCore.Runtime.MediaCategory
        |> Ash.Query.filter(name == "inner")
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      assert inner.parent_id == photos.id

      file =
        file_input(view, "#pb-media-upload #media_form-form", :media_files_media_form, [
          %{name: "shot.png", content: MishkaCmsCore.Test.Files.png(), type: "image/png"}
        ])

      render_upload(file, "shot.png")
      view |> element("#pb-media-upload #media_form-form") |> render_submit(%{"form" => %{}})

      [media] = Ash.read!(MishkaCmsCore.Runtime.Media, tenant: site.id, authorize?: false)
      assert media.media_category_id == photos.id
    end

    # The library's own filters and pagination come with the Gervaz table; the sheet does not
    # reimplement folders. What it DOES own is the scope: an editor only ever browses its own site.
    test "Assets shows this site's library and not another's", %{
      conn: conn,
      page: page,
      site: site
    } do
      other = create_site!()
      create_media!(site_id: site.id, name: "ours-hero")
      create_media!(site_id: other.id, name: "theirs-hero")

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "ours-hero"
      refute html =~ "theirs-hero"
    end

    test "Review names what a comment would be anchored to", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = render(view)
      assert html =~ "Commenting on"
      assert html =~ "h1"
    end

    # A NOTE IS A ROW NOW, not a list on the editing session. What is pinned here is what
    # gets STORED, because that is what has to survive the session: the element it was anchored to,
    # the label captured beside it, its type, and who wrote it.
    test "posting a note anchors it to the selection and stores what it was about", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Tighten this heading", "bug")

      [comment] = notes(site, page)
      assert comment.body == "Tighten this heading"
      assert comment.node_id == h1.id
      assert comment.node_label == "h1"
      assert comment.type == :bug
      assert comment.status == :open
      assert comment.author_type == :human
      assert comment.author_id, "a human note records who wrote it"
    end

    # A COMPOSER THAT KEEPS THE NOTE YOU JUST POSTED IS BROKEN. The form has no `phx-change`, so
    # LiveView does not own its inputs and cannot clear them; changing `defaults` rebuilds it, and
    # the revision on `defaults` is what changes after a write.
    test "the composer resets after a note is posted", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      before = :sys.get_state(view.pid).socket.assigns.review_revision
      post_note(view, "First note", "bug")

      assert :sys.get_state(view.pid).socket.assigns.review_revision > before,
             "the revision is what rebuilds the composer"
    end

    # The same code path with nothing selected. One nullable column is the whole difference.
    test "a note left with nothing selected is about the whole page", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Needs a meta description", "task")

      [comment] = notes(site, page)
      assert comment.node_id == nil
      assert comment.node_label == nil
      assert comment.type == :task
    end

    test "the composer offers every note type, in the order a note's types are named", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_async(view)

      offered =
        view
        |> element("#pb-comment-type")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("option")
        |> LazyHTML.attribute("value")

      assert offered == Enum.map(MishkaCmsCore.Runtime.PageComment.types(), &to_string/1)
    end

    test "an empty note posts nothing and says so", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "   ", "information")

      assert notes(site, page) == []
      assert render(view) =~ "Write something first."
    end

    # Resolving records WHO and WHEN, together or not at all.
    test "resolving a note records the resolver, and reopening clears them", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Fix the spacing", "bug")

      [comment] = notes(site, page)

      # The event, not the button: one button carries BOTH, swapping its `phx-click` when the note's
      # status changes, and `element/2` renders from the HTML the client last applied a diff to — so
      # clicking it twice in a row sends "resolve" twice.
      assert has_element?(view, "#pb-comment-resolve-#{comment.id}")
      render_click(view, "resolve_comment", %{"id" => comment.id})

      [resolved] = notes(site, page)
      assert resolved.status == :resolved
      assert resolved.resolved_at
      assert resolved.resolved_by_id, "who closed it is the thing a thread is asked a week later"

      render_click(view, "reopen_comment", %{"id" => comment.id})

      [reopened] = notes(site, page)
      assert reopened.status == :open
      refute reopened.resolved_at

      refute reopened.resolved_by_id,
             "'resolved by X' on an open note is a claim that is not true"
    end

    test "a note can be deleted", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Never mind", "other")

      [comment] = notes(site, page)
      assert has_element?(view, "#pb-comment-delete-#{comment.id}")
      render_click(view, "delete_comment", %{"id" => comment.id})

      assert notes(site, page) == []
    end

    # THE OPEN / ALL CHIPS ARE A REAL FILTER, not decoration. They used to push Gervaz's `filter`
    # event at a resource that declared no filters, so the handler reduced over an empty list and
    # returned the map it started with — a silent no-op that looked exactly like a working control.
    test "the Open and All chips actually narrow the thread", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Still needs doing", "task")
      post_note(view, "Already handled", "bug")

      handled = Enum.find(notes(site, page), &(&1.body == "Already handled"))
      render_click(view, "resolve_comment", %{"id" => handled.id})
      _flushed = render(view)

      # All — nothing filtered, both notes.
      view |> element("#pb-review-all") |> render_click()
      _loaded = render_async(view)
      all = render(view)
      assert all =~ "Still needs doing"
      assert all =~ "Already handled"

      # Open — the resolved one goes.
      view |> element("#pb-review-open") |> render_click()
      _loaded = render_async(view)
      open = render(view)
      assert open =~ "Still needs doing"
      refute open =~ "Already handled"
    end

    # FIFTY AT A TIME, then more on demand. `keep_loaded_records true` is what makes "more" ACCUMULATE
    # — it re-reads pages 1..N in one query rather than replacing the list with page N — and the
    # button is gated on `has_more?`, which is the only field that is right during a load.
    test "the thread pages fifty at a time and loads more on demand", %{
      conn: conn,
      page: page,
      site: site
    } do
      for n <- 1..62 do
        MishkaCmsCore.Runtime.PageComment
        |> Ash.Changeset.for_create(
          :create,
          %{
            body: "Note number #{n}",
            type: :information,
            section: :page,
            document_id: page.id
          },
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()
      end

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      _loaded = render_async(view)

      cards = fn html ->
        html |> String.split(~s(<article id="pb-comment-)) |> length() |> Kernel.-(1)
      end

      first = render(view)
      assert cards.(first) == 50, "one page is fifty"
      assert first =~ "pb-review-more", "there is more, so it has to be offered"

      view |> element("#pb-review-more") |> render_click()
      _loaded = render_async(view)

      second = render(view)
      assert cards.(second) == 62, "load-more accumulates rather than replacing the page"
      refute second =~ "pb-review-more", "and stops offering once there is nothing left"
    end

    # THE COUNTER IS UNRESOLVED BUGS AND IT IS DERIVED. Every one of the four things that can
    # change it is exercised here, because a hard-coded counter passes any test that only creates.
    test "the Review badge counts unresolved bugs, and only those", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      assert review_badge(view) == nil

      render_click(view, "open_sheet", %{"sheet" => "review"})

      # A note that is not a bug does not move it.
      post_note(view, "Looks good", "information")
      assert review_badge(view) == nil

      post_note(view, "Broken on mobile", "bug")
      post_note(view, "Overlaps the footer", "bug")
      assert review_badge(view) == "2"

      bug = Enum.find(notes(site, page), &(&1.type == :bug))

      render_click(view, "resolve_comment", %{"id" => bug.id})
      assert review_badge(view) == "1"

      render_click(view, "reopen_comment", %{"id" => bug.id})
      assert review_badge(view) == "2"

      render_click(view, "delete_comment", %{"id" => bug.id})
      assert review_badge(view) == "1"
    end

    # WHO MAY CLOSE A NOTE, and — since a shared document became a master's to open — who may reach
    # the thread at all. `PageComment` will only accept a site-less note on a section that can BE
    # site-less, so a shared note lives on a shared component or a shared layout and nowhere else;
    # and those are the two documents a tenant is now turned away from. The thread is a master's,
    # entirely, and the door is where that is decided rather than the button inside it.
    #
    # The reader who is refused is told what happened, which is the part worth pinning: silence here
    # reads as a broken link. `MishkaCmsCoreWeb.Test.EditorTenancyTest` covers the rule in full.
    test "a shared component's review thread is not a tenant's to reach", %{
      conn: conn,
      site: site
    } do
      component = create_component!(name: "shared-box", template: ~s(<div>shared</div>))

      {:ok, note} =
        MishkaCmsCore.Runtime.PageComment
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            body: "Broken for everyone",
            type: :bug,
            section: :component,
            document_id: component.id
          },
          authorize?: false
        )
        |> Ash.create()

      assert is_nil(note.site_id), "the note under test has to be the shared kind"

      tenant_conn = log_in(build_conn_for_host(), create_admin("tenant@example.com", site.id))

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(tenant_conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert to == "/admin/dashboard/runtime/components"
      assert flash["error"] =~ "shared with every site"

      # And the master, who does open it, is offered the button the tenant was not.
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      _thread = render_async(view)

      html = render(view)
      assert html =~ "Broken for everyone"
      assert html =~ "pb-comment-resolve-#{note.id}"
      refute html =~ "Master closes this"
    end

    # A NOTE'S ID IS NOT AUTHORITY. The three note handlers take `phx-value-id` straight from the
    # client, and the write behind them read the TENANT off the note it was handed — so a
    # site-scoped admin's Delete ran under the VICTIM's tenant, which satisfied `TenantContext`, the
    # multitenancy filter and the policy alike. Nothing downstream could tell. Scoped by who is
    # asking now, the way `delete_snippet` has always been.
    test "a tenant cannot reach another site's note by typing its id", %{conn: conn, site: site} do
      other_site = create_site!(name: "elsewhere", host: "elsewhere.test")
      foreign_page = create_page!(site_id: other_site.id, name: "their-page", path: "/their-page")

      {:ok, foreign_note} =
        MishkaCmsCore.Runtime.PageComment
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            body: "A private note on another site",
            type: :bug,
            section: :page,
            document_id: foreign_page.id,
            site_id: other_site.id
          },
          authorize?: false
        )
        |> Ash.create()

      own_page = create_page!(site_id: site.id, name: "our-page", path: "/our-page")
      tenant = create_admin("tenant-notes@example.com", site.id)
      {:ok, view, _html} = open_builder(log_in(build_conn_for_host(), tenant), own_page)

      for event <- ~w(resolve_comment reopen_comment delete_comment) do
        render_click(view, event, %{"id" => foreign_note.id})
      end

      assert {:ok, survivor} =
               Ash.get(MishkaCmsCore.Runtime.PageComment, foreign_note.id,
                 action: :get_any,
                 authorize?: false
               )

      assert survivor.status == :open, "#{survivor.status}: another site's note was resolved"
      refute survivor.resolved_by_id

      # Their OWN site's notes are still theirs to resolve and delete — the writes run under the
      # domain's authorization now rather than with it turned off, so this is what says the policy
      # lets a site admin through.
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Ours to close", "task")
      [mine] = notes(site, own_page)

      render_click(view, "resolve_comment", %{"id" => mine.id})
      assert [%{status: :resolved}] = notes(site, own_page)

      render_click(view, "delete_comment", %{"id" => mine.id})
      assert notes(site, own_page) == []

      # And the master, whose notes these are to manage, still deletes it.
      {:ok, master_view, _html} = open_builder(conn, foreign_page)
      render_click(master_view, "delete_comment", %{"id" => foreign_note.id})

      assert {:error, _gone} =
               Ash.get(MishkaCmsCore.Runtime.PageComment, foreign_note.id,
                 action: :get_any,
                 authorize?: false
               )
    end

    # WHICH EDITOR AM I IN, AND WHOSE DOCUMENT IS THIS. Four sections share one address shape, one
    # chrome and — until this — one title. A tab strip with a page, its layout and a component open
    # read "Page Builder" three times, and nothing anywhere on the component editor said whether the
    # row being changed belonged to this site or to every site.
    test "the header names the section it is editing, not always the page", %{conn: conn} do
      component = create_component!(name: "shared-box", template: ~s(<div>shared</div>))

      {:ok, _view, html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert html =~ "Component builder"
      refute html =~ "Page Builder"
      assert html =~ "shared-box.heex"
    end

    test "a site-less component is badged Global, a site's own is badged by name", %{
      conn: conn,
      site: site
    } do
      shared = create_component!(name: "shared-box", template: ~s(<div>shared</div>))
      owned = create_component!(name: "own-box", site_id: site.id, template: ~s(<div>own</div>))

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{shared.id}")

      assert has_element?(view, "[data-role=pb-scope]", "Global")

      {:ok, mine, _html} = live(conn, "/admin/dashboard/runtime/builder/component/#{owned.id}")

      assert has_element?(mine, "[data-role=pb-scope]", site.name)
      refute has_element?(mine, "[data-role=pb-scope]", "Global")
    end

    test "a layout editor says layout and a page editor still says page", %{
      conn: conn,
      site: site,
      page: page
    } do
      layout = create_layout!(name: "shell", site_id: site.id, template: ~s(<div>{@inner}</div>))

      {:ok, _layout_view, layout_html} =
        live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert layout_html =~ "Layout builder"

      {:ok, _page_view, page_html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert page_html =~ "Page builder"
    end

    # THE HANDOVER. The ring is client state, so a frame that has just mounted has none — even when
    # the session it mounted from has had something selected all along. The server has to say what
    # is selected, once, on the root; without it the toolbar renders (the server knows) and the hook
    # hides it again (no node carries the ring), which reads as "selected, but no toolbar".
    test "the canvas is told what is already selected when it mounts", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(data-selection="#{h1.id}")
      assert html =~ "pb-el-toolbar", "the bar the ring is drawn for"
    end

    # …and re-asking for the selection the session already holds must still tell the client. That is
    # exactly what a review note about the selected element does.
    test "selecting the already-selected element still announces it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      render_click(view, "select", %{"id" => h1.id})

      assert_push_event(canvas, "pb:selected", %{id: id})
      assert id == h1.id
    end

    # MOVING AN IFRAME RELOADS IT — a browser rule, not a LiveView one. The flash used to be two
    # top-level `:if` divs, so showing one INSERTED a sibling before the page, LiveView shifted the
    # tree under it, and the canvas was thrown away and fetched again on every "Saved" and every
    # "Note posted". A wrapper that is always there means notices come and go INSIDE it.
    test "the flash wrapper is present even with nothing to say", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ ~s(id="mishka-flash")
      refute html =~ ~s(id="flash-info"), "nothing to show yet"

      # …and it is the same wrapper once there is something in it.
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Something to say", "information")

      posted = render(view)
      assert posted =~ ~s(id="mishka-flash")
      assert posted =~ ~s(id="flash-info")

      # The notice dismisses itself, client-side — the hook is what carries the clock.
      assert posted =~ ~s(phx-hook="FlashAutoDismiss")
      assert posted =~ ~s(data-dismiss-after)
    end

    # A NOTE IS NOT A DOCUMENT CHANGE. Notes ride the session topic so both editors' sheets follow
    # each other, but re-reading the session in the canvas rebuilds the whole document — which the
    # author sees as the page flashing every time anyone types a comment.
    # The canvas must not so much as LOOK at the session for a review message. Comparing the tree
    # afterwards proves nothing — re-reading gives an equal tree — so this proves it by making the
    # read impossible: with the session gone, anything that re-reads it flips the frame to
    # "expired", and ignoring the message leaves the canvas exactly as it was.
    test "a review message does not make the canvas re-read the session", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      token = token(view)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token}")

      refute :sys.get_state(canvas.pid).socket.assigns.missing?

      MishkaCmsCore.Runtime.States.EditorSessionState.delete(token)

      send(canvas.pid, {:builder_session, token, {:review, :changed}})
      _rendered = render(canvas)
      refute :sys.get_state(canvas.pid).socket.assigns.missing?, "a note is not a document change"

      # …and anything that IS a document change still is.
      send(canvas.pid, {:builder_session, token, {:op_applied, :insert}})
      _rendered = render(canvas)
      assert :sys.get_state(canvas.pid).socket.assigns.missing?
    end

    # REPLIES. The shape is `MishkaBlog.Comment`'s — a nullable self-reference and its reverse — and
    # so is the move: Reply seeds the composer's `defaults` with the parent rather than opening a
    # second form.
    test "replying threads the answer under the question", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Is this heading final?", "question")
      [question] = notes(site, page)

      # MOVE THE SELECTION FIRST. A reply anchored to whatever happens to be selected when Reply is
      # pressed would file the answer against a different element than the question — and with the
      # selection left on the h1 the two answers are the same string, so the test could not tell.
      elsewhere = node_with_tag(view, "p")
      render_click(view, "select", %{"id" => elsewhere.id})

      # Arming a reply changes what the composer says it is doing.
      armed = render_click(view, "reply_to_comment", %{"id" => question.id})
      assert armed =~ "Replying to"
      assert armed =~ "Post reply"
      assert armed =~ "pb-comment-cancel-reply"

      post_note(view, "Yes, signed off yesterday", "information")

      # The thread still holds ONE note: the answer is under the question, not beside it.
      assert [threaded] = notes(site, page)
      assert threaded.id == question.id
      assert [reply] = threaded.replies
      assert reply.body == "Yes, signed off yesterday"
      assert reply.parent_comment_id == question.id

      # …and it inherited what the question was about, not whatever is selected now.
      assert reply.node_id == h1.id
      assert reply.node_label == "h1"

      # Posting it ends reply mode.
      assert render(view) =~ "Commenting on"
    end

    test "cancelling a reply goes back to writing a new note", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "A question", "question")

      [question] = notes(site, page)
      assert render_click(view, "reply_to_comment", %{"id" => question.id}) =~ "Replying to"
      assert render_click(view, "cancel_reply", %{}) =~ "Commenting on"
    end

    # A reply answers a note that already has a type; letting it carry its own would double-count it
    # in the badge.
    test "a reply is not a bug of its own", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Broken here", "bug")

      [bug] = notes(site, page)
      assert review_badge(view) == "1"

      render_click(view, "reply_to_comment", %{"id" => bug.id})
      post_reply(view, "Fixing it now")

      assert review_badge(view) == "1", "a reply must not add to the count"
      assert [%{replies: [reply]}] = notes(site, page)
      assert reply.type == :information
    end

    test "the answers are drawn under the question", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "The question", "question")

      [question] = notes(site, page)
      render_click(view, "reply_to_comment", %{"id" => question.id})
      post_note(view, "The answer", "information")

      html = render_async(view)
      assert html =~ "The question"
      assert html =~ "The answer"
      assert [%{replies: [reply]}] = notes(site, page)
      assert html =~ "pb-comment-#{reply.id}"
    end

    # NAMING SOMEBODY. The browser decides WHEN — it is the only thing that knows where the caret
    # is — so the search arrives as a hook push rather than a click.
    test "typing @ offers the people who can be named", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      assert render_hook(view, "mention_search", %{"q" => "bo"}) =~
               ~s(data-handle="boss@example.com")

      refute render_hook(view, "mention_search", %{"q" => "zz"}) =~ "pb-mention-list"
    end

    # PICKING IS THE BROWSER'S — it owns the caret, the arrow keys and the highlight. What the server
    # has to put in the markup is what the hook reads: the handle, and a row that starts highlighted.
    test "the list carries what the keyboard picks with", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = render_hook(view, "mention_search", %{"q" => "bo"})

      assert html =~ ~s(data-handle="boss@example.com")
      assert html =~ ~s(data-index="0")
      assert html =~ ~s(data-active="true")
    end

    test "leaving the word closes the list", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      assert render_hook(view, "mention_search", %{"q" => ""}) =~
               ~s(data-handle="boss@example.com")

      refute render_hook(view, "mention_close", %{}) =~ ~s(data-handle="boss@example.com")
    end

    # BEING NAMED IS ADDRESSED TO YOU, so your own chip is the filled one. The handle is the email's
    # local part, so the reader of this test IS `@boss`.
    test "your own name is drawn differently from anybody else's", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = post_note(view, "@boss@example.com and @someone@else.test", "information")

      assert html =~ ~s(data-role="pb-mention-self")
      assert html =~ "boss@example.com — this is you"
      assert html =~ ~s(data-role="pb-mention")
    end

    # A NAME IN A NOTE IS DRAWN AS ONE. Segments rather than injected markup, so this also pins that
    # a body is still text: the chip is a span the template made, not something the body said.
    test "a name in a note is drawn as a chip", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = post_note(view, "@boss@example.com please look at <b>this</b>", "question")

      assert html =~ ">@boss@example.com</span>"
      refute html =~ "<b>this</b>", "a body is text, not markup"
    end

    # THE ANCHOR HAS TO SURVIVE THE PARSE THAT WROTE IT. Node ids are minted per parse, so a
    # colleague reading the note in their own session computes a different id for the same element —
    # and the note used to tell them the element was gone. The stored path is what both of them agree
    # on.
    test "a note's element can be found from another session", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About this heading", "question")

      [note] = notes(site, page)
      assert note.node_path, "an element note has to record where the element sits"

      {:ok, other, _html} = open_builder(colleague(conn), page)
      their_h1 = node_with_tag(other, "h1")

      assert their_h1.id != note.node_id,
             "two sessions mint different ids; without that this proves nothing"

      render_click(other, "open_sheet", %{"sheet" => "review"})
      render_click(other, "goto_comment", %{"id" => note.id})

      assert editor(other).selection == their_h1.id
      refute render(other) =~ "no longer on this page"
    end

    # The path is a position, and a position is only right if what sits there is still the same kind
    # of thing. Deleting an element slides its neighbour into that index.
    test "a note does not select whatever slid into its place", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About this heading", "question")

      [note] = notes(site, page)

      {:ok, other, _html} = open_builder(colleague(conn), page)
      render_click(other, "op", %{"kind" => "delete", "node_id" => node_with_tag(other, "h1").id})
      render_click(other, "open_sheet", %{"sheet" => "review"})
      render_click(other, "goto_comment", %{"id" => note.id})

      assert render(other) =~ "no longer on this page"
    end

    # A NOTE ABOUT THE PAGE, WITH SOMETHING SELECTED. The composer follows the canvas, which is right
    # nearly always and wrong exactly when the thing to be said is about the page rather than the
    # element under the cursor. Deselecting to say it would lose the place you were working in.
    test "the scope can be cleared to the whole page without deselecting", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      assert render(view) =~ "pb-comment-whole-page"

      cleared = render_click(view, "comment_on_page", %{})
      refute cleared =~ "pb-comment-whole-page", "there is nothing left to clear"

      post_note(view, "About the page as a whole", "information")

      assert [note] = notes(site, page)
      refute note.node_id, "the note is about the page, not the element still selected"
      refute note.node_path
      assert editor(view).selection == h1.id, "clearing the scope must not clear the canvas"
    end

    # …and choosing another element is choosing what the next note is about, so the override ends.
    test "selecting an element takes the composer back off the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(view, "comment_on_page", %{})

      refute render(view) =~ "pb-comment-whole-page"

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})

      # The composer REBUILDS when what it is about changes, and a rebuilt Gervaz form draws its
      # skeleton until it has loaded.
      html = render_async(view)

      assert html =~ "pb-comment-whole-page"
      assert html =~ "&lt;p&gt;"
    end

    # A LOCAL PART IS NOT A NAME. Two people called `master` are two people, and a byline reading
    # "master" says which of them wrote this to nobody.
    test "the byline is the whole address", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = post_note(view, "Mine", "information")

      assert html =~ ">boss@example.com<"
      refute html =~ ">boss<"
    end

    # A MASTER'S ADDRESS IS NOT A TENANT'S TO HAVE. The masters work across every site on the
    # deployment, so putting one's email in a customer's sidebar hands them the platform's own
    # contact details. The activity feed already draws this line; the thread draws it too.
    test "a tenant sees a master's note without seeing the master", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Written by a master", "information")

      tenant_conn = log_in(build_conn_for_host(), create_admin("tenant@example.com", site.id))
      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})

      theirs_html = render_async(theirs)
      [note] = notes(site, page)

      assert theirs_html =~ "Written by a master", "the note itself is theirs to read"
      assert byline(theirs, note) == {"M", "Master"}
      refute theirs_html =~ "boss@example.com"
      refute theirs_html =~ ">boss<", "not even the local part"

      # …and a master reading the same note sees the whole address.
      assert byline(view, note) == {"B", "boss@example.com"}
    end

    test "a site admin reads a master named in a note as @Master", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_admin("other.master@platform.test")
      create_admin("named-tenant@example.com", site.id)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "@other.master@platform.test and @named-tenant@example.com look", "task")
      [note] = notes(site, page)

      tenant_conn = log_in(build_conn_for_host(), create_admin("reader@example.com", site.id))
      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})
      render_async(theirs)

      assert note_mentions(theirs, note) == ["@Master", "@named-tenant@example.com"]
      refute render(theirs) =~ "other.master"

      assert note_mentions(view, note) == [
               "@other.master@platform.test",
               "@named-tenant@example.com"
             ]
    end

    test "a site admin sees who resolved a note, and a master only as Master", %{
      conn: conn,
      page: page,
      site: site
    } do
      tenant = create_admin("resolver-tenant@example.com", site.id)
      tenant_conn = log_in(build_conn_for_host(), tenant)

      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})
      post_note(theirs, "Raised by the site", "bug")
      [note] = notes(site, page)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(view, "resolve_comment", %{"id" => note.id})
      render_async(view)

      assert byline(view, note) == {"RT", "resolver-tenant@example.com"}
      assert resolver_line(view, note) =~ "Resolved by boss@example.com"

      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})
      render_async(theirs)

      assert byline(theirs, note) == {"RT", "resolver-tenant@example.com"}
      assert resolver_line(theirs, note) =~ "Resolved by Master"
      refute render(theirs) =~ "boss@example.com"
      refute render(theirs) =~ ">boss<"
    end

    # MOTION IN BOTH DIRECTIONS. An overlay gated by `:if` is gone from the DOM the instant the assign
    # flips, so a CSS leave transition never gets a frame — `phx-remove` is what makes LiveView hold
    # the node back and run the commands first. Without it the close is the one that snaps, and it is
    # the one nobody notices is missing until it is there.
    test "the sheet arrives and leaves with motion", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render_click(view, "open_sheet", %{"sheet" => "review"})

      assert html =~ ~s(id="pb-sheet")
      assert html =~ "phx-mounted"
      assert html =~ "phx-remove"
      assert html =~ "duration-200", "the enter"
      assert html =~ "duration-150", "and the leave"
    end

    # PREVIEW IS A TOGGLE, and the caret only exists where there is a second way. A page with no
    # draft has none, and a caret with nothing behind it turns one click into a choice.
    test "preview has no caret without a draft to share", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      assert html =~ ~s(id="pb-preview")
      refute html =~ ~s(id="pb-preview-menu")
      refute html =~ ~s(id="pb-preview-tab")
    end

    test "preview still toggles between the editor and the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      refute editor(view).preview?

      render_click(view, "toggle_preview", %{})
      assert editor(view).preview?

      render_click(view, "toggle_preview", %{})
      refute editor(view).preview?
    end

    # A draft has a URL somebody who is not editing can open, so it — and only it — gets the caret.
    test "a shareable draft gets a caret with the link behind it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      autosave!(view)

      html = render(view)
      assert html =~ ~s(id="pb-preview-menu")

      opened = render(view)
      assert opened =~ ~s(id="pb-preview-tab")
      assert opened =~ "Open in a new tab"
      assert opened =~ "The shareable link"
      assert opened =~ ~s(target="_blank")

      # …and the link is a link, not a way of changing what the button does.
      refute editor(view).preview?
    end

    # A DESCRIPTION GOES UNDER THE TITLE. Beside it the two ran together into one line that read as
    # neither, so the markup has to put the label in a block of its own.
    test "a menu item's description sits under its title", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert [_all, between] = Regex.run(~r/Draft history(.*?)Open a saved draft/s, html)
      assert between =~ "</span>", "the title closes before the description starts"
      assert between =~ "block", "and the description is its own block"
    end

    # A note is only actionable if the reader can get to what it is about.
    test "a note's chip selects the element it was written about", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Here", "suggestion")

      render_click(view, "select", %{"id" => nil})
      refute editor(view).selection

      [comment] = notes(site, page)
      render_click(view, "goto_comment", %{"id" => comment.id})

      assert editor(view).selection == h1.id
    end

    # And when it is not, that is a sentence rather than a crash. The id is the editor's own
    # handle, minted fresh by every parse, so it goes stale by construction.
    test "a note pointing at a deleted element says so instead of failing", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About this heading", "question")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      [comment] = notes(site, page)
      html = render_click(view, "goto_comment", %{"id" => comment.id})

      assert html =~ "no longer on this page"
    end

    test "a page-level note says it is about the page rather than going nowhere", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About the page", "information")

      [comment] = notes(site, page)
      assert render_click(view, "goto_comment", %{"id" => comment.id}) =~ "the whole page"
    end

    # Nothing here implements AI review. What is pinned is that when something does, it is a
    # value in an existing column rather than a second comment system beside this one. The system
    # writes it through `:master_create`; the tenant `:create` takes no author from input.
    test "a note can be written by an AI or by the system", %{page: page, site: site} do
      for author_type <- [:ai, :system] do
        assert {:ok, comment} =
                 MishkaCmsCore.Runtime.PageComment
                 |> Ash.Changeset.for_create(
                   :master_create,
                   %{
                     body: "Contrast is below AA here",
                     type: :bug,
                     section: :page,
                     document_id: page.id,
                     site_id: site.id,
                     author_type: author_type
                   },
                   authorize?: false
                 )
                 |> Ash.create()

        assert comment.author_type == author_type
        assert comment.author_id == nil, "an AI or system note has no user row"
      end

      assert length(notes(site, page)) == 2
    end

    # Both browsers in a session share one document, so they share one thread — which is now true
    # because the thread is a table, not a copy of a list.
    test "a note posted in one session is visible to the other editor", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      token = token(view)

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{token}")

      render_click(second, "open_sheet", %{"sheet" => "review"})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Seen by both", "information")

      [comment] = notes(site, page)
      assert comment.body == "Seen by both"

      # The second editor reads the same rows, so re-opening its sheet shows the note.
      render_click(second, "open_sheet", %{"sheet" => "review"})
      _loaded = render_async(second)
      assert render(second) =~ "Seen by both"
    end

    # TWO PEOPLE WHO EACH OPENED THIS PAGE FROM THE LIST share no session and no session topic — the
    # rows are the only thing they have in common. The thread follows them, on the resource's own
    # `pub_sub`, so a note arrives while the other editor is looking at it.
    test "a note reaches an editor in a session of their own", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, other, _html} = open_builder(colleague(conn), page)

      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(other, "open_sheet", %{"sheet" => "review"})

      assert token(view) != token(other),
             "two people editing one page have two sessions; without that this proves nothing"

      post_note(view, "Written next door", "information")

      # No click, no reload: the other editor's thread re-read on the broadcast alone.
      assert render_async(other) =~ "Written next door"
    end

    # The badge is a count of rows, so it has to move for the same reason the thread does.
    test "the bug counter follows somebody else's note", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, other, _html} = open_builder(colleague(conn), page)

      render_click(view, "open_sheet", %{"sheet" => "review"})
      assert review_badge(other) == nil

      post_note(view, "Broken next door", "bug")

      _settled = render_async(other)
      assert review_badge(other) == "1"
    end

    # A note about ANOTHER page arrives on the same topic — the topic knows only the site. The thread
    # would never SHOW it, because the read is scoped by document either way; what the check buys is
    # that a busy site does not make every open editor re-read for every note in it. So the thing to
    # assert is the work, not the words.
    test "a note about another page does not disturb this thread", %{
      conn: conn,
      page: page,
      site: site
    } do
      elsewhere = create_page!(site_id: site.id)
      {:ok, view, _html} = open_builder(conn, elsewhere)
      {:ok, other, _html} = open_builder(colleague(conn), page)

      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(other, "open_sheet", %{"sheet" => "review"})

      before = revision(other)
      post_note(view, "About the other page", "information")
      _settled = render_async(other)

      refute render(other) =~ "About the other page"

      assert revision(other) == before,
             "a note about another document must not cost this thread a read"
    end

    # OUR OWN NOTE COMES BACK TO US on the same topic everybody else hears it on. `refresh_review/1`
    # has already re-read, synchronously, so handling the echo as well would make the author pay for
    # every note twice — a second `:for_editor` read and a second `COUNT` for nothing.
    test "the author does not re-read their own note twice", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      before = revision(view)
      post_note(view, "Mine", "information")

      assert revision(view) == before + 1,
             "the write re-read the thread once; the broadcast must not re-read it again"
    end

    defp revision(view), do: :sys.get_state(view.pid).socket.assigns.review_revision

    # §Reply — the composer announces what it is for, so the caret has to be in it.
    test "replying puts the caret in the composer", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "A question", "question")

      [question] = notes(site, page)
      render_click(view, "reply_to_comment", %{"id" => question.id})

      assert_push_event(view, "gervaz:exec-js", %{target: "pb-comment-body", js: js})
      assert js =~ "focus"

      render_click(view, "cancel_reply", %{})
      assert_push_event(view, "gervaz:exec-js", %{target: "pb-comment-body"})
    end
  end
end
