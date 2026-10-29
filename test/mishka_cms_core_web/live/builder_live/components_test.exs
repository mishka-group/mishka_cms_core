# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.ComponentsTest do
  @moduledoc """
  The palette, drag and drop, and writing components: kinds, lifecycle, interface and nesting.
  """
  use MishkaCmsCore.BuilderLiveCase

  # A READER HAS TO BE ABLE TO TELL THE TWO APART. A live component answers clicks and keeps
  # state between renders; a function component structurally cannot. Two cards, two rows and two
  # inspector panels that look identical are a choice the author cannot make, and they find out
  # which they picked by publishing.
  # AN AUTHOR WRITES THE COMPONENT'S OWN LIFECYCLE, in the editor, and it runs.
  #
  # This looks blocked, and the blocker is real for the question a page raises: a PAGE author
  # cannot target a component, because `@myself` is not in scope in a page template and the canvas
  # strips every `phx-*` written on a `<.component>` node. But that is not the question a
  # component's author asks. Inside the COMPONENT's own template `@myself` is in scope — that is what
  # compiling to a `Phoenix.LiveComponent` bought — so a component's handler has a door, and the
  # Helpers tab is where it is written.
  describe "writing a live component's lifecycle in the editor" do
    defp live_component!(site_id) do
      create_component!(
        name: "editable-live",
        site_id: site_id,
        stateful: true,
        template:
          ~s(<div id={@id} {@rest}><button phx-click="tick" phx-target={@myself}>go</button></div>),
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
      )
    end

    test "the Helpers tab says which three names are the lifecycle", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, live_component!(site.id))

      render_click(view, "source_tab", %{"tab" => "helpers"})

      assert has_element?(view, ~s([data-role="pb-lifecycle-note"])),
             "a live component's author is not told that handle_event is its own"

      html = render(view)
      assert html =~ "handle_event(name, params, socket)"
      assert html =~ "phx-target"
    end

    # AND A FUNCTION COMPONENT IS NOT TOLD SOMETHING UNTRUE. It has no lifecycle to write: a
    # `handle_event` on one is a plain function nothing will ever call.
    test "and a function component is not", %{conn: conn, site: site} do
      plain = create_component!(name: "editable-plain", site_id: site.id)
      {:ok, view} = open_component(conn, plain)

      render_click(view, "source_tab", %{"tab" => "helpers"})

      refute has_element?(view, ~s([data-role="pb-lifecycle-note"]))
    end

    # AND HOW FAR IT REACHES. A component's handler runs in whatever LiveView renders it, so a
    # global one's runs inside every tenant's page. Nothing scopes that — it is what shared means —
    # so it is said where the handler is written, and said only where it is true.
    test "a global one's note says its code runs on every site", %{conn: conn} do
      {:ok, view} = open_component(conn, live_component!(nil))

      render_click(view, "source_tab", %{"tab" => "helpers"})

      assert has_element?(
               view,
               ~s([data-role="pb-lifecycle-note"] [data-role="pb-lifecycle-shared"]),
               "runs on every site that places it"
             ),
             "a global live component's author is not told its handlers run on every site"
    end

    test "and one site's note does not", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, live_component!(site.id))

      render_click(view, "source_tab", %{"tab" => "helpers"})

      assert has_element?(view, ~s([data-role="pb-lifecycle-note"]))

      refute has_element?(view, ~s([data-role="pb-lifecycle-shared"])),
             "a component of one site was said to run on every site"
    end

    # THE ROUND TRIP. Written in the editor, stored on the row, and — because `Changes.SignCode` is
    # on the component's own update action and `Helper` now has somewhere to keep a signature —
    # stored SIGNED, which is what makes it run rather than compile to an inert clause.
    test "a handler written here is saved, and saved signed", %{conn: conn, site: site} do
      Application.put_env(:mishka_cms_core, :code_signing_key, "a-test-signing-key-long-enough")
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :code_signing_key) end)

      component = live_component!(site.id)
      {:ok, view} = open_component(conn, component)

      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> form("#pb-code-form", %{
        "tab" => "helpers",
        "entry" => %{
          "0" => %{
            "name" => "handle_event",
            "args" => ~s|"tick", _params, socket|,
            "code" => "{:noreply, socket}"
          }
        }
      })
      |> render_submit()

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)

      assert [helper] = stored.helpers
      assert helper.name == "handle_event"

      assert is_binary(helper.signature),
             "the handler was stored unsigned, so it would compile to an inert clause"

      assert MishkaCmsCore.Runtime.PageBuilder.CodeSignature.trusted?(helper)
    end
  end

  describe "which kind of component this is" do
    defp select_placed(view, name) do
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => name})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == name))

      assert placed, "#{name} was not placed"
      render_click(view, "select", %{"id" => placed.id})

      # THE INSPECTOR IS A TAB, and picking from the palette leaves the palette showing — a click on
      # the canvas is what swings the rail over. Asserting without this reads a panel that is not on
      # screen.
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      view
    end

    test "the palette marks a live one and leaves a plain one unmarked", %{
      conn: conn,
      page: page,
      site: site
    } do
      _live = create_component!(name: "live-card", site_id: site.id, stateful: true)
      _plain = create_component!(name: "plain-card", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s(#pb-comp-live-card [data-role="pb-livedot"])),
             "a live component's card said nothing about being live"

      refute has_element?(view, ~s(#pb-comp-plain-card [data-role="pb-livedot"]))
    end

    test "and the inspector says so over the selected one", %{
      conn: conn,
      page: page,
      site: site
    } do
      _live = create_component!(name: "live-selected", site_id: site.id, stateful: true)
      _plain = create_component!(name: "plain-selected", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      select_placed(view, "live-selected")

      assert has_element?(view, ~s([data-role="pb-insp-kind"])),
             "the inspector did not say the selected component keeps state"

      select_placed(view, "plain-selected")

      refute has_element?(view, ~s([data-role="pb-insp-kind"])),
             "a function component was labelled as live"
    end
  end

  # THE FLAG HAS TO SURVIVE THE PALETTE. The palette's query names its columns explicitly, and
  # an unselected attribute is not an error and is not `%Ash.NotLoaded{}` — the struct field reads
  # `nil`, which is falsy. Miss it and every component reads as stateless, no drop is ever given an
  # id, and a live component placed on a page raises in the visitor's LiveView instead.
  describe "a stateful component in the palette" do
    test "the entry carries the flag the row declared", %{conn: conn, page: page, site: site} do
      _live = create_component!(name: "live-thing", site_id: site.id, stateful: true)
      _plain = create_component!(name: "plain-thing", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      assert entry(view, "live-thing").stateful? == true
      assert entry(view, "plain-thing").stateful? == false
    end

    # AND A DROP OF ONE CARRIES AN ID. A `Phoenix.LiveComponent` cannot exist without one —
    # `Phoenix.LiveView.Diff` raises — so this is not a nicety the kit opts into by declaring an
    # `id` attr, which is the question asked of a function component.
    test "placing one mints an id even though it declares no id attr", %{
      conn: conn,
      page: page,
      site: site
    } do
      _live = create_component!(name: "live-drop", site_id: site.id, stateful: true)

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => "live-drop"})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "live-drop"))

      assert node, "the component was not placed"
      assert {:string, id} = Node.attr(node, "id")
      assert String.starts_with?(id, "phx-"), "got #{inspect(id)}"
    end

    # A FUNCTION COMPONENT IS UNCHANGED. Minting an id for one that declares nothing to read it
    # would put an attribute in the saved markup that no rule refers to.
    test "and a plain one that declares no id still gets none", %{
      conn: conn,
      page: page,
      site: site
    } do
      _plain = create_component!(name: "plain-drop", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => "plain-drop"})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "plain-drop"))

      assert node, "the component was not placed"
      assert Node.attr(node, "id") == nil
    end
  end

  describe "the examples modal" do
    setup %{site: site} do
      create_component!(
        site_id: site.id,
        name: "promo-card",
        extra: %{
          "examples" => [
            %{
              "label" => "Base",
              "base" => true,
              "section" => nil,
              "requires" => %{"components" => ["promo-title"]},
              "source" =>
                ~s(<.component component_name="promo-card" site="Global" variant="bordered" color="info"><h3>Deal</h3></.component>)
            },
            %{
              "label" => "Filled",
              "base" => false,
              "section" => "Variants",
              "requires" => %{},
              # Furnished, like the Base one: curation now ranks an empty-bodied example below any
              # with content and drops it when the component has better — see `Examples.substance/1`.
              "source" =>
                ~s(<.component component_name="promo-card" site="Global" variant="filled"><h3>Filled deal</h3></.component>)
            }
          ]
        }
      )

      :ok
    end

    test "a component with examples shows a badge that opens the modal", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")

      html = render(view)
      assert html =~ "pb-examples"
      assert html =~ "2 variants"
      assert html =~ "Base"
      assert html =~ "Filled"
      # It opens on the first variant, showing the preview rather than the source.
      assert has_element?(view, "#pb-example-preview-0-desktop")
      assert has_element?(view, "#pb-example-insert")
      assert html =~ "also uses promo-title"
    end

    # §8: the old editor read only `ast[0][0]`, so an example's attributes and children never made
    # it onto the page. The whole parsed subtree is inserted here.
    test "inserting an example keeps its attributes AND its children", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")
      render_click(view, "insert_example", %{"index" => "0"})

      tree = view |> editor() |> Map.fetch!(:tree)
      inserted = tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "promo-card"))

      assert Node.attr(inserted, "variant") == {:string, "bordered"}
      assert Node.attr(inserted, "color") == {:string, "info"}
      assert tree |> Tree.walk() |> Enum.any?(&(&1.tag == "h3"))
    end

    # Every kit example hardcodes site="Global"; on a tenant page that would bind the node to the
    # wrong compiled module.
    test "inserting an example rebinds site to this page's scope", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")
      render_click(view, "insert_example", %{"index" => "1"})

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "promo-card"))

      assert Node.attr(inserted, "site") == {:string, "localhost"}
      refute Node.attr(inserted, "site") == {:string, "Global"}
    end

    # The other half of the same rule: a GLOBAL component's module is hashed with "Global", so
    # rebinding it to the page's site named a module nobody built and the canvas showed the runtime's
    # red "failed to render" on every global component inserted from an example.
    test "inserting a GLOBAL component's example leaves it bound to Global", %{
      conn: conn,
      page: page
    } do
      create_component!(
        name: "kit-footer",
        extra: %{
          "examples" => [
            %{
              "label" => "Base",
              "base" => true,
              "source" => ~s(<.component component_name="kit-footer" site="Global" />)
            }
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "kit-footer")
      render_click(view, "insert_example", %{"index" => "0"})

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "kit-footer"))

      assert Node.attr(inserted, "site") == {:string, "Global"}
    end

    test "the inserted example survives a save", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")
      render_click(view, "insert_example", %{"index" => "0"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(variant="bordered")
      assert reloaded.template =~ ~s(site="localhost")
      assert reloaded.template =~ "Deal"
    end

    # The modal is a chooser, not a source dump: picking a variant only changes what the preview
    # renders, and nothing is inserted until Insert is pressed.
    test "picking a variant moves the preview without touching the document", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      show_examples!(view, "promo-card")
      assert has_element?(view, "#pb-example-preview-0-desktop")

      view |> element("#pb-example-1") |> render_click()
      assert has_element?(view, "#pb-example-preview-1-desktop")
      refute has_element?(view, "#pb-example-preview-0")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # A drawer under the preview, not a replacement for it: the source is the answer to a second
    # question, and closing the picture to read it makes comparing the two impossible.
    test "the Code drawer shows the source without hiding the preview", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "promo-card")

      # The drawer is a fold the browser opens, so both are in the document at once — which is the
      # point: reading the source must not close the picture.
      assert has_element?(view, "#pb-example-code-body")
      assert has_element?(view, "#pb-example-preview-0-desktop")
      assert render(view) =~ "variant=&quot;bordered&quot;"
    end

    test "the device toggle narrows the stage to a phone width", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "promo-card")

      view |> element("#pb-example-device-mobile") |> render_click()

      assert view |> element("#pb-example-preview-0-mobile") |> render() =~ "w-[320px]"
    end

    # The preview is drawn by the CANVAS in preview mode, in a document carrying the SITE's
    # stylesheet — the admin's CSS would draw a different component than the site draws, and a second
    # renderer would draw a different one than inserting produces.
    test "the preview route renders the chosen example with the site's own CSS", %{
      conn: conn,
      page: page
    } do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: "abc",
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, preview, body} = live(conn, example_path(token(view), "promo-card", 0))

      # The same stylesheet the editing canvas gets, by the same cacheable URL — carried as the
      # address here, because the `<link>` is the root layout's now. See the canvas tests.
      assert css_hrefs(preview) == ["/assets/css/__shared_base__/abc.css"]
      # The example's own subtree, resolved through the runtime the way the canvas resolves it.
      assert body =~ ~s(data-component="promo-card")
      # Preview mode: no drop tail, no element toolbar, no chrome stylesheet.
      refute body =~ "pb-canvas-tail"
      refute body =~ "pb-el-toolbar"

      # And not the page preview's bar: an example is not the author's page, and its way back would
      # toggle the editor's own preview from inside the modal.
      refute has_element?(preview, "#pb-preview-bar")
    end

    test "an unknown example says so rather than crashing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _preview, body} = live(conn, example_path(token(view), "promo-card", 99))

      assert body =~ "no longer available"
    end

    test "closing the modal leaves the document untouched", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      show_examples!(view, "promo-card")
      render_click(view, "close_examples", %{})

      refute render(view) =~ "pb-examples"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end
  end

  describe "drag and drop" do
    test "a drop carrying a node id is a move", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})

      tree = view |> editor() |> Map.fetch!(:tree)
      assert Tree.get(tree, h1.id).parent_id == nil
      assert hd(tree.roots) == h1.id
    end

    test "a drop carrying a template is an insert", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure")
    end

    test "the drop index is honoured", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "1"
      })

      tags =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.children(section.id)
        |> Enum.map(& &1.tag)

      assert Enum.at(tags, 1) == "figure"
    end

    # The client resolves geometry; it does not get to decide legality. A payload naming an illegal
    # parent is refused as a CHILD here even though no browser would have produced it — and lands
    # beside the target instead, which is the half of the contract the drag hint promises.
    test "a tampered drop is refused as a child and relocated beside the target", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      html =
        render_click(view, "drop", %{
          "template" => "<section></section>",
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "text and inline"
      assert html =~ "Placed after"

      tree = view |> editor() |> Map.fetch!(:tree)
      inserted = Enum.find(Tree.walk(tree), &(&1.tag == "section" and &1.children == []))

      assert inserted.parent_id == h1.parent_id
      refute inserted.parent_id == h1.id

      siblings = Tree.child_ids(tree, h1.parent_id || :root)

      assert Enum.find_index(siblings, &(&1 == inserted.id)) ==
               Enum.find_index(siblings, &(&1 == h1.id)) + 1
    end

    test "a drop with nowhere legal to land is refused outright", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      # Beside the h1 is still inside the section being moved, so the retry fails too.
      html =
        render_click(view, "drop", %{
          "node_id" => section.id,
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "inside itself"
      refute html =~ "Placed after"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "dropping a node into its own descendant is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")

      html =
        render_click(view, "drop", %{
          "node_id" => section.id,
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "inside itself"
      assert Tree.get(view |> editor() |> Map.fetch!(:tree), section.id).parent_id == nil
    end

    # WHAT THE RAIL OFFERS TO DROP INTO, AND HOW IT SAYS SO.
    #
    # This was a separate strip under every expanded COMPONENT — so every plain tag, the `<div>`,
    # `<main>` and `<footer>` a page is actually built out of, had no target in the tree at all, and
    # an empty `<div>` could not even be expanded to get one (`expandable?/1` is false for it on all
    # four counts). It was also permanent, standing on every expanded component whether or not
    # anything was being dragged.
    #
    # Revealing it per hover was the obvious repair and is the wrong shape: showing an in-flow box
    # only moves what is BELOW its own row, but hiding the previous one moves the row now UNDER the
    # pointer, and the strip was taller than a row. So the answer is written on the row, which
    # already has its size.
    test "a container row says so, on itself, only while it is the target", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: ~s(<main><p>Words</p></main><div></div>))
      {:ok, view, _html} = open_builder(conn, page)

      for tag <- ["main", "div"] do
        row = view |> element(~s([data-layer-row="#{node_with_tag(view, tag).id}"])) |> render()

        assert row =~ ~s(data-role="pb-drop-inside"), "#{tag} can be dropped into"
        assert row =~ "drop inside"
        assert row =~ "hidden", "and says nothing until a drag makes it the target"
        assert row =~ "group-data-[drop=inside]:flex"
      end
    end

    test "a row that cannot hold children never offers to", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>Words</p><img src="/a.png" />))
      {:ok, view, _html} = open_builder(conn, page)

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      for id <- [text.id, node_with_tag(view, "img").id] do
        row = view |> element(~s([data-layer-row="#{id}"])) |> render()

        refute row =~ ~s(data-role="pb-drop-inside")
        refute row =~ ~s(data-container="true")
      end
    end

    # The map of where this drag could land. `data-can` is written by the hook from the server's own
    # verdict; the row has to be able to DRAW it, and as an outline rather than a border or a tint
    # because both of those are already spoken for by the drop marker.
    test "a row can be drawn as somewhere this drag would go", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      row =
        view |> element(~s([data-layer-row="#{node_with_tag(view, "section").id}"])) |> render()

      assert row =~ "data-[can=true]:[outline:1px_dashed_#cfcdf0]"
      assert row =~ "data-[drop=inside]:bg-[#f2f1fc]"
      assert row =~ ~s(data-container="true")
    end

    # A SHUT BRANCH IS NOT IN THE DOCUMENT AT ALL, so a drag cannot reach into one — and
    # `default_expanded/1` opens the roots and one level below them and nothing else, so a tree of
    # any depth is mostly shut. A `<span>` inside a `<p>` inside a `<div>` had no row to aim at, and
    # the only way to reach it was to let go of what you were holding, click down to it, and pick it
    # up again. The hook springs a shut row open after a dwell; this is what tells it which rows are
    # worth waiting on.
    test "a row says whether it is shut over something", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section><div><p><span>Deep</span></p></div></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      # Open by default: `default_expanded/1` takes the roots and the branch children of the roots,
      # and stops. Two levels, however deep the document goes.
      for tag <- ["section", "div"] do
        assert view |> element(~s([data-layer-row="#{node_with_tag(view, tag).id}"])) |> render() =~
                 ~s(data-open="true")
      end

      # Shut, and worth waiting on — this is the row the drag has to open to get any further, and
      # the `<span>` under it is not in the document at all until it does.
      assert view |> element(~s([data-layer-row="#{node_with_tag(view, "p").id}"])) |> render() =~
               ~s(data-open="false")

      refute has_element?(view, ~s([data-layer-row="#{node_with_tag(view, "span").id}"]))
    end

    test "a row with nothing under it says nothing, so no drag waits on it", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: ~s(<section><hr /></section>))
      {:ok, view, _html} = open_builder(conn, page)

      row = view |> element(~s([data-layer-row="#{node_with_tag(view, "hr").id}"])) |> render()
      refute row =~ ~s(data-open=)
    end

    # The event the spring pushes is the chevron's own, which is what keeps one behaviour rather than
    # two: whatever a click opens, a dwell opens.
    test "the branch a drag opens is the branch a click opens", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section><div><p><span>Deep</span></p></div></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      paragraph = node_with_tag(view, "p")
      span = node_with_tag(view, "span")
      refute has_element?(view, ~s([data-layer-row="#{span.id}"]))

      render_click(view, "toggle_expand", %{"id" => paragraph.id})

      assert has_element?(view, ~s([data-layer-row="#{span.id}"]))

      assert view |> element(~s([data-layer-row="#{paragraph.id}"])) |> render() =~
               ~s(data-open="true")
    end

    # A COMPONENT'S OWN MARKUP IS NOT THE PAGE'S TREE.
    #
    # It was drawn loose, at the same indent as the page's own children and directly among them, with
    # nothing saying what it was — for a `chelekom-footer`, nine rows of somebody else's markup
    # between the component and the one line of content the page actually put in it. Rows that look
    # like children, are not, and accept nothing. It now sits behind a heading, like `.properties`
    # and `.slots`, and costs one row until it is asked for.
    test "a component's own markup is folded behind a heading of its own", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "deepish",
        template: ~s|<footer><div><span>a</span></div></footer>|,
        slots: []
      )

      page = create_page!(site_id: site.id, template: ~s|<.component component_name="deepish" />|)
      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)

      assert has_element?(view, "#pb-markup-#{node.id}")

      heading = view |> element("#pb-markup-#{node.id}") |> render()
      assert heading =~ ".markup"
      assert heading =~ "(4)", "footer, div, span and its text — the rows it will draw"

      refute render(view) =~ "read only", "nothing of it is drawn until the heading is opened"

      render_click(view, "toggle_expand", %{"id" => "markup:" <> node.id})

      html = render(view)
      assert html =~ "read only"
      assert html =~ "shared by every page using this component"
    end

    # Reading what is in there and going to edit it are different intents, so the heading carries the
    # fold and a separate arrow carries the trip — a link inside a button swallows the click, and a
    # heading that navigated away would take the fold with it.
    test "the markup heading is also the way to go and edit it", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "openable",
          template: ~s|<footer><div>a</div></footer>|,
          slots: []
        )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="openable" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)

      back =
        URI.encode_query(%{"return_to" => "/admin/dashboard/runtime/builder/page/#{page.id}"})

      assert has_element?(
               view,
               ~s(#pb-markup-open-#{node.id}[href="/admin/dashboard/runtime/builder/component/#{component.id}?#{back}"])
             )

      # The component's own row carries the same trip, and the same way back.
      assert has_element?(
               view,
               ~s(#pb-layer-open-#{node.id}[href="/admin/dashboard/runtime/builder/component/#{component.id}?#{back}"])
             )

      # And it is a sibling of the fold, not inside it: a link nested in a button never gets the click.
      assert view |> element("#pb-markup-#{node.id}") |> render() =~ "toggle_expand"
      refute view |> element("#pb-markup-#{node.id}") |> render() =~ "href="
    end

    # And it stays a window rather than becoming part of the document: no drag handle, no id a drop
    # could resolve to. Editing it here would rewrite the component under every other page silently.
    test "a component's own markup is not a drop target", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "windowed",
        template: ~s|<footer><div>a</div></footer>|,
        slots: []
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="windowed" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "markup:" <> node.id})

      rows = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.id)

      # Every addressable row in the rail is a node of the PAGE's tree. The markup contributes none.
      for id <- rail_row_ids(view) do
        assert id in rows, "#{id} is drawn as a drop target but is not in the document"
      end
    end

    # `Inspector.addable_slots/1` leaves out `inner_block` — that is not a slot anybody adds, it is
    # whatever you write between the tags — so a component declaring only `inner_block` counted zero
    # and was told "this component takes no slots". That is the opposite of true, and it is the
    # commonest shape in the kit: the rail marks such a component a container and a drop into it
    # lands. The line said the one thing that would stop an author trying.
    test "a component whose only slot is inner_block is not told it takes none", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "holds-anything",
        template: ~s|<div>{render_slot(@inner_block)}</div>|,
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}]
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="holds-anything">hi</.component>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      html = render(view)
      refute html =~ "this component takes no slots"
      assert html =~ "goes straight inside"

      # And the rail really does accept a drop into it, which is what makes the old line a lie.
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~
               ~s(data-container="true")
    end

    test "a component that takes nothing inside still says so", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "holds-nothing",
        template: ~s|<hr class="r" />|,
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="holds-nothing" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert render(view) =~ "takes nothing inside"
    end

    # `+ :source` USED TO BREAK THE PAGE.
    #
    # The button wrote `<:source></:source>` and nothing else, but a slot declares attributes of its
    # own and eleven of the kit's slots declare REQUIRED ones. The component reads them directly —
    # `chelekom-video` does `src={source.src}` — so a bare slot is not an empty slot, it is a missing
    # key: "chelekom-video could not render — key :src not found", the instant the button was
    # pressed. The one control whose whole job is "add the thing this component asks for" was the one
    # that stopped the page rendering.
    test "adding a slot writes the attributes that slot cannot render without", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "mediaish",
        template: ~s|<video><source :for={s <- @source} src={s.src} type={s.type} /></video>|,
        slots: [
          %{
            "name" => "source",
            "opts" => %{},
            "attrs" => [
              %{"name" => "src", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "type", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "label", "type" => "string", "opts" => %{}}
            ]
          }
        ]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="mediaish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      ghost = view |> element("#pb-slot-add-#{node.id}-source") |> render()
      assert ghost =~ ~s(src=)
      assert ghost =~ ~s(type=)
      refute ghost =~ ~s(label=), "optional attributes are what the Inspector is for"

      # And pressing it leaves a slot the component can actually render.
      view |> element("#pb-slot-add-#{node.id}-source") |> render_click()

      slot =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :slot))

      assert slot, "the slot was inserted"

      written = Enum.map(slot.attrs, fn {name, _value} -> name end)
      assert "src" in written
      assert "type" in written
    end

    # A slot with nothing required stays as bare as it always was — there is nothing to seed.
    test "a slot that requires nothing is still added bare", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "looseish",
        template: ~s|<div><div :for={a <- @extra}>{render_slot(a)}</div></div>|,
        slots: [%{"name" => "extra", "opts" => %{}, "attrs" => []}]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="looseish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert view |> element("#pb-slot-add-#{node.id}-extra") |> render() =~
               ~s(phx-value-template="&lt;:extra&gt;&lt;/:extra&gt;")
    end

    # The kit declares defaults for some of them, and a default beats an empty every time: it is the
    # value the component was designed around.
    test "a required attribute with a declared default is seeded with it", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "defaultish",
        template: ~s|<div><span :for={i <- @item}>{i.kind}</span></div>|,
        slots: [
          %{
            "name" => "item",
            "opts" => %{},
            "attrs" => [
              %{
                "name" => "kind",
                "type" => "string",
                "opts" => %{"required" => true, "default" => "info"}
              }
            ]
          }
        ]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="defaultish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert view |> element("#pb-slot-add-#{node.id}-item") |> render() =~ "info"
    end

    # A REQUIRED PROPERTY LEFT BLANK REFUSES THE PUBLISH BUTTON, and the rail never said so — the
    # first anyone heard was a flash naming a field several rows inside a component that may not even
    # be open. Read off the DECLARATION, so a kit nobody here has seen is marked the same way.
    test "the property row says which ones are compulsory", %{conn: conn, site: site} do
      needy(site.id)
      page = create_page!(site_id: site.id, template: ~s|<.component component_name="needful" />|)
      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "props:" <> node.id})

      required = view |> element("#pb-prop-row-#{node.id}-src") |> render()
      optional = view |> element("#pb-prop-row-#{node.id}-alt") |> render()

      assert required =~ "required"
      refute optional =~ "required"
    end

    # Loud while empty, quiet once filled: a satisfied requirement is worth knowing before you
    # clear it, and worth nothing louder than that.
    test "and stops shouting once it is filled", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="needful" src="/a.png" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "props:" <> node.id})

      row = view |> element("#pb-prop-row-#{node.id}-src") |> render()
      assert row =~ "required"
      refute row =~ "#c0473d", "filled, so it is not drawn as a problem"
    end

    # The number the badge shows is the SUBTREE's, which is the whole point: a shut component says
    # something inside it is unfinished without being opened.
    test "the row counts everything unfinished under it, shut or open", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<div><.component component_name="needful" /></div>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      wrapper = node_with_tag(view, "div")
      row = view |> element(~s([data-layer-row="#{wrapper.id}"])) |> render()

      assert row =~ "needed", "the div itself needs nothing; the component inside it does"
      assert row =~ "2 needed", "one blank required property and one missing required slot"
    end

    # A count on a shut row is a riddle without it, and the two cases need different words: a row
    # whose own properties are fine and whose CHILD is unfinished must not claim the problem is here.
    test "the badge says what is behind its number, in the right number", %{
      conn: conn,
      site: site
    } do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<div><.component component_name="needful" src="/a.png" /></div>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      component = needful_node(view)
      wrapper = node_with_tag(view, "div")

      # Its own: one required slot, never added.
      assert view |> element(~s([data-layer-row="#{component.id}"])) |> render() =~
               "1 slot required here is still empty"

      # The wrapper's: nothing of its own, one thing underneath.
      assert view |> element(~s([data-layer-row="#{wrapper.id}"])) |> render() =~
               "1 required thing inside this is still empty"
    end

    test "and says nothing at all once everything is filled", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<.component component_name="needful" src="/a.png"><:caption>hi</:caption></.component>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      refute view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "needed"
    end

    # THE BADGE AND THE BUTTON READ THE SAME ANSWER. Two implementations of one rule drift, and a
    # badge that disagrees with the refusal beside it is worse than no badge.
    test "the badge counts exactly what publishing refuses", %{conn: conn, site: site} do
      needy(site.id)
      page = create_page!(site_id: site.id, template: ~s|<.component component_name="needful" />|)
      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "2 needed"

      html = render_click(view, "publish", %{})
      assert html =~ "needful.src"
      assert html =~ "needful.:caption"
    end

    # A kit this editor has never seen declares its requirements the same way, so nothing here is
    # keyed to a component name or an attribute name.
    test "a component nobody has heard of is marked the same way", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "zzz-unknown-widget",
        template: ~s|<div data-x={@mandatory}></div>|,
        attrs: [%{"name" => "mandatory", "type" => "string", "opts" => %{"required" => true}}],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="zzz-unknown-widget" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "1 needed"
    end

    # THE END OF THE PAGE, which no row can stand for. A document with one root had exactly one place
    # to aim at in the rail and an EMPTY one had none at all — so the tray's whole gesture, dragging
    # a card into a page with nothing in it yet, could only be done on the canvas. It is the last
    # element in the rail, which is why it is allowed to appear and disappear when nothing else is.
    test "the rail offers the end of the page as a target", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s([data-role='pb-root-drop'][data-parent-id='root']))

      tail = view |> element(~s([data-role='pb-root-drop'])) |> render()
      assert tail =~ "drop at the end of the page"
      assert tail =~ "data-[show=true]:flex"
      refute tail =~ ~s(data-show=)
    end

    # The same payload the rail's tail sends, taken at its word by the server: a template with no
    # `node_id` is an insert, and an index past the end appends.
    test "a template dropped at the end of the page becomes a new root", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      roots = length(view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots))

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => "root",
        "index" => "9999"
      })

      tree = view |> editor() |> Map.fetch!(:tree)
      assert length(tree.roots) == roots + 1
      assert Tree.get(tree, List.last(tree.roots)).tag == "figure"
    end

    test "a move is undoable like any other edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})
      undo!(view)

      assert Tree.get(view |> editor() |> Map.fetch!(:tree), h1.id).parent_id != nil
    end

    # 183 components carrying their templates, attrs, slots and examples is 3.4 MB and 1.6 seconds.
    # Reading it during mount meant the editor drew nothing until it landed; it now arrives after,
    # and the panel says so rather than claiming there are no components.
    test "the palette loads after mount, showing a skeleton until it lands", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "late-arrival")

      {:ok, view, html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      # Before the async read returns: a skeleton, and NOT the "no components" answer — an empty
      # palette and one that has not arrived are different things to say.
      assert html =~ "pb-palette-skeleton"
      refute html =~ "No components match."

      loaded = render_async(view)

      refute loaded =~ "pb-palette-skeleton"
      assert loaded =~ "pb-comp-late-arrival"
      # It lands on the SESSION too, because the canvas binds components to a site from that list.
      assert view |> editor() |> Map.fetch!(:components) != []
    end

    test "palette cards advertise the same template click-to-place inserts", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "drag-me")
      {:ok, view, html} = open_builder(conn, page)

      assert html =~ ~s(data-template="&lt;.component component_name=&quot;drag-me&quot;)
      assert has_element?(view, "#pb-comp-drag-me[draggable]")
    end

    # The hint is what the drag paints its line from. It is asked for ONCE, at dragstart, and it has
    # to agree with the check that later admits the drop — which is why both come from the same
    # function. A hint that says yes where the drop says no is the bug this guards.
    test "dragstart answers with the whole tree's verdict for the thing being dragged", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      section = node_with_tag(view, "section")

      render_click(view, "drag_start", %{"template" => "<section></section>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: accepts})

      assert accepts[section.id] == true
      assert accepts[h1.id] == false
      assert map_size(accepts) == view |> editor() |> Map.fetch!(:tree) |> Tree.size()
    end

    # The hint is only worth having if the drop keeps its promise, so this asserts the promise on both
    # sides: where it says yes the node lands inside, where it says no the node lands beside instead.
    test "the drop keeps the promise the hint made", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "drag_start", %{"template" => "<figure></figure>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: accepts})

      tree = view |> editor() |> Map.fetch!(:tree)
      {yes, true} = Enum.find(accepts, fn {_id, allowed?} -> allowed? end)

      # A refused node whose PARENT accepts — so "beside it" is a place the retry can actually land.
      refused =
        Enum.find_value(accepts, fn
          {id, false} ->
            with %{} = node <- Tree.get(tree, id), true <- accepts[node.parent_id], do: node

          {_id, true} ->
            nil
        end)

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => yes,
        "index" => "0"
      })

      assert node_with_tag(view, "figure").parent_id == yes

      render_click(view, "drop", %{
        "template" => "<aside></aside>",
        "parent_id" => refused.id,
        "index" => "0"
      })

      assert node_with_tag(view, "aside").parent_id == refused.parent_id
    end

    test "a locked node accepts nothing, and a locked node being dragged is offered nowhere", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")

      {:ok, _locked} = EditorSession.toggle_lock(token(view), section.id)

      render_click(view, "drag_start", %{"template" => "<figure></figure>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: locked_target})
      assert locked_target[section.id] == false

      render_click(view, "drag_start", %{"node_id" => section.id})
      assert_push_event(view, "pb:drop-hints", %{accepts: locked_source})
      assert Enum.all?(locked_source, fn {_id, allowed?} -> allowed? == false end)
      assert locked_source[h1.id] == false
    end

    # SELECTING FIRST IS ALREADY SAYING WHERE. Picking with something selected used to arm the palette
    # and wait for a click on the element the reader had just clicked; it places into it instead.
    test "picking with an element selected places into it at once", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "straight-in")
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => "straight-in"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "straight-in"))

      assert placed, "one click on the palette should have been enough"
      assert placed.parent_id == section.id
      assert placed.id == List.last(Tree.get(editor(view).tree, section.id).children)

      # And nothing is left armed, so the next click on a row selects.
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # A BAND IS A SLICE OF THE PAGE, so it goes beside the other slices rather than into whatever was
    # selected. Every block in the library is one, which is why the whole library follows this rule
    # and a kit component, one test above, does not.
    test "picking a block with a section selected places it after that section", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      before = Tree.get(editor(view).tree, section.id).children
      block = hd(MishkaCmsCore.Runtime.PageBuilder.Blocks.all())
      render_click(view, "pick_block", %{"block" => block.id})

      tree = editor(view).tree
      assert Tree.get(tree, section.id).children == before, "the section was not opened up"

      placed = Tree.get(tree, List.last(tree.roots))
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # AND A BLOCK AN EXTENSION BROUGHT IS ONE OF THEM. The palette draws the merged library while the
    # click was resolved in the core one, so a contributed card answered "that element is no longer
    # on the page" — and dragging the identical card worked, which is what made it look like a
    # palette bug rather than a lookup that never asked the registry.
    test "and a block an extension contributed lands the same way", %{conn: conn, page: page} do
      register_plugin(BlockPlugin, "builder:blocks")

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick_block", %{"block" => BlockPlugin.block().id})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert Serializer.serialize(tree) =~ "They loved it.", "the plugin's own template"
    end

    # AN ELEMENT RIDES THE SAME ROUTE AS A BLOCK — one armed slot, two libraries — so a `<section>`
    # arrives by exactly the mechanism a finished Hero does, and lands by the same rule.
    test "picking a structural element places an empty container beside it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-section"})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert placed.tag == "section"
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert placed.children == [], "a layout element is a hole to put things in"
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # THE REPORTED BUG. A call to action clicked while the page header was selected became a third
    # item in the header's flex row and rendered a quarter of the width.
    test "a band clicked into a header lands beside the header, not in it", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<header class="flex"><a href="/">Logo</a><nav></nav></header><main></main>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      header = node_with_tag(view, "header")
      before = Tree.get(editor(view).tree, header.id).children

      render_click(view, "select", %{"id" => header.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      tree = editor(view).tree
      assert Tree.get(tree, header.id).children == before, "the header was left alone"

      placed = Tree.get(tree, Enum.at(tree.roots, 1))
      assert placed.tag == "section"
      assert placed.parent_id == nil
    end

    # CLIMBING MORE THAN ONE LEVEL. Clicking the heading inside a hero has to pop the band out of the
    # heading AND out of the hero — and that landing place is one the selection ring does not explain
    # on its own, so it is the one case that says where it went.
    test "a band clicked deep inside a section climbs out of the whole branch", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      html = render_click(view, "pick_block", %{"block" => "cta-band"})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert placed.tag == "section"
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert html =~ "Sections sit beside each other"
    end

    # THE CLIMB STOPS AT A WRAPPER THAT ALREADY HOLDS BANDS. A page wrapped in one div is an ordinary
    # shape, and lifting every new section out of it would put them somewhere the page does not live.
    test "a band is not lifted out of a wrapper that already holds bands", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="app"><section id="a"><p>One</p></section><section id="b"></section></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      wrapper = node_with_tag(view, "div")
      p = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => p.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      placed =
        editor(view).tree
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "section" and Node.attr(&1, "id") == nil))

      assert placed.parent_id == wrapper.id
    end

    # AN EMPTY BOX IS A HOLE TO PUT THINGS IN. It is the one container that cannot squeeze the band
    # into a narrow column, because there is nothing beside it — and it is the escape hatch that
    # keeps "make a section, then fill it" working.
    test "a band clicked into an empty section goes inside it", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section class="py-16"></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      assert Tree.get(editor(view).tree, section.id).children != []
    end

    # `<main>` is a band host by vocabulary, so a band clicked into one goes in rather than beside.
    test "a band clicked into main goes inside it", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<main><p>One</p></main>))

      {:ok, view, _html} = open_builder(conn, page)
      main = node_with_tag(view, "main")

      render_click(view, "select", %{"id" => main.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      assert Tree.get(editor(view).tree, main.id).children |> length() == 2
    end

    # WHAT MUST NOT CHANGE. Only a band climbs. A paragraph, a heading or a kit component clicked
    # while a section is selected still goes straight inside it — the gesture this editor is built on.
    test "a leaf clicked into a section still goes inside it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-paragraph"})

      children = Tree.get(editor(view).tree, section.id).children
      assert Tree.get(editor(view).tree, List.last(children)).tag == "p"
    end

    # `header` AND `footer` ARE NOT BANDS BY TAG. The spec puts them inside `<article>` and
    # `<section>` as readily as at page level, and treating them as page slices made "give this
    # section its own header" impossible to do by clicking.
    test "a bare header element goes inside the section that was selected", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<section id="s"><p>One</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-header"})

      children = Tree.get(editor(view).tree, section.id).children
      assert Tree.get(editor(view).tree, List.last(children)).tag == "header"
    end

    # WHAT MAKES THE PAGE FOOTER DIFFERENT IS THE LIBRARY. `footer-columns` is rooted in a `<footer>`
    # exactly like the element above, and it still climbs — every entry in Blocks is a slice of the
    # page by construction.
    test "the footer block still lands beside, not inside", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section id="s"><p>One</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      before = Tree.get(editor(view).tree, section.id).children
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "footer-columns"})

      tree = editor(view).tree
      assert Tree.get(tree, section.id).children == before
      assert Tree.get(tree, List.last(tree.roots)).tag == "footer"
    end

    # THE RULE IS A CLICK-PATH POLICY. A drag names its parent with the pointer, and a deliberate one
    # must still be obeyed — every builder in the field keeps these two answers separate.
    test "a dragged band still lands exactly where it was dropped", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<header class="flex"><a>Logo</a></header>))

      {:ok, view, _html} = open_builder(conn, page)
      header = node_with_tag(view, "header")

      render_click(view, "drop", %{
        "template" => "<section></section>",
        "parent_id" => header.id,
        "index" => "0"
      })

      placed = Tree.get(editor(view).tree, hd(Tree.get(editor(view).tree, header.id).children))
      assert placed.tag == "section", "a pointer knows better than a policy"
    end

    test "the Blocks panel lists the elements alongside the sections", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      assert has_element?(view, "#pb-el-el-section")
      assert has_element?(view, "#pb-el-el-columns-3")
      assert has_element?(view, "#pb-el-el-h2")
      assert has_element?(view, "#pb-block-hero-centred"), "the sections are still there"
    end

    # The categories filter one library or the other, never a mix of both — choosing Layout should
    # not leave eight finished marketing sections underneath it.
    test "an element category hides the sections", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      render_click(view, "block_cat", %{"cat" => "Layout"})

      assert has_element?(view, "#pb-el-el-section")
      refute has_element?(view, "#pb-block-hero-centred")
      refute has_element?(view, "#pb-el-el-h2"), "H2 is Text, not Layout"
    end

    # WITH NOTHING SELECTED IT STILL ARMS, because there is no answer yet — the canvas and the tree
    # are both waiting to give one.
    test "picking with no selection arms the palette instead", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "waits-for-a-click")
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "pick", %{"name" => "waits-for-a-click"})

      assert view |> editor() |> Map.fetch!(:picked) == "waits-for-a-click"

      refute view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.walk()
             |> Enum.find(&(Node.component_name(&1) == "waits-for-a-click"))
    end

    # Click-to-place accepts a click on the TREE as well as on the canvas, and lands in the row that
    # was clicked — inside it when it can hold the component, immediately after it when it cannot.
    test "a picked component is placed by clicking a layer row", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "place-me")
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "pick", %{"name" => "place-me"})
      render_click(view, "select", %{"id" => section.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "place-me"))

      assert placed.parent_id == section.id

      # The pick is spent, so the next click on a row selects again rather than placing a second one.
      assert view |> editor() |> Map.fetch!(:picked) == nil

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      assert view |> editor() |> Map.fetch!(:selection) == h1.id
    end

    # A component row pushes `inspect` rather than `select`, so placing had to be taught there too —
    # otherwise the tree could place into a `<div>` but not into the component you meant.
    test "a picked component is placed by clicking a component row", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-shell",
        slots: [%{"name" => "inner_block", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      create_component!(site_id: nil, name: "goes-inside")

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-shell" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      shell =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick", %{"name" => "goes-inside"})
      render_click(view, "inspect", %{"id" => shell.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "goes-inside"))

      assert placed.parent_id == shell.id

      # With nothing picked the same click still opens the Inspector on that component.
      render_click(view, "inspect", %{"id" => shell.id})
      assert view |> editor() |> Map.fetch!(:selection) == shell.id
      assert has_element?(view, "#pb-lefttab-inspector")
    end

    # A component that declares `id` as required raises the moment it renders without one. Generating
    # it where such nodes are created means that never has to be handled later — and it is written
    # into the template as an ordinary attribute, so it can be renamed. A node that declares no `id`
    # is left alone, plain HTML included: minting one for every `<figure>` would rewrite a document
    # nobody edited.
    test "a node that declares an id is given one", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: nil,
        name: "needs-id",
        attrs: [%{"name" => "id", "type" => "string", "opts" => %{"required" => true}}],
        template: "<div id={@id}>x</div>"
      )

      create_component!(site_id: site.id, name: "no-id-attr")
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert is_nil(Node.attr(node_with_tag(view, "figure"), "id"))

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="needs-id" site="Global"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      declared = component_node(view, "needs-id")
      assert Node.attr_text(declared, "id") =~ ~r/\S/

      # A component that never declared `id` is not given one — an undeclared assign is noise.
      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="no-id-attr" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert is_nil(Node.attr(component_node(view, "no-id-attr"), "id"))

      # An empty one is no id either — a snippet shipping `id=""` is as broken as one shipping none,
      # so a DECLARING node fills it. This `<article>` declares nothing, and keeps what it was given.
      render_click(view, "drop", %{
        "template" => ~s(<article id=""></article>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert Node.attr_text(node_with_tag(view, "article"), "id") == ""

      # An expression is a VALUE — the author bound the id to their data, and it is left alone.
      render_click(view, "drop", %{
        "template" => ~s(<aside id={@row.id}></aside>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert {:expr, expr} = Node.attr(node_with_tag(view, "aside"), "id")
      assert expr =~ "@row.id"
    end

    # A raise inside the canvas takes the LiveView with it, and the reload costs the author every
    # unsaved edit. A required attribute that is empty is knowable before rendering, so it is checked
    # rather than caught — no `try` on a path that runs for every component on every diff.
    test "a component missing a required attribute renders a placeholder, not a crash", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "strict-card",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{"required" => true}}],
        template: "<div>{@title}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="strict-card" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-incomplete="true"]))
      assert html =~ "strict-card"
      assert html =~ "needs title"

      # And it is still a node: selectable, so the missing field can be filled in the inspector.
      card = component_node(view, "strict-card")
      assert has_element?(canvas, ~s([data-node-id="#{card.id}"]))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => card.id,
        "name" => "title",
        "value" => "filled in"
      })

      refute has_element?(canvas, ~s([data-incomplete="true"]))
    end

    # THE OTHER HALF, AND THE HARDER ONE. A missing required attribute is knowable before rendering,
    # so it gets a check. Everything else a component might do — a bad value shape, an atom that does
    # not exist, an outright `raise` — is not, and it used to take the canvas LiveView with it:
    # crash, reload, and every unsaved edit in the session gone.
    #
    # It has to be a REAL compiled component. A database row whose module was never built takes the
    # runtime's "failed to render" branch and never runs at all, which is a different case and was
    # already handled — that is why this uses `MishkaCmsCore.Test.RaisingComponent`, whose one
    # attribute is declared, defaulted, and perfectly fine until it is given a value that names no
    # atom.
    test "a component that raises leaves the canvas standing", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root">) <>
              ~s(<MishkaCmsCore.Test.RaisingComponent.boom tone="nope-not-an-atom" />) <>
              ~s(<p>after</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-render-error="true"]))
      assert html =~ "could not render"

      # THE PAGE AROUND IT IS UNHARMED, which is the whole point — one bad component costs its own
      # box and nothing else.
      assert html =~ "after"
      assert Process.alive?(canvas.pid)

      # And it is still a node: selectable, so it can be inspected and deleted.
      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert has_element?(canvas, ~s([data-node-id="#{node.id}"]))

      render_click(view, "op", %{"kind" => "delete", "node_id" => node.id})

      assert Process.alive?(canvas.pid)
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # THE BOUND `contain/2` CANNOT GIVE. It covers every way a render can LEAVE; it cannot cover one
    # that does not leave, and a render allocating without limit takes the whole node rather than one
    # iframe. A heap ceiling is the only bound available without a second process, and a second
    # process is not available here — the sandbox does not cross one.
    test "the canvas runs under a heap ceiling, so a runaway render cannot take the node", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      {:max_heap_size, limit} = Process.info(canvas.pid, :max_heap_size)

      assert limit.size > 0, "an unbounded canvas is one component away from an unbounded node"
      assert limit.kill, "a ceiling that only logs is not a ceiling"

      # And it is nowhere near what an honest canvas uses, or it would be a new way to lose work.
      {:total_heap_size, used} = Process.info(canvas.pid, :total_heap_size)
      assert used < div(limit.size, 10)
    end

    # A `rescue` catches an exception and NOTHING ELSE. A component that throws, or that calls a
    # GenServer which is not running — an `exit`, and the likeliest of the three in a component that
    # talks to anything — went straight past the guard above and killed the canvas, which is the very
    # outcome that guard exists to prevent.
    for {function, leaving} <- [{"tossed", "throws"}, {"departed", "exits"}] do
      test "a component that #{leaving} leaves the canvas standing too", %{
        conn: conn,
        site: site
      } do
        page =
          create_page!(
            site_id: site.id,
            template:
              ~s(<div id="root">) <>
                ~s(<MishkaCmsCore.Test.RaisingComponent.#{unquote(function)} />) <>
                ~s(<p>after</p></div>)
          )

        {:ok, view, _html} = open_builder(conn, page)
        {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

        assert has_element?(canvas, ~s([data-render-error="true"]))
        assert html =~ "after", "the page around it is unharmed"
        assert Process.alive?(canvas.pid)
        assert Process.alive?(view.pid)
      end
    end

    test "layer rows are addressable as sortable items", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      assert has_element?(view, "#pb-layers[phx-hook='PbLayers']")
      assert has_element?(view, "[data-layer-id='#{section.id}']")
    end
  end

  # A COMPONENT'S INTERFACE, IN THE BUILDER. `attrs` and `slots` are columns on the component and
  # they drive nearly everything the page builder does with it — the Inspector's controls,
  # `.properties`, `.slots`, the required badges, the drop rules — and the builder could not edit
  # them at all. The only way in was the Components table form, where a slot's options are raw JSON.
  describe "the Interface tab" do
    defp open_component(conn, component) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      render_click(view, "open_source", %{})
      {:ok, view}
    end

    defp declarable(site) do
      create_component!(
        site_id: site,
        name: "declarable",
        template: ~s|<div class={@size}>{render_slot(@inner_block)}{@title}</div>|,
        attrs: [],
        slots: []
      )
    end

    test "is offered for a component and for nothing else", %{conn: conn, site: site, page: page} do
      {:ok, view} = open_component(conn, declarable(site.id))
      assert has_element?(view, "#pb-sourcetab-interface")

      {:ok, pages, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
      _loaded = render_async(pages)
      render_click(pages, "open_source", %{})

      refute has_element?(pages, "#pb-sourcetab-interface"),
             "a page takes no attributes and has no slots"
    end

    # A window headed "Page code" while it edits a component is lying about what it changes.
    test "and the window says which record it is editing", %{conn: conn, site: site, page: page} do
      {:ok, view} = open_component(conn, declarable(site.id))
      assert render(view) =~ "Component code"

      {:ok, pages, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
      _loaded = render_async(pages)
      render_click(pages, "open_source", %{})
      assert render(pages) =~ "Page code"
    end

    # THE CHECK THAT MATTERS MOST. A template reading `@size` with no `attr :size` compiles and then
    # raises `KeyError` the first time the component renders on somebody's page.
    test "names what the template reads and the component never declares", %{
      conn: conn,
      site: site
    } do
      {:ok, view} = open_component(conn, declarable(site.id))
      render_click(view, "source_tab", %{"tab" => "interface"})

      html = render(view)
      assert html =~ "does not declare them"
      assert has_element?(view, "#pb-interface-declare-attr-size")
      assert has_element?(view, "#pb-interface-declare-attr-title")
      assert has_element?(view, "#pb-interface-declare-slot-inner_block")
    end

    test "and declaring one writes it to the component", %{conn: conn, site: site} do
      component = declarable(site.id)
      {:ok, view} = open_component(conn, component)
      render_click(view, "source_tab", %{"tab" => "interface"})

      render_click(view, "declare_missing", %{"kind" => "attr", "name" => "size"})

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)
      assert Enum.any?(Interface.attrs(stored), &(&1["name"] == "size"))

      # And it stops being reported, because it is no longer missing.
      refute has_element?(view, "#pb-interface-declare-attr-size")
    end

    test "a slot is declared the same way", %{conn: conn, site: site} do
      component = declarable(site.id)
      {:ok, view} = open_component(conn, component)
      render_click(view, "source_tab", %{"tab" => "interface"})

      render_click(view, "declare_missing", %{"kind" => "slot", "name" => "inner_block"})

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)
      assert Enum.any?(Interface.slots(stored), &(&1["name"] == "inner_block"))
    end

    # THE FORM IS THE RESOURCE'S OWN. The first version of this tab was hand-rolled inputs beside a
    # `field :attrs, :nested` the resource had declared all along — two editors for one pair of
    # columns. This is the sixth `MishkaGervaz.Form.Web.Live` mount in the builder.
    test "the rows are the resource's own form, not a second one", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, declarable(site.id))
      render_click(view, "source_tab", %{"tab" => "interface"})

      # Gervaz names its own wrapper from the id it is mounted with.
      assert has_element?(view, "#pb-interface-form-form-wrapper")
      refute has_element?(view, ~s([name^="attr["])), "no hand-rolled rows"
    end

    # Every field but the two, asked of the form rather than listed — so a field added to the
    # resource tomorrow is hidden here without anyone remembering to come back.
    test "and it draws the interface columns and nothing else", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, declarable(site.id))
      render_click(view, "source_tab", %{"tab" => "interface"})

      hidden = Panels.interface_hidden_fields(MishkaCmsCore.Runtime.Component)

      refute :attrs in hidden
      refute :slots in hidden
      assert :name in hidden, "the component's own name belongs to the header, not here"
      assert :template in hidden, "the markup is what the canvas is for"
    end

    # The whole point of writing it here: the page builder reads it immediately.
    test "what is declared here is what a page then offers", %{conn: conn, site: site} do
      component = declarable(site.id)

      {:ok, _updated} =
        component
        |> Ash.Changeset.for_update(
          :update,
          %{attrs: [%{"name" => "size", "type" => "string", "opts" => %{"required" => true}}]},
          authorize?: false
        )
        |> Ash.update()

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="declarable" />|
        )

      {:ok, builder, _html} = open_builder(conn, page)
      node = needful_node(builder)

      assert builder |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "1 needed",
             "the required property it was just given"
    end

    # THE SAME SAVE AS THE COMPONENTS TABLE'S, and it lost the same things. The tab draws Required,
    # Default and Doc for an attribute, Required and Doc for a slot, and a flat row for each of a
    # slot's attributes, whose `required` and `doc` the record keeps under `opts`. Writing one doc
    # wrote back only what those controls held.
    test "a save keeps every option the form does not show", %{conn: conn, site: site} do
      slots = [
        %{
          "name" => "item",
          "opts" => %{"required" => false, "validate_attrs" => false, "doc" => "One entry"},
          "attrs" => [
            %{
              "name" => "title",
              "type" => "string",
              "opts" => %{"required" => true, "doc" => "Title of the entry"}
            },
            %{"name" => "kind", "type" => "string", "opts" => %{"values" => ["a", "b"]}}
          ]
        }
      ]

      component =
        create_component!(
          site_id: site.id,
          name: "shapes",
          template: every_option_template(),
          attrs: every_option_shape(),
          slots: slots
        )

      {:ok, view} = open_component(conn, component)
      render_click(view, "source_tab", %{"tab" => "interface"})
      render_async(view)

      view
      |> form("#pb-interface-form-form", %{
        "form" => %{"attrs" => %{"1" => %{"opts" => %{"doc" => "How big"}}}}
      })
      |> render_submit()

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)

      expected =
        Enum.map(every_option_shape(), fn
          %{"name" => "size"} = row -> put_in(row, ["opts", "doc"], "How big")
          row -> row
        end)

      assert Map.new(Interface.attrs(stored), &{&1["name"], &1["opts"]}) ==
               Map.new(expected, &{&1["name"], &1["opts"]})

      assert MishkaCmsCore.Runtime.Helpers.stringify_keys(stored.slots) == slots
    end
  end

  # THE SAME DECLARATION, AS THE FIRST ROW OF THE TREE. The Interface tab is where it is edited; the
  # rail is where it is SEEN, beside the markup that reads it. Before this the rail opened on a
  # component's elements with no mention of what the component takes — the one thing everything
  # below it depends on was the one thing with no row.
  describe "the .interface group in the layers rail" do
    defp declared_component(site) do
      create_component!(
        site_id: site,
        name: "declared",
        template: ~s|<div class={@size}>{render_slot(@inner_block)}</div>|,
        attrs: [%{"name" => "size", "type" => "string", "opts" => %{"required" => true}}],
        slots: [%{"name" => "inner_block"}, %{"name" => "actions"}]
      )
    end

    defp open_component_rail(conn, component) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      {:ok, view}
    end

    test "is drawn for a component, counting what it declares", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      assert has_element?(view, "#pb-interface-group")

      assert view |> element("#pb-interface-group") |> render() =~ "(3)",
             "one attribute and two slots"
    end

    # FIRST, which is what it was asked to be: a component's declaration comes before its markup the
    # way it does in the source, and reading the rail top to bottom should read the same way.
    test "before every element in the tree", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      html = render(view)
      group = :binary.match(html, "pb-interface-group") |> elem(0)
      first_row = :binary.match(html, "data-layer-row=") |> elem(0)

      assert group < first_row, "the group has to come before the first element row"
    end

    # A page takes no attributes and has no slots, so there is nothing here for it to be a view of.
    test "and nowhere else", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-interface-group")
    end

    # Folded until asked for, like `.properties` and `.markup` — it costs one row until then.
    test "folded, and opening it names what is declared", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      refute has_element?(view, "#pb-interface-attr-size")

      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      assert has_element?(view, "#pb-interface-attr-size")
      assert has_element?(view, "#pb-interface-slot-inner_block")
      assert has_element?(view, "#pb-interface-slot-actions")
    end

    # NAMED THE WAY THE MARKUP NAMES IT. `@size` and `<:actions>` are what somebody would type; the
    # column's spelling is this editor's business and not the reader's.
    test "written the way the markup writes them", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))
      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      rail = view |> element("#pb-interface-group") |> render()
      assert rail =~ ".interface"

      html = render(view)
      assert html =~ "@size"
      assert html =~ "&lt;:actions&gt;"
      assert html =~ "inner content", "the unnamed slot is written as what it holds"
    end

    test "marking the ones the component cannot do without", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))
      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      assert view |> element("#pb-interface-attr-size") |> render() =~ "required"
      refute view |> element("#pb-interface-slot-actions") |> render() =~ "required"
    end

    # A VIEW, NOT A SECOND EDITOR. Every row is a way into the form that owns these columns, and the
    # window opens on THAT tab rather than wherever it was last left.
    test "and every row opens the Interface tab", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))
      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      view |> element("#pb-interface-attr-size") |> render_click()

      assert has_element?(view, "#pb-interface-form-form-wrapper"),
             "the Interface tab, not the Template one"
    end

    test "as does the pencil on the group itself", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      view |> element("#pb-interface-edit") |> render_click()

      assert has_element?(view, "#pb-interface-form-form-wrapper")
    end

    # Silence reads as "not loaded". A component that declares nothing says so.
    test "a component with nothing declared says so rather than showing an empty fold", %{
      conn: conn,
      site: site
    } do
      bare =
        create_component!(
          site_id: site.id,
          name: "bare-declaration",
          template: ~s|<div>hello</div>|,
          attrs: [],
          slots: []
        )

      {:ok, view} = open_component_rail(conn, bare)
      assert view |> element("#pb-interface-group") |> render() =~ "(0)"

      render_click(view, "toggle_expand", %{"id" => "iface:root"})
      assert render(view) =~ "nothing declared yet"
    end
  end

  # A COMPONENT MADE OUT OF OTHER COMPONENTS, which is what most of the kit is. Three things about
  # the inner node were wrong, and the first of them destroyed data.
  describe "a component that nests another" do
    defp nesting(site) do
      create_component!(
        site_id: site,
        name: "inner-one",
        template: ~s|<span class={@tone}>x</span>|,
        attrs: [%{"name" => "tone", "type" => "string"}],
        slots: []
      )

      create_component!(
        site_id: site,
        name: "outer-one",
        template:
          ~s|<div><.component component_name="inner-one" site="Global" tone={@mood} /></div>|,
        attrs: [%{"name" => "mood", "type" => "string"}],
        slots: []
      )
    end

    defp inner_node(view) do
      Enum.find(
        Tree.walk(editor(view).tree),
        &(&1.kind == :component and
            MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "inner-one")
      )
    end

    defp open_component_builder(conn, component) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      {:ok, view}
    end

    # An attribute the outer component passes DOWN is an expression, and editing it through any
    # ordinary control posted the source back with no kind — so `tone={@mood}` became
    # `tone="@mood"`, a literal that looks identical in the panel and is bound to nothing.
    test "editing an inherited attribute keeps it bound", %{conn: conn, site: site} do
      outer = nesting(site.id)
      {:ok, view} = open_component_builder(conn, outer)
      node = inner_node(view)

      assert node, "the fixture has to nest the inner component"
      assert Node.attr(node, "tone") == {:expr, "@mood"}

      render_change(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node.id,
        "name" => "tone",
        "value" => "@mood_two"
      })

      assert Node.attr(inner_node(view), "tone") == {:expr, "@mood_two"}
      assert {:ok, heex} = Serializer.to_heex(editor(view).tree)
      assert heex =~ "tone={@mood_two}"
      refute heex =~ ~s(tone="@mood_two")
    end

    # And the panel says which boxes are bound, because `name={@icon}` and `name="hero-bolt"` drew
    # the same box — with a way to stop it being one on purpose.
    test "and says so, with a way out", %{conn: conn, site: site} do
      outer = nesting(site.id)
      {:ok, view} = open_component_builder(conn, outer)
      node = inner_node(view)

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      assert has_element?(view, "#pb-attr-literal-#{node.id}-tone")

      view |> element("#pb-attr-literal-#{node.id}-tone") |> render_click()

      assert Node.attr(inner_node(view), "tone") == {:string, "@mood"}
    end

    # A component that renders ITSELF is kept out of its own palette, so it could never be dropped
    # into itself — and the palette is also where the inspector looks for declarations, so its own
    # inner node drew a panel with no properties at all.
    test "a component that renders itself still knows what it declares", %{conn: conn, site: site} do
      recursive =
        create_component!(
          site_id: site.id,
          name: "recursive-one",
          template:
            ~s|<ul><.component component_name="recursive-one" site="Global" depth={@depth} /></ul>|,
          attrs: [%{"name" => "depth", "type" => "integer"}],
          slots: []
        )

      {:ok, view} = open_component_builder(conn, recursive)

      node =
        Enum.find(
          Tree.walk(editor(view).tree),
          &(&1.kind == :component and
              MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "recursive-one")
        )

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      assert has_element?(view, "#pb-attr-#{node.id}-depth"),
             "the declaration is on the record in hand"

      refute has_element?(view, "#pb-insp-edit-component"),
             "the Inspector offered to open the editor the author is already in"

      # And it is still kept out of the palette, which is what stops it being dropped into itself.
      refute has_element?(view, "#pb-comp-recursive-one"),
             "the recursion guard is the palette, and it still holds"
    end

    # THE RAIL HAS TO AGREE WITH THE PANEL. It counts what a node still needs from the same palette
    # the inspector reads, so a required property on a self-rendered component was never counted:
    # the panel said "required, empty" and the row beside it said nothing at all.
    test "and the rail counts what one of these still needs", %{conn: conn, site: site} do
      recursive =
        create_component!(
          site_id: site.id,
          name: "needful-self",
          template: ~s|<ul><.component component_name="needful-self" site="Global" /></ul>|,
          attrs: [%{"name" => "depth", "type" => "integer", "opts" => %{"required" => true}}],
          slots: []
        )

      {:ok, view} = open_component_builder(conn, recursive)

      node =
        Enum.find(
          Tree.walk(editor(view).tree),
          &(&1.kind == :component and
              MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "needful-self")
        )

      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "1 needed"
    end

    # A private helper — `<.badge_dismiss>` and twenty-two others across the kit — is declared in the
    # component's own `helpers` column, which the palette deliberately does not carry.
    test "and a private helper declares its own properties too", %{conn: conn, site: site} do
      holder =
        create_component!(
          site_id: site.id,
          name: "with-helper",
          template: ~s|<div><.badge_dismiss tone={@mood} /></div>|,
          attrs: [%{"name" => "mood", "type" => "string"}],
          slots: [],
          helpers: [
            %{
              "name" => "badge_dismiss",
              "args" => "assigns",
              "code" => "nil",
              "attrs" => [%{"name" => "tone", "type" => "string"}],
              "slots" => []
            }
          ]
        )

      {:ok, view} = open_component_builder(conn, holder)

      node =
        Enum.find(
          Tree.walk(editor(view).tree),
          &(&1.kind == :component and
              MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "badge_dismiss")
        )

      assert node, "a dotted tag is a component node"

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      assert has_element?(view, "#pb-attr-#{node.id}-tone")

      refute has_element?(view, "#pb-insp-edit-component"),
             "a private helper is the component being edited, not another one to open"
    end

    test "and the one it nests opens in its own editor, with the way back here", %{
      conn: conn,
      site: site
    } do
      outer = nesting(site.id)
      {:ok, view} = open_component_builder(conn, outer)
      node = inner_node(view)

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      inner = view |> editor() |> Map.fetch!(:components) |> Enum.find(&(&1.name == "inner-one"))

      back =
        URI.encode_query(%{
          "return_to" => "/admin/dashboard/runtime/builder/component/#{outer.id}"
        })

      assert has_element?(
               view,
               ~s(#pb-insp-edit-component[href="/admin/dashboard/runtime/builder/component/#{inner.id}?#{back}"])
             )
    end
  end

  # THE ROUND TRIP. A component opened from a page's Inspector carries that page's builder in
  # `return_to`, and its back link goes there instead of to the component list. The address is
  # something a URL supplied, so only another builder is honoured — anything that could point the
  # back link off-site falls back to the list.
  describe "the way back from a component's editor" do
    defp back_link(conn, component, query) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}?#{query}")

      view
    end

    test "goes back to the builder it was opened from", %{conn: conn, site: site, page: page} do
      component = create_component!(site_id: site.id, name: "round-trip")
      page_builder = "/admin/dashboard/runtime/builder/page/#{page.id}"

      view = back_link(conn, component, URI.encode_query(%{"return_to" => page_builder}))

      assert has_element?(view, ~s(#pb-back[href="#{page_builder}"]))
    end

    test "and an error page's entry is kept on the way back", %{conn: conn, site: site} do
      component = create_component!(site_id: site.id, name: "round-trip-status")
      entry = "/admin/dashboard/runtime/builder/error-page/#{Ecto.UUID.generate()}?status=500"

      view = back_link(conn, component, URI.encode_query(%{"return_to" => entry}))

      assert has_element?(view, ~s(#pb-back[href="#{entry}"]))
    end

    test "but never anywhere that is not a builder", %{conn: conn, site: site} do
      component = create_component!(site_id: site.id, name: "round-trip-refused")

      for elsewhere <- [
            "//evil.example/admin/dashboard/runtime/builder/page/x",
            "https://evil.example/admin/dashboard/runtime/builder/page/x",
            "/admin/dashboard/runtime/components/../../../elsewhere",
            "javascript:alert(1)",
            ""
          ] do
        view = back_link(conn, component, URI.encode_query(%{"return_to" => elsewhere}))

        assert has_element?(view, ~s(#pb-back[href="/admin/dashboard/runtime/components"])),
               "#{inspect(elsewhere)} was honoured as a way back"
      end

      view = back_link(conn, component, "")
      assert has_element?(view, ~s(#pb-back[href="/admin/dashboard/runtime/components"]))
    end
  end

  # A TAB THE SAVE WILL THROW AWAY IS WORSE THAN NO TAB. `events` and `infos` are Page columns; a
  # Layout, a Component and an error page have `helpers` and nothing else. `code_keys/1` has always
  # asked the resource and dropped the rest, so a handler typed on a layout was written nowhere and
  # then flashed as "Saved to the layout" — the window and the writer disagreed, and the writer won
  # silently.
  describe "the code window offers only the tabs the record has a column for" do
    defp open_code(conn, path) do
      {:ok, view, _html} = live(conn, path)
      _loaded = render_async(view)
      render_click(view, "open_source", %{})
      {:ok, view}
    end

    test "a page has handlers and messages", %{conn: conn, page: page} do
      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert has_element?(view, "#pb-sourcetab-events")
      assert has_element?(view, "#pb-sourcetab-infos")
      assert has_element?(view, "#pb-sourcetab-helpers")
    end

    test "a layout has helpers and neither of the other two", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "tabbed-shell",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert has_element?(view, "#pb-sourcetab-helpers")
      refute has_element?(view, "#pb-sourcetab-events"), "a layout holds no handlers"
      refute has_element?(view, "#pb-sourcetab-infos"), "nor any messages"
    end

    test "and neither does a component", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "tabbed-one",
          template: ~s|<div>x</div>|,
          attrs: [],
          slots: []
        )

      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert has_element?(view, "#pb-sourcetab-helpers")
      refute has_element?(view, "#pb-sourcetab-events")
      refute has_element?(view, "#pb-sourcetab-infos")
    end

    # The columns decide it, so the answer is read off the resource rather than off a list of
    # section names kept somewhere near the window.
    test "which is the resource's own answer, not a list kept here", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "tabbed-shell-two",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      for key <- [:events, :infos] do
        assert is_nil(Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Layout, key)),
               "the fixture only means something while a Layout has no #{key}"

        refute has_element?(view, "#pb-sourcetab-#{key}")
      end

      assert Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Layout, :helpers)
      assert has_element?(view, "#pb-sourcetab-helpers")
    end
  end

  # WHAT THE DOCUMENT CAN ACTUALLY DO. Three of the four are rendered by a LiveView; an error page is
  # rendered by a controller, and `phx-click` and `phx-hook` are attached by the LiveView client
  # against a view. With no view owning that DOM the binding never attaches, so the panel was
  # offering a click that cannot fire.
  describe "bindings are offered only where a LiveView owns the DOM" do
    defp select_first_tag(view) do
      node = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :tag))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})
      node
    end

    test "a page offers On click and a JS hook", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      select_first_tag(view)

      assert has_element?(view, "#pb-act-toggle")
      assert has_element?(view, "#pb-hook-toggle")
    end

    test "and an error page offers neither", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          name: "bindingless",
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => ~s(<div id="oops">Not found</div>)}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      _loaded = render_async(view)
      select_first_tag(view)

      refute has_element?(view, "#pb-act-toggle"), "a controller renders this, not a LiveView"
      refute has_element?(view, "#pb-hook-toggle")
    end
  end

  # The three form blocks ship `phx-change` and `phx-submit` bound to handlers, and only a Page has
  # an `events` column to hold one.
  describe "the blocks a section can use" do
    test "a page is offered the form blocks", %{conn: _conn} do
      ids = Enum.map(Blocks.for_section("page"), & &1.id)

      assert "form-contact" in ids
      assert "form-newsletter" in ids
    end

    test "and a layout, a component and an error page are not" do
      for section <- ~w(layout component error-page) do
        ids = Enum.map(Blocks.for_section(section), & &1.id)

        refute "form-contact" in ids, section
        refute "form-fieldset" in ids, section
        refute "form-newsletter" in ids, section

        assert ids != [], "everything else still belongs everywhere"
      end
    end

    # The same rule the elements already follow, so the exception has to be declared rather than
    # inferred from a category name.
    test "a block that declares no sections belongs everywhere" do
      everywhere = Enum.reject(Blocks.all(), &Map.has_key?(&1, :sections))

      for section <- ~w(page layout component error-page) do
        ids = Enum.map(Blocks.for_section(section), & &1.id)
        assert Enum.all?(everywhere, &(&1.id in ids)), section
      end
    end
  end

  # THE STUDIO OPENS, AND THEN ITS CONTENTS ARRIVE. Everything the sheet shows was read before
  # anything could paint — a stylesheet parse and a kit-bundle parse, 10.8 MB of JSON for Chelekom
  # alone — so pressing Studio did nothing at all until they finished. The tests here needed
  # `render_async` the moment that changed, which is the clearest statement of what the reader was
  # waiting for.
  describe "the Studio loads off the click that opens it" do
    test "the sheet is there before its data is", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      opened = render_click(view, "open_sheet", %{"sheet" => "studio"})

      assert opened =~ "pb-studio-skeleton", "the shape of what is coming"
      assert has_element?(view, "#pb-studio-tokens"), "and the tabs are live already"
      refute opened =~ "pb-token-export", "while the contents are not here yet"
    end

    test "and the skeleton gives way to the real thing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})

      loaded = render_async(view, 5_000)

      refute loaded =~ "pb-studio-skeleton"
      assert has_element?(view, "#pb-token-export")
    end

    # A read that fails is an empty Studio, not a dead editor — so the shape it falls back to has to
    # carry every key the sheet reads. One key added to the loader and forgotten there is a KeyError
    # in a render, which takes the whole editor down rather than one sheet.
    test "and the shape it falls back to answers everything the sheet asks" do
      empty = Panels.empty_studio_data()

      for key <- [:tokens, :token_categories, :presets, :packages, :package_categories] do
        assert Map.fetch(empty, key) == {:ok, []}, "the failed read still has to answer #{key}"
      end
    end
  end

  # NOT A LIST WRITTEN OUT BY HAND. The Registry's chips named `data`, `input`, `layout` and
  # `marketing`; the kit's components are typed `general`, `forms`, `navigations`, `media`,
  # `feedback` and `overlays`. Four of six chips matched nothing, and picking one showed an empty
  # registry under the words "everything is already installed".
  describe "the Registry's categories come from the catalogue" do
    test "they are the kit's own types, not an invented list" do
      categories = Marketplace.package_categories(%{})

      refute "data" in categories, "no component has ever had this type"
      refute "input" in categories
      refute "layout" in categories
      refute "marketing" in categories
    end

    # Whatever the adapter is, the chips describe the packages it actually returns.
    test "and every category offered is one some package really has" do
      offered = MapSet.new(Marketplace.package_categories(%{}))

      real =
        %{category: "all"}
        |> Marketplace.packages()
        |> Enum.map(& &1.category)
        |> MapSet.new()

      assert MapSet.subset?(real, offered),
             "a package whose category has no chip cannot be filtered to"
    end

    # An adapter written before `package_categories/1` existed still gets chips that match its data.
    test "an adapter that cannot answer is asked its packages instead" do
      Application.put_env(:mishka_cms_core, :builder_marketplace, Marketplace.Mock)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      refute MishkaGervaz.Helpers.exports?(Marketplace.Mock, :package_categories, 1),
             "the fallback only means something while Mock has no answer of its own"

      derived = Marketplace.package_categories(%{})
      from_packages = %{} |> Marketplace.packages() |> Enum.map(& &1.category) |> Enum.uniq()

      assert Enum.sort(derived) == Enum.sort(from_packages)
    end
  end

  describe "when the palette cannot be read" do
    # An invalid site id is the cheapest real failure to provoke — `for_tenant_with_globals` refuses
    # to cast it, no mocking and no sandbox tricks.
    test "the panel says so and offers a retry", %{conn: conn, page: page} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, view, _html} =
            live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=not-a-uuid")

          html = render_async(view)

          assert html =~ "The component list could not be loaded."
          assert has_element?(view, "#pb-palette-retry")
        end)

      assert log =~ "palette read failed",
             "a failure the reader can see must also leave a trace for whoever has to explain it"
    end

    # The other half: a working site must never show the failure state, or the message means nothing.
    test "a site that reads fine shows components and no retry", %{conn: conn, page: page} do
      create_component!(name: "retryless-card")

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-comp-retryless-card")
      refute has_element?(view, "#pb-palette-retry")
    end
  end

  describe "the palette" do
    setup %{site: site} do
      %{component: create_component!(site_id: site.id, name: "hero-card")}
    end

    # An installed extension's own components are found together under its name, ahead of the
    # categories, and its chip shows them alone; a UI kit's stay under their categories.
    test "an installed extension's own components are one group under its name", %{
      conn: conn,
      page: page
    } do
      installer = MishkaCmsCore.Test.AcmeShopInstaller

      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: installer,
          event: MishkaCmsCore.Install.Extensions.event(),
          extension: :acme_shop,
          extra: [%{label: "Acme Shop", summary: "", fields: []}],
          status: :started
        })

      on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, installer, false) end)

      create_component!(
        name: "shop-cart",
        type: "media",
        extra: %{"ui_kit" => "acme_shop", "ui_kit_version" => "1.0.0"}
      )

      create_component!(name: "kit-photo", type: "media", extra: %{"ui_kit" => "chelekom"})

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s([data-group="Acme Shop"] #pb-comp-shop-cart))
      assert has_element?(view, ~s([data-group="media"] #pb-comp-kit-photo))
      refute has_element?(view, ~s([data-group="media"] #pb-comp-shop-cart))

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="pb-group"]))
             |> Enum.map(&LazyHTML.attribute(&1, "data-group"))
             |> List.first() == ["Acme Shop"]

      view |> element(~s(button[phx-value-cat="Acme Shop"])) |> render_click()

      assert has_element?(view, "#pb-comp-shop-cart")
      refute has_element?(view, "#pb-comp-kit-photo")
    end

    test "lists the site's components and filters by search", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-comp-hero-card")

      render_change(view, "palette_query", %{"value" => "zzzz"})
      refute has_element?(view, "#pb-comp-hero-card")

      render_change(view, "palette_query", %{"value" => "hero"})
      assert has_element?(view, "#pb-comp-hero-card")
    end

    # Every admin table links the editor as `?site_id=…`, so this is how a master actually arrives.
    # It used to hand that site to `:master_read`, whose `TenantContext` validation refuses a non-nil
    # tenant on a multitenancy-bypass action — the read errored and the palette rendered empty.
    test "a master arriving with ?site_id= still gets the site's components", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{site.id}")

      assert has_element?(view, "#pb-comp-hero-card")
    end

    test "?site_id= scopes the palette to that site plus the global components", %{
      conn: conn,
      page: page,
      site: site
    } do
      other = create_site!(name: "other", host: "other.test", active: true)
      create_component!(site_id: other.id, name: "foreign-card")
      create_component!(name: "global-card")

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{site.id}")

      assert has_element?(view, "#pb-comp-hero-card")
      assert has_element?(view, "#pb-comp-global-card")
      refute has_element?(view, "#pb-comp-foreign-card")
    end

    # A component names its own palette glyph in `extra.icon`. Nothing else may override that — it is
    # the authored answer, and the suggestion below exists only for rows that have none.
    test "a component's own extra.icon is the glyph the palette draws", %{conn: conn, page: page} do
      create_component!(name: "kit-thing", extra: %{"icon" => "gallery"})

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-thing")) == :gallery
    end

    test "an unknown icon name falls back rather than rendering nothing", %{
      conn: conn,
      page: page
    } do
      create_component!(name: "kit-odd", extra: %{"icon" => "not-an-icon"})

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-odd")) == :box
    end

    # 183 components will not all be annotated by hand, so the palette suggests from the name.
    test "a component with no icon gets one suggested from its name", %{conn: conn, page: page} do
      for name <-
            ~w(kit-password-field kit-mega-menu kit-heading-two kit-image-block kit-data-table) do
        create_component!(name: name)
      end

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-password-field")) == :lock
      assert Panels.entry_icon(entry(view, "kit-mega-menu")) == :nav
      assert Panels.entry_icon(entry(view, "kit-heading-two")) == :head
      assert Panels.entry_icon(entry(view, "kit-image-block")) == :img
      assert Panels.entry_icon(entry(view, "kit-data-table")) == :table
    end

    test "a name that suggests nothing falls back to the component's category", %{
      conn: conn,
      page: page
    } do
      create_component!(name: "kit-zzz", type: "media")

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-zzz")) == :image
    end

    # Every card is the same box whatever its name is; one wrapping label must not make its row grow,
    # and the box holds two lines of it: the label never shrinks to one and cuts the second off.
    test "every palette card is the same fixed height, tall enough for a two-line name", %{
      conn: conn,
      page: page
    } do
      create_component!(name: "kit-x")
      create_component!(name: "kit-with-a-very-long-name-that-wraps-twice")

      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      [short, long] =
        for name <- ~w(kit-x kit-with-a-very-long-name-that-wraps-twice) do
          [_before, after_id] = String.split(html, ~s(id="pb-comp-#{name}"), parts: 2)
          [tag, _rest] = String.split(after_id, ">", parts: 2)
          tag =~ "h-[92px]"
        end

      assert short
      assert long
      assert html =~ "line-clamp-2 w-full flex-none"
    end

    # The kit's own name is on every one of its components, so printing it on every card spends the
    # label on the one word that never varies and pushes the part that does off the card.
    test "a kit prefix is dropped from the card label but kept everywhere else", %{
      conn: conn,
      page: page
    } do
      for name <- ~w(acme-alert acme-toast acme-banner solo-widget) do
        create_component!(name: name)
      end

      {:ok, view, _html} = open_builder(conn, page)
      entries = editor(view) |> Map.fetch!(:components)
      prefixes = Panels.kit_prefixes(entries)

      assert Panels.short_label(entry(view, "acme-alert"), prefixes) == "Alert"
      assert Panels.short_label(entry(view, "acme-banner"), prefixes) == "Banner"

      # Used three times, "acme" is a kit; "solo" is used once and stays.
      assert Panels.short_label(entry(view, "solo-widget"), prefixes) == "Solo Widget"

      # The full name is still what the card is titled with and what it inserts.
      assert view |> element("#pb-comp-acme-alert") |> render() =~ "acme-alert"
    end

    test "picking a component arms placement, and placing inserts it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-hero-card") |> render_click()
      assert render(view) =~ "Placing hero-card"

      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert inserted.tag == ".component"
      assert MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(inserted) == "hero-card"
      refute render(view) =~ "Placing hero-card"
    end

    # The click that places happens inside the CANVAS, which is a different LiveView — so an
    # arming flag kept in the chrome's own assigns left the browser selecting elements while the hint
    # said "click the canvas". This drives the two the way a person does.
    test "arming in the chrome and clicking IN THE CANVAS places the component", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-hero-card") |> render_click()
      section = node_with_tag(view, "section")
      render_click(canvas, "select", %{"id" => section.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert placed
      # Inside the clicked container, as its last child — and the arming is spent.
      assert placed.parent_id == section.id
      refute render(view) =~ "Placing hero-card"
    end

    # Clicking a component that declares no slot is someone pointing at WHERE they want the new
    # element, not a request to nest it there. The browser answered that with a red
    # "does not declare a slot" toast and placed nothing.
    test "clicking an element that cannot hold children places after it", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-leaf", nil, "<hr/>")
      create_component!(name: "pb-leaf")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><.component component_name="pb-leaf" site="Global" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      leaf =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(canvas, "select", %{"id" => leaf.id})

      tree = view |> editor() |> Map.fetch!(:tree)
      placed = tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "hero-card"))

      assert placed
      # A sibling of the leaf, not a child of it.
      assert placed.parent_id == leaf.parent_id
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, leaf.id) + 1
    end

    test "a canvas click with nothing armed still selects", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      section = node_with_tag(view, "section")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(canvas, "select", %{"id" => section.id})

      assert view |> editor() |> Map.fetch!(:selection) == section.id
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "a click on no element places at the end of the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(canvas, "select", %{})

      tree = view |> editor() |> Map.fetch!(:tree)
      assert tree |> Tree.get(List.last(tree.roots)) |> Map.fetch!(:kind) == :component
    end

    # Dropping a global component onto a site's page has to render it. The palette used to bind every
    # card to the page's site, which for a global component named a module nobody ever built.
    test "placing a GLOBAL component from the palette renders it on the canvas", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-drop-footer", nil, "<footer>dropped global footer</footer>")
      create_component!(name: "pb-drop-footer")

      page = create_page!(site_id: site.id, template: ~s(<div id="root"></div>))
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-pb-drop-footer") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "0"})

      assert editor_html(view) =~ ~s(site="Global")

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ "dropped global footer"
      refute html =~ "failed to render"
    end

    test "selecting a placed component shows its properties as real controls", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "fancy-box",
        attrs: [
          %{"name" => "color", "type" => "string", "opts" => %{}},
          %{"name" => "variant", "type" => "string", "opts" => %{}},
          %{"name" => "disabled", "type" => "boolean", "opts" => %{}},
          %{"name" => "title", "type" => "string", "opts" => %{"required" => true}}
        ],
        helpers: [
          %{
            "name" => "color_class",
            "args" => "color",
            "code" => "defp color_class(_), do: \"\"",
            "discriminators" => [
              %{"axis" => "color", "values" => ~w(primary secondary danger warning info light)},
              %{"axis" => "variant", "values" => ~w(base filled)}
            ]
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-fancy-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # EVERY declared property is on the form, each as its own typed control. A component's option
      # surface is what the author opened the inspector for; showing only the ones already set meant
      # alert's seventeen properties arrived as two.
      html = render(view)
      assert html =~ "Title"
      assert html =~ "Required"
      assert html =~ "Variant"
      assert html =~ "Color"
      assert html =~ "Disabled"

      # …and they are sectioned, not one flat column.
      assert html =~ "Appearance"

      # The preset rides in the button's OWN `value`, not `phx-value-value`: LiveView overwrites the
      # latter with `el.value`, which on a button is empty, so the preset arrived blank.
      assert html =~ ~s(value="filled")
      refute html =~ ~s(phx-value-value=)

      # A six-value list is a select, a two-value list is segmented, a boolean is a switch.
      assert html =~ "<select"
      assert html =~ ~s(<option value="secondary")
      assert html =~ ~s(role="switch")

      # A required property keeps its delete control, disabled — an absent one would read as
      # "look somewhere else".
      assert view |> element("#pb-attr-clear-#{placed.id}-title") |> render() =~ "disabled"
    end

    # A component's own properties open; the chrome under a long panel does not. Sixteen rows of
    # properties with the state pills wedged above them is the layout the fold exists to fix, and a
    # plain element with no properties at all keeps its chrome open. The BREAKPOINT strip is exempt:
    # it is what tells a reader which device the settings below belong to, and a fold that hides that
    # is how someone edits Mobile believing they are editing Desktop.
    test "on a component with many properties the chrome starts folded and the properties do not",
         %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "wide-box",
        attrs:
          Enum.map(~w(a b c d e f g h i j), &%{"name" => &1, "type" => "string", "opts" => %{}})
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-wide-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      assert html =~ "pb-attr-#{placed.id}-a"
      refute html =~ "pb-state-hover", "State starts folded behind a long property panel"

      # The breakpoint tabs are always on screen — they name the scope of everything under them.
      assert html =~ "pb-bp-tablet"

      # …and the folded chrome opens on the reader's say-so, because the heading tells the server
      # which state it is in rather than making the toggle guess at the default.
      assert view |> element("#pb-section-state") |> render_click() =~ "pb-state-hover"
    end

    # "Layout" names both a property group of a component and a section of the style panel. They were
    # one key and one DOM id, so folding either folded both — and duplicate ids break DOM patching.
    test "folding a component's Layout group leaves the style panel's Layout alone", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "gap-box",
        attrs: [%{"name" => "padding", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-gap-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The two "Layout"s are different things — a property group of the COMPONENT and a section of
      # the style panel — and they keep separate fold state. The style one is open on selection, so
      # the claim is that toggling either leaves the other exactly as it was.
      assert render(view) =~ "pb-style-form-base-gap"

      assert view |> element("#pb-prop-layout") |> render_click() =~ "pb-style-form-base-gap"
      assert view |> element("#pb-prop-layout") |> render_click() =~ "pb-style-form-base-gap"

      # And back the other way: closing the style section does not close the component's group.
      view |> element("#pb-section-layout") |> render_click()
      html = view |> element("#pb-prop-layout") |> render_click()

      assert html =~ "pb-attr-#{placed.id}-padding"
      refute html =~ "pb-style-form-base-gap"
    end

    # A component that declares a property as required will not render without it, so a page missing
    # one is already broken — publishing it just puts the breakage in front of visitors. A DRAFT is
    # allowed to be half-finished; that is what a draft is.
    test "a missing required property blocks the save and names itself", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "needs-title",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{"required" => true}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-needs-title") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      html = publish!(view)
      assert html =~ "Not saved"
      assert html =~ "needs-title.title"

      # Fill it and the save goes through.
      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "title",
        "value" => "Real title"
      })

      assert save!(view) =~ "saved"
    end

    # Blurring a field you only clicked into must not wipe the component's default.
    test "leaving an untouched property alone keeps the default", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "defaulted",
        attrs: [%{"name" => "message", "type" => "string", "opts" => %{"default" => "Hello"}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-defaulted") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # What a blur with nothing typed sends.
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "message",
        "value" => ""
      })

      # The attribute is gone, so the component renders its own default again rather than an empty
      # string that overrides it.
      node = view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id)
      assert Node.attr_text(node, "message") == nil
    end

    test "editing a prop writes the attribute and clearing it removes it", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "plain-box")
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-plain-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "variant",
        "value" => "filled"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id) |> Node.attr("variant") ==
               {:string, "filled"}

      render_click(view, "op", %{
        "kind" => "delete_attr",
        "node_id" => placed.id,
        "name" => "variant"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id) |> Node.attr("variant") ==
               nil
    end

    test "a placed component serializes in the form the compilers read", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(component_name="hero-card")
      assert reloaded.template =~ "<.component"
    end
  end
end
