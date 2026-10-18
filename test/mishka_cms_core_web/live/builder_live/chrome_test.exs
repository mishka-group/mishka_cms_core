# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.ChromeTest do
  @moduledoc """
  The demo's chrome around the canvas, and responsive style overrides.
  """
  use MishkaCmsCore.BuilderLiveCase

  # Checked against the v1 prototype served at :8000, option by option.
  describe "the demo's chrome" do
    test "the palette is grouped under category headings with counts", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "grid-box", type: "layout")
      create_component!(site_id: site.id, name: "big-title", type: "text")

      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      assert html =~ "LAYOUT"
      assert html =~ "TEXT"
      assert html =~ "Global — all sites"
      assert html =~ "Tenant only"
    end

    test "the Studio chip counts the team's own tokens", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      studio = view |> element("#pb-studio") |> render()

      # The Mock seeds two custom tokens (brand-teal, screen-xl) — the demo's "+2".
      assert studio =~ "2"
    end

    # The sample findings render through the SAME card as a measured one, so a missing key crashes
    # the rail — which is exactly what happened, and only with the flag on.
    test "the audit rail renders with sample findings switched on", %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_demo_data, true)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_demo_data) end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Low contrast on muted text"
      assert html =~ "Page score"
    end

    # Sample content must never stand in for real content, and must never claim to be a record you
    # can act on. Both are checked here because the flag makes it easy to get wrong.
    # THE RECORD IS NEVER SAMPLED. The other two panels show prototype content when they are empty,
    # because an empty rail cannot be judged; the timeline does not, because a sample row there is
    # indistinguishable from somebody's actual work and the button beside it offers to restore it.
    test "the sample content never reaches the record", %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_demo_data, true)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_demo_data) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "history"})

      html = render_async(view)

      assert html =~ "No changes recorded yet"
      refute html =~ "Header made sticky"
      refute html =~ "history_revert"

      # And a real edit shows up as itself.
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      _flushed = render_async(view)

      assert render_async(view) =~ "Deleted element"
    end

    test "the sample thread yields to a real conversation", %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_demo_data, true)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_demo_data) end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()
      assert render(view) =~ "Make the header sticky and reduce its height a bit"

      view |> form("#pb-ai-form", %{"prompt" => "tighten the spacing"}) |> render_submit()

      html = render(view)
      refute html =~ "Make the header sticky and reduce its height a bit"
      assert html =~ "tighten the spacing"
    end

    # The attach menu sends the SOURCE with the prompt, so each item has to produce something real.
    test "Capture selection attaches the selected element's markup", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      view |> element("#pb-rail-assistant") |> render_click()

      view |> element("#pb-ai-attach-selection") |> render_click()

      assert has_element?(view, "#pb-ai-attachment")
      assert render(view) =~ "&lt;h1&gt; ·"

      view |> form("#pb-ai-form", %{"prompt" => "match this"}) |> render_submit()

      # It travels with the message and the composer is clear again.
      assert render(view) =~ "&lt;h1&gt; ·"
      refute has_element?(view, "#pb-ai-attachment")
    end

    test "Capture template attaches the whole document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      view |> element("#pb-ai-attach-template") |> render_click()

      assert render(view) =~ "whole template ·"
    end

    test "Add file opens the media library rather than a dead upload", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      view |> element("#pb-ai-attach-file") |> render_click()

      assert has_element?(view, "#pb-sheet")
      assert render(view) =~ "Assets"
    end

    # Every overlay had its click-away on the full-screen backdrop, where no click is ever "away".
    test "overlays carry click-away on the panel, not the backdrop", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      backdrop = view |> element("#pb-sheet") |> render()

      refute backdrop =~
               ~s(<div id="pb-sheet" data-role="pb-sheet" class="fixed inset-0 z-[80] flex justify-end bg-[#17161a]/30" phx-click-away)

      assert backdrop =~ "phx-click-away=\"close_sheet\""
    end

    # The stage control is the prototype's split button and it has two distinct looks. Publishing is
    # outward-facing, so this is the one place the published styling is checked.
    test "the stage button is violet-tinted as a draft and solid once published", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      draft = view |> element("#pb-stage") |> render()
      assert draft =~ "bg-[#f2f1fc]"
      assert draft =~ "text-[#4f4bcc]"
      assert draft =~ "Draft"
      # The dot is the autosave light; a caret would mean published.
      assert view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"

      # Selecting only SELECTS — the page is not live until the button is pressed.
      view |> element("#pb-stage-published") |> render_click()
      assert view |> element("#pb-stage") |> render() =~ "Publish"

      view |> element("#pb-stage") |> render_click()

      # AND ONCE IT IS LIVE THE CHIP FALLS BACK TO DRAFT, because publishing is an act rather than a
      # mode: whatever is done next is unpublished work again. The button stays solid — it is still
      # reporting that the page went out — and offers to keep the next work aside.
      published = view |> element("#pb-stage") |> render()
      assert published =~ "linear-gradient(140deg,#6d69e6,#4f4bcc)"
      assert published =~ "text-white"
      assert published =~ "Save draft"
      refute view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"
    end

    # The layers tree is the other way into the document, and it had three holes: a row named every
    # component ".component", a row could not be dropped onto another one, and there was no way to
    # delete a branch from it.
    test "a component row is named after the component, not the wrapper tag", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="chelekom-alert" site="Global"/></div>)
        )

      # The tree opens two levels deep on arrival, so a component one level in is already listed.
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "chelekom-alert"
      refute html =~ ">.component<"
    end

    # A DEFAULT IS NOT ALWAYS A WORD. `chelekom-banner` declares `params` with a default of
    # `%{kind: "banner"}`, and the layers row rendered it with `to_string/1` — which raises
    # `Protocol.UndefinedError` on a map and took the whole builder LiveView down the moment a banner
    # appeared in the tree. Seven of the kit's components declare a map or list default this way.
    test "a component whose attribute defaults to a map still renders its row", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "mappy",
        template: "<div>{@params[:kind]}</div>",
        attrs: [
          %{"name" => "params", "type" => "map", "opts" => %{"default" => %{"kind" => "banner"}}}
        ],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="mappy" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      assert render(view) =~ "mappy"
    end

    # Rendering the layers row was only the FIRST of eight places that stringified a default. Opening
    # the inspector went through `plain_input/1` and raised there instead — same map, same
    # `Protocol.UndefinedError`, and because a raise inside a render kills the LiveView, the author
    # saw the canvas flash and reconnect rather than an inspector.
    #
    # So this selects the node, which is what a click does, and covers every widget the eight call
    # sites belong to: a map and a list default against a text box, a colour, a link, an image and a
    # select.
    test "selecting a component with structured defaults opens the inspector", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "structy",
        template:
          "<div class={@color}><a href={@href}><img src={@src} /></a>{@params[:kind]}{@classes}{@variant}</div>",
        attrs: [
          %{"name" => "params", "type" => "map", "opts" => %{"default" => %{"kind" => "banner"}}},
          %{"name" => "classes", "type" => "list", "opts" => %{"default" => ["a", "b"]}},
          %{"name" => "color", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{"name" => "href", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{"name" => "src", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => %{"x" => 1}, "values" => ["default", "outline"]}
          }
        ],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="structy" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      component = node_with_tag(view, ".component")

      render_click(view, "inspect", %{"id" => component.id})

      # It is still alive, and it is showing the component rather than a reconnect.
      assert render(view) =~ "structy"
    end

    # A component's slots ARE its children in the tree, and each is named by the slot it fills —
    # written the way the markup writes it, `:label`, rather than as the tree's own `__label_slot`.
    test "a component's slots appear in the tree, named", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root"><.component component_name="chelekom-alert" site="Global">\
          <:label>Careful</:label></.component></div>\
          """
        )

      # Two levels are open on arrival, and a component with a slot is a branch — so both the
      # component and the slot under it are already listed.
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "chelekom-alert"
      assert html =~ ":label"
      refute html =~ "__label_slot"
    end

    # A component takes a drop only where the drop can land: it needs a slot to hold it. 120 of the
    # kit's components declare one; a component that declares none renders nothing you drop in, so
    # the tree must not offer it as a target.
    test "only a component with a slot is a drop target", %{conn: conn, site: site} do
      with_slot =
        create_component!(
          site_id: nil,
          name: "demo-card",
          slots: [%{"name" => "inner_block", "opts" => %{"required" => false}}],
          template: "<div class=\"card\">{render_slot(@inner_block)}</div>"
        )

      without = create_component!(site_id: nil, name: "demo-rule", template: "<hr class=\"r\"/>")

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root">\
          <.component component_name="#{with_slot.name}" site="Global"/>\
          <.component component_name="#{without.name}" site="Global"/>\
          </div>\
          """
        )

      {:ok, view, _html} = open_builder(conn, page)

      nodes =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :component))

      [card, rule] = Enum.sort_by(nodes, &Node.component_name/1)

      assert view |> element(~s([data-layer-row="#{card.id}"])) |> render() =~
               ~s(data-container="true")

      refute view |> element(~s([data-layer-row="#{rule.id}"])) |> render() =~
               ~s(data-container="true")
    end

    # `<:inner_block>` is not writable HEEx — the compiler answers "the slot name :inner_block is
    # reserved" — so offering it as a slot to add gave a button whose only possible outcome was that
    # error in a flash. It is the content you put IN the component, and the panel now says so.
    test "the inner block is described rather than offered as a slot to add", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-note",
        slots: [
          %{"name" => "inner_block", "opts" => %{"required" => false}},
          %{"name" => "footer", "opts" => %{"required" => false}}
        ],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-note" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      note =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => note.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # NOT CLICKED OPEN. A component with a slot to add now arrives with the group unfolded — the
      # "End section +" row on a field was the one thing a joined input could not be built without,
      # and folded, nobody found it. Clicking here would close it again.
      assert has_element?(view, "#pb-slot-add-inspector-footer")
      refute has_element?(view, "#pb-slot-add-inspector-inner_block")
      assert has_element?(view, "#pb-slot-inner-block")
      # The layers rail keeps the same rule: a ghost row for `footer`, none for the inner block.
      refute has_element?(view, "#pb-slot-add-#{note.id}-inner_block")

      # And it is still a drop target: the inner block is exactly where a drop lands.
      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => note.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure").parent_id == note.id
    end

    # WHAT CAN GO INSIDE, folded like everything else in the rail. The slot rows used to hang off the
    # component at full volume, and a component that declared NONE got a line reading
    # `__ no slots declared` — the common case, written in the tree's own vocabulary, filed under
    # `.properties`, which is not what it was about. Reported on the editor issue as "it doesn't look
    # good, it's confusing".
    test "a component's slots are a folded group, not loose rows", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-panel",
        slots: [%{"name" => "footer", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-panel" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      panel = component_node(view)
      render_click(view, "toggle_expand", %{"id" => panel.id})

      assert has_element?(view, "#pb-slots-#{panel.id}"), "the rail has no .slots group"

      refute has_element?(view, "#pb-slot-add-#{panel.id}-footer"),
             "the slot rows are open before anybody asked for them"

      view |> element("#pb-slots-#{panel.id}") |> render_click()

      assert has_element?(view, "#pb-slot-add-#{panel.id}-footer")
    end

    # Named the way it is WRITTEN. `<:footer>` is what goes in the markup; `__footer_slot` was the
    # tree's bookkeeping leaking into a label the author has to read.
    test "and a slot is labelled the way it is written in the markup", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-aside",
        slots: [%{"name" => "footer", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-aside" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      aside = component_node(view)
      render_click(view, "toggle_expand", %{"id" => aside.id})
      view |> element("#pb-slots-#{aside.id}") |> render_click()

      row = view |> element("#pb-slot-add-#{aside.id}-footer") |> render()

      assert row =~ ":footer"
      refute row =~ "__footer_slot"
    end

    # THE COMMON CASE SAYS NOTHING UNTIL ASKED. Most components declare no slots at all, and the old
    # line announced that on every one of them.
    test "a component with no slots is silent until the group is opened", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-rule",
        slots: [],
        template: "<hr />"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-rule" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      rule = component_node(view)
      render_click(view, "toggle_expand", %{"id" => rule.id})

      refute render(view) =~ "no slots declared", "the dead line is back"
      refute render(view) =~ "takes nothing inside"

      view |> element("#pb-slots-#{rule.id}") |> render_click()

      assert render(view) =~ "takes nothing inside"
    end

    defp component_node(view) do
      view
      |> editor()
      |> Map.fetch!(:tree)
      |> Tree.walk()
      |> Enum.find(&(&1.kind == :component))
    end

    # A Phoenix slot may be given more than once, and two rows called `__item_slot` tell you nothing
    # about which is which.
    test "repeated slots are numbered in the tree", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-list",
        slots: [%{"name" => "item", "opts" => %{"required" => false}}],
        template: "<ul>{render_slot(@item)}</ul>"
      )

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root"><.component component_name="demo-list" site="Global">\
          <:item>One</:item><:item>Two</:item></.component></div>\
          """
        )

      {:ok, view, _html} = open_builder(conn, page)
      list = component_node(view)

      html = render(view)
      assert html =~ ":item 1"
      assert html =~ ":item 2"

      # And the row to add a third says so rather than claiming the slot is empty. It lives in the
      # component's `.slots` group now, which is folded until it is asked for.
      view |> element("#pb-slots-#{list.id}") |> render_click()
      assert render(view) =~ "add another"
    end

    # The rule that a component needs somewhere to put a child is the SERVER's, not the browser's —
    # the tree only mirrors it, so a tampered payload has to be refused here.
    test "the server refuses a drop into a component with no slot", %{conn: conn, site: site} do
      create_component!(site_id: nil, name: "demo-hr", template: "<hr/>")

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-hr" site="Global"/><p>x</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      tree = editor(view).tree
      target = tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))
      dragged = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      html =
        render_click(view, "drop", %{
          "node_id" => dragged.id,
          "parent_id" => target.id,
          "index" => "0"
        })

      assert html =~ "does not declare a slot"
      # And nothing moved.
      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(dragged.id)
             |> Map.fetch!(:parent_id) ==
               dragged.parent_id
    end

    # A required slot is the same promise as a required property.
    test "a missing required slot blocks the save", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-collapse",
        slots: [%{"name" => "trigger", "opts" => %{"required" => true}}],
        template: "<div>{render_slot(@trigger)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-collapse" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      html = publish!(view)
      assert html =~ "Not saved"
      assert html =~ "demo-collapse.:trigger"
    end

    # A component's markup lives on the COMPONENT, not on the page — so the tree shows it in place
    # rather than sending anyone to another screen, and shows it as a window, not as rows to edit.
    test "a component's own markup is listed inside it, read-only", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: nil,
          name: "demo-footer",
          template: ~s(<footer class="f"><p>Built with MishkaCMS</p></footer>)
        )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="#{component.name}" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "demo-footer"
      # Its insides are there…
      assert html =~ "footer"

      # …but they carry none of the row actions, because editing them would rewrite the component
      # under every other page using it.
      instance =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      refute has_element?(view, "#pb-layer-delete-#{instance.id} ~ *")
    end

    test "a layers row carries what a drop needs and deletes its branch", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      row = view |> element(~s([data-layer-row="#{section.id}"])) |> render()
      assert row =~ ~s(draggable="true")
      assert row =~ ~s(data-parent-id=)
      assert row =~ ~s(data-index=)
      assert row =~ ~s(data-container="true")
      assert row =~ ~s(data-kind="tag")

      # And the delete button takes the branch with it.
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()
      view |> element("#pb-layer-delete-#{section.id}") |> render_click()
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() < before
      refute has_element?(view, ~s([data-layer-row="#{section.id}"]))
    end

    # A COUNT HAS TO MATCH THE ROWS UNDER IT. The panel has always hidden the indentation between two
    # tags, but it counted it — so an indented `<div>` announced seven children over three rows, and a
    # container holding nothing but a newline offered a chevron that opened onto nothing.
    test "a row counts the children it is going to draw", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: "<section>\n  <p>One</p>\n  <p>Two</p>\n</section>\n<div>\n</div>"
        )

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      assert length(section.children) == 5, "three runs of indentation and two paragraphs"

      row = view |> element(~s([data-layer-row="#{section.id}"])) |> render()
      assert row =~ "(2)"
      refute row =~ "(5)"
      assert row =~ ~s(phx-value-id="#{section.id}"), "and it is still expandable"

      empty = node_with_tag(view, "div")
      assert empty.children != [], "the div is holding its newline"

      empty_row = view |> element(~s([data-layer-row="#{empty.id}"])) |> render()
      refute empty_row =~ "(1)", "a container with only indentation in it has nothing to open"
      refute empty_row =~ "toggle_expand"
    end

    # ONE MENU FOR BOTH SURFACES. The canvas is a frame rendering the site's own document with none
    # of the admin stylesheet, so it forwards its right-clicks to the chrome rather than drawing a
    # second, inline-styled copy — which is why there is exactly one of these in the page and why it
    # carries no `phx-click`: the hook stamps the node and pushes the action, so opening costs
    # nothing and no patch can swap the row out mid-gesture.
    test "the right-click menu is rendered once, for both surfaces", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(
               view,
               "#pb-ctx[phx-hook='PbContextMenu'][data-target='[data-layer-row]']"
             )

      assert has_element?(view, "#pb-ctx[hidden]")

      menu = view |> element("#pb-ctx") |> render()
      refute menu =~ "phx-click"

      for action <- Panels.context_actions(), do: assert(menu =~ ~s(data-action="#{action}"))
    end

    test "an entry acts on the node it names, not on the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "ctx", %{"action" => "duplicate", "node_id" => h1.id})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> headings() == 2
    end

    # WITHOUT THIS the menu edits one element while the inspector beside it still describes another,
    # which is how you change the padding of something you are not looking at. `duplicate` is the
    # wrong entry to assert it with — a copy takes the focus, and should.
    test "opening the menu selects what it was opened on", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})

      assert editor(view).selection == h1.id
    end

    test "wrap puts the node inside a fresh container", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "ctx", %{"action" => "wrap", "node_id" => h1.id})

      wrapper = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node_parent(view, h1.id))
      assert wrapper.tag == "div"
      assert h1.id in wrapper.children
    end

    # THE HALF THE MENU ENTRY IS FOR. A link put around the words is only useful if the address can
    # then be typed, and a bare `<a>` draws no field at all — the Attributes list only lists what the
    # node carries.
    test "the link it makes has an address to fill in", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      text = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :text))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "ctx", %{"action" => "link", "node_id" => text.id})

      link = Enum.find(Tree.walk(editor(view).tree), &(&1.tag == "a"))
      assert Node.attr_text(link, "href") == "#"
      assert text.id in link.children

      assert editor(view).selection == link.id, "the link is what the author now edits"

      render_click(view, "toggle_prop_group", %{
        "group" => "section:Attributes",
        "folded" => "true"
      })

      assert has_element?(view, ~s(form[id="pb-attr-row-form-#{link.id}-href"]))
    end

    # The dead end a run of text used to be: a panel saying what it could not do and offering one way
    # out, to the element around it.
    test "a run of text offers the link from the inspector", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      text = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :text))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => text.id})
      assert has_element?(view, "#pb-text-link")

      view |> element("#pb-text-link") |> render_click()

      assert Enum.any?(Tree.walk(editor(view).tree), &(&1.tag == "a"))
    end

    test "an element the words sit in offers no such button", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})

      refute has_element?(view, "#pb-text-link")
    end

    test "styles travel between two elements", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => h1.id,
        "bucket" => "base",
        "prop" => "padding",
        "value" => "8"
      })

      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})
      render_click(view, "ctx", %{"action" => "paste_styles", "node_id" => p.id})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(p.id)
             |> Map.fetch!(:meta)
             |> then(& &1.styles.base) == %{"padding" => "8"}
    end

    # SAVING A SELECTION IS A FORM, and the form already exists. The menu opens it rather than
    # growing a second one beside it.
    test "save as snippet opens the studio on its snippets tab", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "ctx", %{"action" => "snippet", "node_id" => h1.id})

      assert :sys.get_state(view.pid).socket.assigns.sheet == :studio
      assert :sys.get_state(view.pid).socket.assigns.studio_tab == :snippets
    end

    # The action is a word off the wire. Anything the menu does not offer is dropped rather than
    # being handed to the session to interpret.
    test "an action the menu never offers is ignored", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(view, "ctx", %{"action" => "publish_everything", "node_id" => h1.id})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # THE BAR ONLY EXISTS WHILE SOMETHING IS HELD. It sits above the canvas rather than floating over
    # it, because a bar that covers the page hides the thing it is about.
    test "holding a second element opens the bulk bar", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-multi-bar")

      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "p").id})

      assert has_element?(view, "#pb-multi-bar")
      assert render(view) =~ "2 elements held"

      render_click(view, "bulk", %{"action" => "delete"})

      refute has_element?(view, "#pb-multi-bar")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> headings() == 0
    end

    test "clearing lets go without changing the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "clear_marks", %{})

      refute has_element?(view, "#pb-multi-bar")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # OVER THE PAGE'S WORDS, not its markup. A page says "Contact Us" in four places and the fifth is
    # a class called `contact-us`; renaming the company must not touch the CSS.
    test "find and replace sweeps the text and nothing else", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<section class="contact-us"><h1>Contact Us</h1><p>contact us today</p></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_find", %{})
      assert has_element?(view, "#pb-find")

      render_change(view, "find_query", %{"find" => "contact us", "replace" => "Talk to us"})

      # Two places, and the class is not one of them — the search is case-insensitive so the
      # capitalised heading counts.
      assert render(view) =~ "2 matches in 2 places"

      render_click(view, "replace_all", %{})

      heex = view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize()
      assert heex =~ "<h1>Talk to us</h1>"
      assert heex =~ "<p>Talk to us today</p>"
      assert heex =~ ~s(class="contact-us"), "a class is not a word on the page"
    end

    test "a replace-all is one undo", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><p>one</p><p>one</p><p>one</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize()

      render_click(view, "open_find", %{})
      render_change(view, "find_query", %{"find" => "one", "replace" => "two"})
      render_click(view, "replace_all", %{})

      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize() == before
    end

    test "searching for something that is not there says so", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_find", %{})
      render_change(view, "find_query", %{"find" => "zzzz", "replace" => ""})

      assert has_element?(view, "#pb-find-none")
      assert has_element?(view, "#pb-find-replace-all[disabled]")
    end

    # BESIDE TOKENS, because both are things a site defines once and every page then resolves
    # through. A class is only useful if it can reach an element, so Apply appears when something is
    # selected and appends rather than replacing — an element's own utilities are the exceptions to
    # the shared class and have to survive it.
    test "the studio carries a Classes tab that can reach the selection", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})

      assert has_element?(view, "#pb-class-form")
      assert has_element?(view, "#pb-classes-empty")

      render_submit(view, "save_class", %{"name" => "card-shell", "utilities" => "rounded-xl p-6"})

      assert has_element?(view, "#pb-class-card-shell")
      refute has_element?(view, "#pb-classes-empty")

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "apply_class", %{"name" => "card-shell"})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(h1.id)
             |> Tree.Node.attr_text("class") =~ "card-shell"
    end

    # AND A CLASS IS NOT ALWAYS A STRING TO APPEND TO. Apply read the attribute as text and wrote
    # the whole row back as one — so on `class={[@variant, "lead"]}` it put the expression's own
    # source on the element as literal words, which is not Elixir: the page stopped compiling and
    # could not be saved. The class joins the expression instead, and the computed value stays so.
    test "and a class applied over a computed one joins it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})
      render_submit(view, "save_class", %{"name" => "brand-card", "utilities" => "rounded-xl"})

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => ~S|[@variant, "lead"]|,
        "value_kind" => "expr"
      })

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "apply_class", %{"name" => "brand-card"})

      tree = view |> editor() |> Map.fetch!(:tree)

      assert Tree.classes(Tree.get(tree, h1.id)) == ["lead", "brand-card"]
      assert attr_of(view, h1.id, "class") == {:expr, ~S|[@variant, "lead", "brand-card"]|}
      assert CodeCheck.template(Serializer.serialize(tree)) == :ok
    end

    test "a name that is not a CSS class is refused with a message", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})
      render_submit(view, "save_class", %{"name" => "Not A Class", "utilities" => "p-6"})

      assert has_element?(view, "#pb-class-error")
      assert render(view) =~ "lowercase letters, digits and dashes"
      refute has_element?(view, "#pb-class-Not A Class")
    end

    # A TYPO IN THIS BOX USED TO FREEZE THE SITE'S STYLESHEET. `@apply rounde-xl` is a non-zero exit
    # from Tailwind, and every later compile reads the same stored row again — so the row is proved
    # before it is stored, and what comes back is Tailwind's own sentence about it, under the field
    # that still holds what was typed.
    test "a utility Tailwind does not know is refused under the field", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})
      render_submit(view, "save_class", %{"name" => "card", "utilities" => "rounde-xl"})

      assert has_element?(view, "#pb-class-error")
      assert render(view) =~ "rounde-xl"
      refute has_element?(view, "#pb-class-card")
      assert has_element?(view, "#pb-classes-empty")
      assert has_element?(view, ~s|#pb-class-utilities[value="rounde-xl"]|)

      render_submit(view, "save_class", %{"name" => "card", "utilities" => "rounded-xl"})

      assert has_element?(view, "#pb-class-card")
      refute has_element?(view, "#pb-class-error")
    end

    # THE KIT ALREADY SAYS WHERE ITS DOCS ARE. All 136 Chelekom components carry a `doc_url` and
    # nothing read it, so someone stuck on what `variant` means had the answer in the database with
    # no way to reach it.
    test "a component's docs are one click from its properties", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "documented",
        template: ~s|<div class="p-4">hi</div>|,
        extra: %{"doc_url" => "https://mishka.tools/chelekom/docs/alert"}
      )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-documented") |> render_click()
      render_click(canvas, "select", %{})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # SELECTING ON THE CANVAS, not in the panel. A panel selection is navigation and leaves the
      # left tab where the reader put it; a canvas click means "work on this", which is what swings
      # the panel to the Inspector the link lives in.
      render_click(canvas, "select", %{"id" => node.id})

      assert has_element?(
               view,
               ~s(#pb-docs-link[href="https://mishka.tools/chelekom/docs/alert"])
             )

      assert has_element?(view, ~s(#pb-docs-link[target="_blank"][rel="noopener noreferrer"]))
    end

    # A `javascript:` in a link the ADMIN renders is the one way a third-party kit's bundle could
    # reach into this page, so only an http(s) address is offered.
    test "a doc_url that is not a web address is not offered", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "sneaky",
        template: ~s|<div>x</div>|,
        extra: %{"doc_url" => "javascript:alert(1)"}
      )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-sneaky") |> render_click()
      render_click(canvas, "select", %{})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # SELECTING ON THE CANVAS, not in the panel. A panel selection is navigation and leaves the
      # left tab where the reader put it; a canvas click means "work on this", which is what swings
      # the panel to the Inspector the link lives in.
      render_click(canvas, "select", %{"id" => node.id})

      refute has_element?(view, "#pb-docs-link")
    end

    # Clicking a row has to move the ring on the CANVAS, which is a different LiveView. The push that
    # carries it compared the new selection against itself, so it never fired.
    test "selecting in the layers rail reaches the canvas", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      assert_push_event(canvas, "pb:selected", %{id: id})
      assert id == h1.id
    end

    # The prototype uses THREE active treatments and they are not interchangeable: a scope filter is
    # violet-tinted, a category pill is solid dark, a segmented tab is white-on-track. Getting one
    # wrong looks like a typo and reads as a different control, so each is pinned here.
    # OUT OF THE BOX THE STUDIO ANSWERS FROM THIS SERVER. It used to default to the design
    # prototype's sample catalogue, which meant invented packages with prices beside an Install that
    # refuses, and invented presets beside an Apply that only flashes. `Kits` is real: its tokens are
    # the site's own stylesheet declarations and its packages are the kit components on disk this
    # site has not installed.
    test "the marketplace answers from this server unless a host swaps it", %{
      conn: conn,
      page: page
    } do
      assert MishkaCmsCore.Runtime.PageBuilder.Marketplace.adapter() ==
               MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      # The sample-catalogue banner is keyed on the adapter, so it goes with it.
      refute has_element?(view, "#pb-sample-catalogue")

      render_click(view, "studio_tab", %{"tab" => "presets"})
      assert has_element?(view, "#pb-presets-empty")
      refute render(view) =~ "SaaS Landing", "the prototype's invented presets must not ship"
    end

    test "active chips use the prototype's own three treatments", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-studio") |> render_click()
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-presets") |> render_click()
      _presets = render_async(view, 5_000)

      # Scope filter — violet tint.
      scope = view |> element("#pb-studio-scope-all") |> render()
      assert scope =~ "bg-[#f2f1fc]"
      assert scope =~ "text-[#4f4bcc]"

      # Category pill — solid dark.
      category = view |> element("#pb-preset-cat-all") |> render()
      assert category =~ "bg-[#17161a]"
      assert category =~ "text-white"

      # Segmented tab — white on its track.
      tab = view |> element("#pb-studio-presets") |> render()
      assert tab =~ "bg-white"
      assert tab =~ "text-[#1b1a18]"
    end

    # Reloading the frame is how you pick up a component recompiled in another tab. It must not reload
    # the EDITOR, and it must ask first when there is work that is not in a draft yet.
    test "reloading the canvas is silent with nothing unsaved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-reload") |> render_click()

      refute has_element?(view, "#pb-reload-modal")
    end

    test "reloading with unsaved work asks first", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      # In DRAFT mode the change is written as it is made, so a reload has nothing to lose.
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      _written = render_async(view)
      view |> element("#pb-reload") |> render_click()
      refute has_element?(view, "#pb-reload-modal")

      # Publish mode writes nothing, which is exactly when the question is worth asking.
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "op", %{
        "kind" => "delete",
        "node_id" => node_with_tag(view, "p").id
      })

      view |> element("#pb-reload") |> render_click()
      assert has_element?(view, "#pb-reload-modal")

      view |> element("#pb-reload-cancel") |> render_click()
      refute has_element?(view, "#pb-reload-modal")

      # And the confirm goes through, leaving the document exactly as it was.
      view |> element("#pb-reload") |> render_click()
      view |> element("#pb-reload-confirm") |> render_click()

      refute has_element?(view, "#pb-reload-modal")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.all?(&(&1.tag != "h1"))
    end

    # PRESSING SAVE IS NOT THE AUTOMATIC WRITE. The automatic one stays out of publish mode; asking
    # for the work to be kept is honoured wherever the stage happens to be pointing.
    test "Save keeps a draft even in publish mode", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "op", %{
        "kind" => "delete",
        "node_id" => node_with_tag(view, "h1").id
      })

      assert view |> editor() |> Map.fetch!(:dirty?), "publish mode writes nothing on its own"

      save!(view)
      _written = render_async(view)

      refute view |> editor() |> Map.fetch!(:dirty?)
      assert is_binary(editor(view).draft_id)
    end

    test "Save draft first saves, then reloads", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      # The modal only appears when there IS unsaved work, which is publish mode.
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      view |> element("#pb-reload") |> render_click()
      view |> element("#pb-reload-save") |> render_click()
      _written = render_async(view)

      refute has_element?(view, "#pb-reload-modal")
      refute view |> editor() |> Map.fetch!(:dirty?)
    end

    # LEAVING IS THE OTHER WAY TO LOSE PUBLISH-MODE WORK, and the only one that cannot be asked
    # about twice — a closed tab is final. The chrome carries a flag the browser reads to decide
    # whether to object at all; the server decides again when the click arrives, because the
    # attribute is one patch behind a change made in the same breath.
    test "the leave guard is armed only by unsaved work in publish mode", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s(#pb-leave-guard[data-armed="false"]))

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      _written = render_async(view)

      assert has_element?(view, ~s(#pb-leave-guard[data-armed="false"])),
             "draft mode writes as you work, so there is nothing to lose by leaving"

      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})

      assert has_element?(view, ~s(#pb-leave-guard[data-armed="true"]))
    end

    test "leaving with nothing at stake just goes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})

      # Nothing to ask about, so the editor is already gone rather than holding a modal.
      assert_redirect(view, "/admin/dashboard/runtime/pages")
    end

    test "leaving publish mode with changes asks, and Stay keeps you here", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      assert has_element?(view, "#pb-leave-modal")

      view |> element("#pb-leave-stay") |> render_click()

      refute has_element?(view, "#pb-leave-modal")
      assert view |> editor() |> Map.fetch!(:dirty?), "staying keeps the work in the session"
      assert Drafts.list("page", page, actor(view)) == [], "and writes nothing behind your back"
    end

    test "Leave anyway goes without writing anything", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-go") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")
      assert Drafts.list("page", page, recorded) == []
    end

    # CHOOSING PUBLISH IS NOT PUBLISHING, and the difference is invisible until something is typed —
    # from that moment the editor silently stops keeping work. It says so once, when the choice is
    # made, rather than leaving the author to discover it by losing something.
    test "choosing a stage says what it just changed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      # Publish mode saves nothing to the page, but it is no longer true that nothing is kept: the
      # change still reaches the record of who did what, which is the whole point of having one.
      published = render_click(view, "set_stage", %{"stage" => "published"})
      assert published =~ "recorded but not saved to the page"
      assert published =~ "when you press Publish"

      drafted = render_click(view, "set_stage", %{"stage" => "draft"})
      assert drafted =~ "every change is kept as you make it"
    end

    # AND CHOOSING IT LEAVES THE DRAFT ALONE. Publish mode stops writing; it does not undo what was
    # written before the author switched.
    test "choosing publish mode keeps the draft already written", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)
      recorded = actor(view)

      render_click(view, "set_stage", %{"stage" => "published"})

      assert Enum.any?(Drafts.list("page", page, recorded), &(&1.id == draft_id)),
             "switching mode is not a discard"
    end

    test "the leave question offers both ways to keep the work", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})

      assert has_element?(view, "#pb-leave-save")
      assert has_element?(view, "#pb-leave-publish")
      assert has_element?(view, "#pb-leave-stay")
      assert has_element?(view, "#pb-leave-go")
    end

    test "Publish it now puts the page live and then goes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-publish") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")

      live_now =
        MishkaCmsCore.Runtime.Page
        |> Ash.get!(page.id, action: :master_get, authorize?: false)

      refute live_now.template =~ "<h1", "the change is on the live page, not in a drawer"
    end

    test "Keep as a draft writes it before going", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-save") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")

      # AND IT IS THE WORK, not an empty row: the h1 that was deleted is gone from what was kept.
      [kept] = Drafts.list("page", page, recorded)
      assert String.starts_with?(kept.label, "Draft · ")
      refute kept.template =~ "<h1"
    end

    # AND IT IS AN ORDINARY DRAFT WRITE, which means an extension gets the same say over it as over
    # every other one. This handler called `Drafts` itself, so the gate never ran for it: a plugin
    # that refuses draft writes was overruled by the one button that writes on the way out, and the
    # author was sent away believing the work was kept.
    test "and a plugin that refuses the write keeps you here with the work", %{
      conn: conn,
      page: page
    } do
      refuse_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      refused = view |> element("#pb-leave-save") |> render_click()

      assert Drafts.list("page", page, recorded) == [], "the gate refused, so nothing was written"
      assert refused =~ "still here with your changes"
      assert view |> editor() |> Map.fetch!(:dirty?), "the work is still the session's to lose"
    end

    # AND THE WRITE IS ANNOUNCED LIKE EVERY OTHER. `builder:draft:after_save` is what a backup or a
    # sync integration hears a draft through; the one made on the way out was never announced, so
    # the drafts nothing downstream knew about were exactly the ones written to rescue work.
    test "and the draft it wrote is announced to the extensions", %{conn: conn, page: page} do
      watch_draft_announcements()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-save") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")
      [kept] = Drafts.list("page", page, recorded)

      assert_receive {MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe, announced}
      assert announced.section == "page"

      assert announced.draft_id == kept.id,
             "the announcement named a row other than the one written"
    end

    # The destination arrives from the browser, so it is checked rather than trusted. A
    # protocol-relative URL is another origin wearing a path's clothes.
    test "a destination that is not a path of this app is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "leaving", %{"to" => "//evil.example.com/admin"})
      render_click(view, "leaving", %{"to" => "https://evil.example.com/admin"})

      refute has_element?(view, "#pb-leave-modal")
      assert render(view) =~ "pb-root"
    end

    # The theme is client state — `<html data-theme>` plus localStorage — so the button carries a hook
    # and BOTH icons, with CSS choosing. A server-rendered icon lagged the real theme and the toggle
    # only ever turned dark on.
    test "the theme toggle owns both icons and flips on the client", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = view |> element("#pb-theme") |> render()
      assert html =~ ~s(phx-hook="PbTheme")
      assert html =~ "[[data-theme=dark]_&amp;]:hidden"
      assert html =~ "[[data-theme=dark]_&amp;]:block"
    end

    test "the crumb bar reports the device and zoom", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert has_element?(view, "[data-role='pb-viewnote']", "Desktop · 100%")

      view |> element("#pb-device-tablet") |> render_click()
      assert has_element?(view, "[data-role='pb-viewnote']", "Tablet · 834px · 100%")
    end

    test "the code editor shows a collapsed strip until it is opened", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-code-strip")
      view |> element("#pb-code-strip") |> render_click()

      refute has_element?(view, "#pb-code-strip")
      assert has_element?(view, "#pb-codetab-html")
    end

    test "the canvas floats a per-element toolbar over the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-el-toolbar"
      assert html =~ "pb-eltb-duplicate"
      assert html =~ "pb-eltb-delete"
      assert html =~ "pb-eltb-ask_ai"
      assert html =~ "pb-eltb-comment"

      # No NODE carries the attribute: the ring is a CSS rule keyed on `data-selected`, and the hook
      # sets it on the click so a selection paints without re-rendering the document.
      assert html =~ ~s([data-node-id][data-selected="true"])
      refute html =~ ~s(data-node-id="#{h1.id}" data-selected="true")

      # And the actions work, through the same validated op funnel as everything else.
      render_click(canvas, "toolbar", %{"action" => "duplicate"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.count(&(&1.tag == "h1")) ==
               2

      render_click(canvas, "toolbar", %{"action" => "delete"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.count(&(&1.tag == "h1")) ==
               1
    end

    # THE TOOLBAR IS AN OPEN REGISTRY AND "NOT DELETE" MEANT "DUPLICATE", so every button an
    # extension contributed inserted a copy of the selected element — undoable, autosaved — and the
    # plugin that put it there was never called. Both halves are asserted here: the plugin hears
    # about the press, and the document does not move.
    test "a contributed toolbar action reaches its plugin instead of duplicating the element", %{
      conn: conn,
      page: page
    } do
      Process.register(self(), ToolbarInvokedProbe.waiter())
      register_plugin(ToolbarProbe, "builder:canvas:toolbar")
      register_plugin(ToolbarInvokedProbe, "builder:canvas:toolbar:invoked")

      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      before = editor(view)

      assert has_element?(canvas, "#pb-eltb-probe-toolbar")

      # THE BUTTON READS AS WHAT THE PLUGIN DECLARED, which is the other half of a contributed action
      # being real: the label and the icon were drawn from the core's own five and a plugin's button
      # came out an unlabelled box, whatever its descriptor said.
      button = canvas |> element("#pb-eltb-probe-toolbar") |> render()

      assert button |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() == "Probe",
             "the descriptor's own label is what the button says, not just its tooltip"

      assert button =~ ~s(data-pb-tb="labelled"), "so it is not squeezed into a 30px glyph box"

      assert button =~ ~s(d="M13 2 4 14h7l-1 8 9-12h-7z"),
             "and the sparkle it named, not the box every key outside the core's five fell back to"

      canvas |> element("#pb-eltb-probe-toolbar") |> render_click()

      assert_receive {ToolbarInvokedProbe,
                      %{action: "probe-toolbar", node_id: node_id, token: token}}

      assert node_id == h1.id
      assert token == token(view)

      assert editor(view).tree == before.tree, "a plugin's button is not a document change"
      assert editor(view).past == before.past, "and it is not an undo step either"
    end

    # A KEY THE REGISTRY NEVER OFFERED can only come from a forged or replayed press — the buttons
    # are drawn from that same list. It used to duplicate the element, which is the loudest possible
    # answer to "I don't know what this is"; the quietest correct one is nothing at all, said in the
    # log. Taking the canvas down instead is the iframe reload loop the catch-all clause avoids.
    test "a toolbar action nothing registered changes nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      before = editor(view)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          render_click(canvas, "toolbar", %{"action" => "not-a-registered"})
        end)

      assert log =~ ~s(no toolbar action is registered as "not-a-registered")
      assert has_element?(canvas, "#pb-el-toolbar"), "and the canvas is still up to draw the bar"
      assert editor(view).tree == before.tree
      assert editor(view).past == before.past
    end

    # `layout` IS one of the registry's five, and the only one the core answers by doing nothing —
    # the panel is client state, so the button pushes no event at all. Left to the clause that hands
    # a key back to the plugin that contributed it, a replayed press would be announced to every
    # plugin as an extension's own action.
    test "a core toolbar key is never announced as a plugin's", %{conn: conn, page: page} do
      Process.register(self(), ToolbarInvokedProbe.waiter())
      register_plugin(ToolbarInvokedProbe, "builder:canvas:toolbar:invoked")

      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      render_click(canvas, "toolbar", %{"action" => "layout"})

      refute_receive {ToolbarInvokedProbe, _summary}
    end

    # THE CHROME COLLECTED THIS REGISTRY TOO, into an assign nothing rendered and from a seed that
    # disagreed with the one on screen — so a plugin ran twice per open and saw two different core
    # sets. The bar is drawn inside the frame, and the frame is now the only thing that asks for it.
    test "only the canvas collects the toolbar registry", %{conn: conn, page: page} do
      Process.register(self(), ToolbarProbe.waiter())
      register_plugin(ToolbarProbe, "builder:canvas:toolbar")

      {:ok, view, _html} = open_builder(conn, page)
      refute_received {ToolbarProbe, :collected}

      {:ok, _canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert_received {ToolbarProbe, :collected}
    end

    # THE BAR NEEDS ROOM ABOVE WHAT IT NAMES. It sits 6px above the selection and never closer than
    # 4px to the top of the frame, so on a 16px stage it was pinned over the top of the document's
    # first element — over the chip or the words a double click was aimed at, in every builder. The
    # layout is what is checkable here; where the hook puts the bar is `placeToolbar`'s.
    test "the stage keeps the toolbar's band clear above the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      chrome = canvas |> element("#pb-canvas-chrome") |> render()

      assert chrome =~
               ~s|#pb-canvas-root[data-preview="false"] { padding-top: calc(4px + 26px + 6px); }|

      assert chrome =~ "html { scroll-padding-top: calc(4px + 26px + 6px); }",
             "a selection scrolled into view has to stop short of the bar the same way"

      view |> element("#pb-preview") |> render_click()

      refute render(canvas) =~ "calc(4px + 26px + 6px)",
             "preview draws no bar, so it keeps no band"
    end

    test "Ask AI and Comment open their rails in the chrome", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_rail", %{"action" => "ask_ai"})
      assert render(view) =~ "Describe a change"

      render_click(view, "open_rail", %{"action" => "comment"})
      assert render(view) =~ "Commenting on"
    end

    # The canvas frame shows the author's own document and nothing else. An empty page still offers
    # somewhere to click, but a page with content does not get a dashed strip appended below it.
    test "the canvas frame adds no chrome below the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "pb-canvas-tail"
      refute html =~ "Drop a component here"
    end
  end

  # The style write path: without these controls the breakpoint tabs and State chips would choose a
  # bucket that nothing ever writes to, which is what the audit found.
  describe "responsive style overrides" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # Layout and Appearance are open on selection — spacing and colour are what people reach for
      # first. The rest still need opening the way a reader would. "Editing at" is not among them any
      # more: the breakpoint is a permanent tab strip now, not a fold.
      for title <- ~w(state behavior attributes) do
        view |> element("#pb-section-#{title}") |> render_click()
      end

      %{view: view, node: section}
    end

    # THE BOX MODEL, AS A CONTROL. Eight edges, each where it is on the element. Before this the panel
    # offered `Padding Y`, `Padding X`, `Padding top` and `Padding bottom` — four of the eight edges
    # missing outright, including `margin-top`, which is the third most-used utility in the whole
    # block library.
    test "the spacing box draws all eight edges", %{view: view} do
      for edge <- ~w(mt mr mb ml pt pr pb pl) do
        assert has_element?(view, "#pb-edge-base-#{edge}"),
               "the spacing box has no cell for #{edge}"
      end
    end

    test "and typing in one writes that edge and nothing else", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px"}}

      view |> element("#pb-edge-form-base-pl") |> render_change(%{"value" => "2rem"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px", "pl" => "2rem"}}
    end

    # THE BOX HAD NO WAY OUT BUT THE KEYBOARD, and that fails in the one way a control must not: you
    # empty the field, the change does not reach the server, and the next render puts the old value
    # back — so it reads as a box that remembers what you deleted. Every other control here has a
    # Reset; this is the box's.
    test "a set edge can be cleared without retyping", %{view: view, node: node} do
      refute has_element?(view, "#pb-edge-clear-base-mt")

      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})

      assert has_element?(view, "#pb-edge-clear-base-mt")

      view |> element("#pb-edge-clear-base-mt") |> render_click()

      assert styles_of(view, node.id) == %{}
      refute has_element?(view, "#pb-edge-clear-base-mt")
    end

    test "and clearing one edge leaves the others alone", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-edge-form-base-pl") |> render_change(%{"value" => "2rem"})

      view |> element("#pb-edge-clear-base-mt") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"pl" => "2rem"}}
    end

    # Emptying the text is still a clear, for anyone who reaches for the keyboard first.
    test "and emptying the field clears it too", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => ""})

      assert styles_of(view, node.id) == %{}
    end

    test "and it reaches the published page", %{view: view, page: page} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "mt-[40px]"
    end

    # An edge is per-breakpoint like every other override, which is the whole point of putting it in
    # the panel rather than in the CSS box: `mt-10` on desktop and `mt-4` on mobile is one element.
    test "an edge belongs to the breakpoint it was set on", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-edge-form-mobile-mt") |> render_change(%{"value" => "12px"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px"}, mobile: %{"mt" => "12px"}}
    end

    # A VALUE THE AUTHOR SET IS NOT AN EXAMPLE. An empty field's placeholder is a made-up hint —
    # "any length, e.g. 2rem" — and a field inheriting from another bucket put the REAL value in the
    # same grey, so an author on Mobile read their own `1000px` as a suggestion and reported the
    # value as missing on reopen.
    test "an inherited value is marked as a value, not as a hint", %{view: view, node: node} do
      view |> element("#pb-style-form-base-width") |> render_change(%{"value" => "1000px"})

      # On base it is the author's own value, in the field itself.
      assert view
             |> element("#pb-style-base-width")
             |> render() =~ ~s(value="1000px")

      view |> element("#pb-bp-mobile") |> render_click()

      mobile = view |> element("#pb-style-mobile-width") |> render()

      assert mobile =~ ~s(placeholder="1000px"), "the inherited value is not offered at all"

      assert mobile =~ ~s(data-inherited="true"),
             "an inherited value is drawn the same as an invented example"

      refute mobile =~ ~s(value="1000px"), "it is not this bucket's own value"

      # And an untouched field still says what a value may look like, without claiming to have one.
      height = view |> element("#pb-style-mobile-height") |> render()
      assert height =~ "any length"
      refute height =~ ~s(data-inherited="true")

      assert styles_of(view, node.id) == %{base: %{"width" => "1000px"}}
    end

    test "the Typography group renders its own controls", %{view: view} do
      html = render(view)

      assert html =~ "Typography"
      assert has_element?(view, "#pb-style-form-base-font-size")
      assert has_element?(view, "#pb-style-form-base-line-height")
      assert has_element?(view, "#pb-style-form-base-letter-spacing")
      assert has_element?(view, "#pb-style-base-font-weight-font-bold")
      assert has_element?(view, "#pb-style-base-text-align-text-center")
      assert has_element?(view, "#pb-style-base-text-transform-uppercase")
    end

    # THE SIZE IS NOT A COLOUR, though Tailwind spells both `text-`. The panel writes the CSS
    # property itself for exactly this reason, and the two have to survive together.
    test "a size and a colour do not overwrite each other", %{view: view, node: node, page: page} do
      view |> element("#pb-style-form-base-font-size") |> render_change(%{"value" => "3rem"})
      view |> element("#pb-style-form-base-color") |> render_change(%{"value" => "#ff0000"})

      assert styles_of(view, node.id) == %{base: %{"font-size" => "3rem", "color" => "#ff0000"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "[font-size:3rem]"
      assert reloaded.template =~ "text-[#ff0000]"
    end

    # A PILL IS NOT A SELECT OF CLASS NAMES. `font-extrabold` and `normal-case` are Tailwind's
    # spelling, not anybody's idea of a choice, so each option carries its own words and is drawn in
    # the thing it names.
    test "an enumerated typographic value offers words, not Tailwind", %{view: view} do
      html = view |> element("#pb-style-base-font-weight-font-extrabold") |> render()

      assert html =~ "Black"
      refute html =~ ">font-extrabold<"

      assert view |> element("#pb-style-base-text-transform-normal-case") |> render() =~
               "As typed"
    end

    test "clicking a weight sets it, and clicking it again clears it", %{view: view, node: node} do
      view |> element("#pb-style-base-font-weight-font-bold") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"font-weight" => "font-bold"}}

      view |> element("#pb-style-base-font-weight-font-bold") |> render_click()

      # The whole bucket goes with the last override in it: an empty `:base` left behind would read
      # as an element that has been styled and reset rather than one nobody touched.
      assert styles_of(view, node.id) == %{}
    end

    test "and so does an alignment and a case", %{view: view, node: node} do
      view |> element("#pb-style-base-text-align-text-center") |> render_click()
      view |> element("#pb-style-base-text-transform-uppercase") |> render_click()

      assert styles_of(view, node.id) ==
               %{base: %{"text-align" => "text-center", "text-transform" => "uppercase"}}
    end

    # A BORDER COLOUR ON ITS OWN PAINTS NOTHING, which is how the panel read before: the control took
    # the colour, the element had no border, and nothing happened.
    test "a border has a width and a style beside its colour", %{view: view, node: node} do
      assert has_element?(view, "#pb-style-form-base-border-width")
      assert has_element?(view, "#pb-style-base-border-style-border-dashed")

      view |> element("#pb-style-form-base-border-width") |> render_change(%{"value" => "2px"})
      view |> element("#pb-style-base-border-style-border-dashed") |> render_click()

      assert styles_of(view, node.id) ==
               %{base: %{"border-width" => "2px", "border-style" => "border-dashed"}}
    end

    test "the column count appears on a grid and not on anything else", %{view: view} do
      refute has_element?(view, "#pb-style-cols-base-3")

      view |> element("#pb-style-pic-base-display-grid") |> render_click()

      assert has_element?(view, "#pb-style-cols-base-3")

      view |> element("#pb-style-pic-base-display-flex") |> render_click()

      refute has_element?(view, "#pb-style-cols-base-3")
    end

    test "and picking one writes Tailwind's own utility", %{view: view, node: node, page: page} do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      view |> element("#pb-style-cols-base-2") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"display" => "grid", "grid-cols" => "2"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      # `grid-cols-[2]` would be `grid-template-columns: 2`, which is not a track list and lays out
      # nothing at all.
      assert reloaded.template =~ "grid-cols-2"
      refute reloaded.template =~ "grid-cols-[2]"
    end

    test "and a track list a count cannot express still goes in", %{view: view, node: node} do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      view |> element("#pb-style-form-base-grid-cols") |> render_change(%{"value" => "2fr 1fr"})

      assert styles_of(view, node.id) == %{base: %{"display" => "grid", "grid-cols" => "2fr 1fr"}}
    end

    # SIX CONTROLS, ONE PROPERTY. `box-shadow` is one string, and offering it as one text box only
    # helps somebody who already knew the answer. Which side it falls on is two numbers.
    test "the shadow editor offers the parts a shadow is made of", %{view: view} do
      for field <- ~w(x y blur spread color) do
        assert has_element?(view, "#pb-shadow-base-#{field}"), "no shadow #{field} control"
      end

      assert has_element?(view, "#pb-shadow-base-inset")
      assert has_element?(view, "#pb-shadow-preset-m")
    end

    test "a preset writes the whole shadow", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-l") |> render_click()

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert shadow =~ "24px"
    end

    # One part at a time, and the other five have to survive it — six ops would be six undo steps for
    # one decision, five of them shadows nobody chose.
    test "and changing one part leaves the others alone", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-l") |> render_click()
      %{base: %{"shadow" => before}} = styles_of(view, node.id)

      view |> element("#pb-shadow-form-base-y") |> render_change(%{"value" => "30px"})

      assert %{base: %{"shadow" => after_edit}} = styles_of(view, node.id)
      assert after_edit =~ "30px"
      assert after_edit =~ "rgba"
      refute after_edit == before
    end

    test "an element with no shadow starts from one worth seeing", %{view: view, node: node} do
      view |> element("#pb-shadow-form-base-y") |> render_change(%{"value" => "8px"})

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert shadow =~ "8px"
      # Not `8px 0 0 0 transparent`: a shadow with no blur and no colour is one you cannot see, so
      # the first nudge would look like a control that does nothing.
      assert shadow =~ "rgba"
    end

    test "and Inside turns it into an inner shadow and back", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-m") |> render_click()
      view |> element("#pb-shadow-base-inset") |> render_click()

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert String.starts_with?(shadow, "inset ")

      view |> element("#pb-shadow-base-inset") |> render_click()

      assert %{base: %{"shadow" => plain}} = styles_of(view, node.id)
      refute plain =~ "inset"
    end

    test "and it reaches the page as a shadow utility", %{view: view, page: page} do
      view |> element("#pb-shadow-preset-s") |> render_click()
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "shadow-[0_1px_2px_0_rgba(15,23,42,0.08)]"
    end

    # A SWATCH ROW OF HARDCODED HEX IS A PALETTE WITH NOTHING TO DO WITH THE SITE. The five here are
    # the editor's own neutrals; the site's real colours were declared in its stylesheet, listed in
    # the Studio one panel away, and unreachable from the control that paints things — so a rebrand
    # meant repainting every element by hand.
    #
    # A token writes `var(--danger-light)`, which is the difference: the element resolves through the
    # same declaration every component on the site resolves through, and changing the token changes
    # them together.
    test "the site's own colours sit beside the editor's", %{conn: conn, page: page} do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "swatch-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n  --danger-light: #de1135;\n  --radius-lg: 12px;\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # FOLDED, BEHIND ITS COUNT. The installed kit theme declares 251 colours — every state of every
      # variant — and a row of them at the neutrals' size is a wall the Background control disappears
      # into. The five that are always open are the editor's own.
      refute has_element?(view, "#pb-token-base-background-danger-light")

      view |> element("#pb-section-site-colours") |> render_click()

      assert has_element?(view, "#pb-token-base-background-danger-light")

      # A length is not a colour. Offering `--radius-lg` as a background is a swatch that draws
      # nothing, which reads as a broken control rather than as an unsuitable token.
      refute has_element?(view, "#pb-token-base-background-radius-lg")

      view |> element("#pb-token-base-background-danger-light") |> render_click()

      assert styles_of(view, section.id) == %{base: %{"background" => "var(--danger-light)"}}
    end

    # AND THE ROW IS A CONVENIENCE, NOT A PRECONDITION. Reading the tokens means reading every
    # stylesheet the site can see and parsing them; done on the mount, a sheet that cannot be read
    # took the whole editor with it — trading something the author needs for something they would
    # merely like.
    test "an unreadable stylesheet costs the swatches, not the session", %{view: view} do
      assert has_element?(view, "#pb-swatch-violet")
      refute has_element?(view, "#pb-section-site-colours")
    end

    # A PICTURE THE AUTHOR PICKS, NOT A PATH THEY REMEMBER. A hero's photograph is a background, so
    # there is no `src` to point the library at — which left it reachable from an `<img>` and not
    # from the element people most want a picture on.
    test "a background can be chosen from the media library", %{view: view} do
      assert has_element?(view, "#pb-background-pick")

      view |> element("#pb-background-pick") |> render_click()

      assert render(view) =~ "Choosing for"
    end

    # The gallery answers with a ROW ACTION rather than a click of ours — the tiles are Gervaz's — so
    # this is the message the sheet really sends.
    test "and a file that is no longer there writes nothing", %{view: view, node: node} do
      view |> element("#pb-background-pick") |> render_click()

      send(view.pid, {:row_action, "use_media", %{"id" => Ecto.UUID.generate()}})

      assert render(view) =~ "no longer in the library"
      assert styles_of(view, node.id) == %{}
    end

    test "the Layout and Appearance groups render", %{view: view} do
      html = render(view)
      assert html =~ "Layout"
      assert html =~ "Appearance"
      assert html =~ "Gap"
      assert html =~ "Background"
    end

    test "a style edit lands in the base bucket and compiles to a class on save", %{
      conn: conn,
      page: page,
      view: view,
      node: node
    } do
      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "20px"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "20px"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "gap-[20px]"
      assert conn
    end

    # Firing `op` directly proves the HANDLER. This proves the CONTROL, which is a different claim:
    # the panel once offered breakpoint and state selectors that chose a bucket no widget ever wrote
    # to, and a handler-level test cannot see a hole like that.
    test "typing in a style field writes the override", %{view: view, node: node} do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}

      # No override marker at base: at Desktop/Normal the value IS the element's value, and the
      # prototype marks a field as overridden only against that baseline.
      refute has_element?(view, "#pb-style-clear-base-gap")

      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})
      assert has_element?(view, "#pb-style-clear-tablet-gap")
    end

    test "the override dot next to a set field clears just that bucket", %{
      view: view,
      node: node
    } do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})

      view |> element("#pb-style-clear-tablet-gap") |> render_click()

      # Only the tablet bucket goes; the base value it was overriding stays.
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}
    end

    # Every property the serialiser can express has to have a control, or the round trip is one-way:
    # a template with `max-w-[60ch]` on it parses into an override the panel cannot show or undo.
    # The claim is narrow and worth pinning: an editing field commits on its own debounce, so nobody
    # has to click away to make a change land. Structurally that means every field lives in a FORM
    # carrying `phx-change` and every input carries `phx-debounce` — a bare `phx-change` on an input
    # outside a form fires nothing at all, which is how these fields were dead once before.
    test "every editing field commits on debounce, with no blur required", %{
      view: view,
      node: node
    } do
      # The shape that makes a debounce commit work at all: the field is inside a form carrying the
      # change event, and the input debounces. A bare `phx-change` on an input outside a form fires
      # nothing — which is exactly how these fields were dead once before.
      assert has_element?(view, ~s(form[phx-change="op"] input[phx-debounce="350"]))

      # Nothing commits on blur any more; that is what forced the click-away.
      refute has_element?(view, "[phx-blur]")

      # And the behaviour itself, through the control rather than the handler: a change with no blur
      # of any kind reaches the tree.
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "27px"})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> then(& &1.meta.styles) == %{base: %{"gap" => "27px"}}
    end

    test "every property the serialiser understands has a control", %{view: view} do
      # Direction, Spread, Align and Wrap are shown only on an element that IS a flex row, and the
      # column count only on one that is a grid — they do nothing to anything else, and an element
      # cannot be both. So the claim is that every property is REACHABLE, not that every property is
      # on screen at once: each is looked for on the display it belongs to.
      # And the axis pair is folded away under the spacing box on an element that sets neither, so it
      # is opened the way a reader opens it. Reachable, again, is the claim.
      view |> element("#pb-section-spacing-by-axis") |> render_click()

      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      as_flex = render(view)

      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      as_grid = render(view)

      for prop <- Styles.properties() do
        assert control_for?(as_flex, prop) or control_for?(as_grid, prop),
               "no control for the #{prop} override"
      end

      # Background has the swatch row on top of its field, the way Gap has its presets.
      assert as_flex =~ "pb-swatch-"
    end

    # A SWATCH IS A PRESET, NOT THE ONLY WAY IN. The field below holds anything, and the swatch it
    # matches lights up — so a background typed by hand still reads as chosen when it is one of the
    # five, and reads as itself when it is not.
    test "the field and the swatches are one control", %{view: view, node: node} do
      view |> element("#pb-swatch-ink") |> render_click()
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="true"]))

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#dadada"})

      assert styles_of(view, node.id) == %{base: %{"background" => "#dadada"}}
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="false"]))
      assert view |> element("#pb-style-base-background") |> render() =~ "#dadada"

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#17161a"})
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="true"]))
    end

    # Every other preset row in the panel clears itself on a second press, and the one that did not
    # was the one whose value could not be reached any other way.
    test "pressing the chosen swatch clears it", %{view: view, node: node} do
      view |> element("#pb-swatch-violet") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"background" => "#4f4bcc"}}

      view |> element("#pb-swatch-violet") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    test "clearing a bucket drops everything written into it and nothing else", %{
      view: view,
      node: node
    } do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})
      view |> element("#pb-style-form-tablet-width") |> render_change(%{"value" => "100%"})

      view |> element("#pb-style-reset") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}
    end

    # A reset that would clear nothing reads as a broken button, so it is not drawn at all.
    test "an untouched bucket offers no reset", %{view: view} do
      refute has_element?(view, "#pb-style-reset")

      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      assert has_element?(view, "#pb-style-reset")
    end

    test "emptying a base field clears it", %{view: view, node: node} do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => ""})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{}
    end

    # Display and its flex-only neighbours are pictures rather than a `<select>` of raw utilities:
    # the value still written is the bare Tailwind class, which is what makes the round trip work.
    test "picking a Layout picture writes the bare Tailwind utility", %{
      conn: conn,
      page: page,
      view: view,
      node: node
    } do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"display" => "grid"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "grid"
      assert conn
    end

    # §3 — the layout vocabulary as pictures. What is pinned is the behaviour a non-technical author
    # depends on, not the markup: one click sets, the same click again clears, and the controls that
    # cannot do anything are not offered.
    test "clicking the chosen picture again clears the override", %{view: view, node: node} do
      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"display" => "flex"}}

      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    test "the flex-only pictures appear only once the element is a row", %{view: view} do
      refute has_element?(view, "#pb-style-pics-base-direction")
      refute has_element?(view, "#pb-style-pics-base-justify")

      view |> element("#pb-style-pic-base-display-flex") |> render_click()

      assert has_element?(view, "#pb-style-pics-base-direction")
      assert has_element?(view, "#pb-style-pics-base-align")
      assert has_element?(view, "#pb-style-pics-base-wrap")

      # …and they go again with the row, rather than lingering as settings with no effect.
      view |> element("#pb-style-pic-base-display-block") |> render_click()
      refute has_element?(view, "#pb-style-pics-base-justify")
    end

    # A row that inherits its display from Desktop is still a row on Mobile. Reading only the open
    # bucket made these four vanish the moment the reader switched breakpoint.
    test "a narrower breakpoint still offers the flex pictures it inherits", %{view: view} do
      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      view |> element("#pb-bp-mobile") |> render_click()

      assert has_element?(view, "#pb-style-pics-mobile-justify")
    end

    test "a gap preset writes the length it is named for", %{view: view, node: node} do
      view |> element("#pb-style-gap-base-L") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"gap" => "16px"}}

      # The field and the presets are one override, so the field shows what the preset wrote…
      assert view |> element("#pb-style-base-gap") |> render() =~ ~s(value="16px")

      # …and pressing the lit preset takes it off.
      view |> element("#pb-style-gap-base-L") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    # §4 — the breakpoint is a tab, and the count on it is how a responsive override stays findable.
    test "each breakpoint tab counts what it sets, and only its own", %{view: view} do
      refute has_element?(view, "#pb-bp-count-base")

      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")
      refute has_element?(view, "#pb-bp-count-mobile")

      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-style-form-mobile-gap") |> render_change(%{"value" => "8px"})
      view |> element("#pb-style-pic-mobile-display-flex") |> render_click()

      assert view |> element("#pb-bp-count-mobile") |> render() =~ ~s(title="2 set here")
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")

      # A STATE SET AT A WIDTH BELONGS TO THAT WIDTH. It used to be counted nowhere — the badge
      # looked only at the plain breakpoint bucket — so a hover colour set on mobile was a change
      # with nothing on screen pointing at it, which is exactly how a responsive edit becomes
      # impossible to find again a week later.
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "4px"})

      assert view |> element("#pb-bp-count-mobile") |> render() =~ ~s(title="3 set here")
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")
    end

    # THE CANVAS GOES WHERE THE PANEL GOES. Choosing Tablet says "I am working on tablet", and
    # leaving the frame at desktop width answers that with a page the override cannot be seen on:
    # the author sets a value, nothing moves, and the control reads as broken when it is the
    # viewport that is wrong.
    test "the breakpoint tab moves the canvas with it", %{view: view} do
      assert device(view) == :desktop

      view |> element("#pb-bp-mobile") |> render_click()
      assert device(view) == :mobile

      view |> element("#pb-bp-tablet") |> render_click()
      assert device(view) == :tablet

      view |> element("#pb-bp-base") |> render_click()
      assert device(view) == :desktop
    end

    # AND IT OPENS WHERE THE SESSION LEFT IT. The breakpoint survives a reload — that is what stops a
    # refresh throwing the panel's place away — but the frame did not, so an editor last used on
    # Mobile came back with the Mobile tab active over a desktop-width canvas. The first click on
    # Mobile then looked broken, because the tab it highlights was already the highlighted one.
    test "and the frame opens where the session left it", %{conn: conn, page: page, view: view} do
      view |> element("#pb-bp-mobile") |> render_click()

      assert device(view) == :mobile

      # A second mount, the way a refresh is: the session hands back the breakpoint it was left on,
      # and the frame has to come with it.
      {:ok, reopened, _html} = open_builder(conn, page)

      assert breakpoint(reopened) == :mobile, "the session did not keep the breakpoint"
      assert device(reopened) == :mobile
    end

    # AND THE OTHER WAY ROUND, which is the half that was missing. The device strip moved the frame
    # and left the breakpoint alone, so the canvas went to 390px while the Inspector kept writing the
    # `base` bucket — an author sizing something on a mobile canvas was setting it for every width.
    test "choosing a frame moves the breakpoint it shows", %{view: view} do
      render_click(view, "set_device", %{"device" => "mobile"})
      assert breakpoint(view) == :mobile

      render_click(view, "set_device", %{"device" => "tablet"})
      assert breakpoint(view) == :tablet

      render_click(view, "set_device", %{"device" => "desktop"})
      assert breakpoint(view) == :base, "the widest frame is what every width looks like"
    end

    # THE SYMPTOM AS REPORTED: the strip lit Mobile over a desktop canvas, so the first press on
    # Mobile did nothing visible — it was already the lit tab. Asserted on the two together, because
    # either one alone is only half the disagreement.
    test "so the lit tab and the canvas never disagree", %{view: view} do
      view |> element("#pb-bp-mobile") |> render_click()
      render_click(view, "set_device", %{"device" => "desktop"})

      assert {:desktop, :base} == {device(view), breakpoint(view)}

      html = render(view)
      assert html =~ ~s(id="pb-bp-base" phx-click="set_breakpoint" value="base" title)
      assert html =~ ~s(aria-pressed="true")

      refute view |> element("#pb-bp-mobile") |> render() =~ ~s(aria-pressed="true"),
             "Mobile stayed lit over a desktop canvas"
    end

    # And the round trip is stable, so neither control can drift the other off by one.
    test "and the two controls round-trip through each other", %{view: view} do
      for {frame, bp} <- [{"mobile", :mobile}, {"tablet", :tablet}, {"desktop", :base}] do
        render_click(view, "set_device", %{"device" => frame})
        assert breakpoint(view) == bp

        view |> element("#pb-bp-#{bp}") |> render_click()
        assert device(view) == String.to_existing_atom(frame)
      end
    end

    # LEAVING side by side is the one path where both controls move at once, and it is the one that
    # took longest to settle on screen — three frames come down and one goes up. Asserted here rather
    # than in the browser, where a probe can read between the two.
    test "and leaving the side-by-side view lands on the frame that was asked for", %{view: view} do
      view |> element("#pb-bp-mobile") |> render_click()
      render_click(view, "set_device", %{"device" => "frames"})

      assert {:frames, :mobile} == {device(view), breakpoint(view)},
             "every width is already on screen, so it moves nothing"

      render_click(view, "set_device", %{"device" => "desktop"})

      assert {:desktop, :base} == {device(view), breakpoint(view)}
    end

    # EXCEPT SIDE BY SIDE, where every width is already on screen and switching to one would take
    # away what the reader opened it for.
    test "but not when the frames view is showing every width at once", %{view: view} do
      render_click(view, "set_device", %{"device" => "frames"})

      view |> element("#pb-bp-mobile") |> render_click()

      assert device(view) == :frames
    end

    # THE BUG THIS MATRIX EXISTS FOR. A hover set while the panel says Mobile must not touch the
    # desktop, and the two must be able to disagree.
    test "a hover set on mobile is a mobile hover", %{view: view, node: node} do
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-hover-gap") |> render_change(%{"value" => "10px"})

      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      assert styles_of(view, node.id) == %{
               hover: %{"gap" => "10px"},
               mobile_hover: %{"gap" => "2px"}
             }
    end

    test "and it reaches the page as a query and a pseudo-class", %{view: view, page: page} do
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "max-[560px]:hover:gap-[2px]"
    end

    # EVERY BUCKET CAN BE CLEARED, not just the plain ones. The button reads the bucket it is
    # clearing, so `mobile :hover` says so rather than offering to clear "mobile".
    test "each bucket offers its own reset, named after itself", %{view: view, node: node} do
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      assert view |> element("#pb-style-reset") |> render() =~ "mobile :hover"

      view |> element("#pb-style-reset") |> render_click()

      assert styles_of(view, node.id) == %{}
    end

    test "a background swatch writes into the current bucket", %{view: view, node: node} do
      view |> element("#pb-swatch-ink") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"background" => "#17161a"}}
    end

    test "the Editing-at and State selectors each explain where an edit lands", %{view: view} do
      assert render(view) =~ "Recorded as the value for every size"

      render_click(view, "set_breakpoint", %{"value" => "tablet"})
      assert render(view) =~ "Recorded against 900px and below"

      render_click(view, "set_pseudo", %{"value" => "hover"})
      html = render(view)
      assert html =~ "Recorded against :hover"
      assert html =~ "Recorded"
    end

    # Each Behavior switch is a class the element either carries or does not, so it reports the
    # document rather than a flag kept beside it — save, reopen, and it is still on.
    test "a Behavior switch adds and removes its classes", %{view: view, node: node} do
      classes = fn ->
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Node.attr_text("class")
      end

      view |> element("#pb-toggle-sticky") |> render_click()
      assert classes.() =~ "sticky"
      assert classes.() =~ "top-0"

      view |> element("#pb-toggle-shadow") |> render_click()
      assert classes.() =~ "shadow-lg"

      view |> element("#pb-toggle-sticky") |> render_click()
      refute classes.() =~ "sticky"
      # Turning one off leaves the other alone.
      assert classes.() =~ "shadow-lg"
    end

    # AND A SWITCH OVER A COMPUTED CLASS JOINS IT. The switch read the row as text and wrote all of
    # it back as one string, so on `class={[@variant, "lead"]}` it put the expression's own source
    # on the element as literal words: not Elixir, and a page that would no longer compile or save.
    test "a switch joins a computed class rather than writing over it", %{view: view, node: node} do
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node.id,
        "name" => "class",
        "value" => ~S|[@variant, "lead"]|,
        "value_kind" => "expr"
      })

      view |> element("#pb-toggle-shadow") |> render_click()

      assert attr_of(view, node.id, "class") == {:expr, ~S|[@variant, "lead", "shadow-lg"]|}
      assert view |> element("#pb-toggle-shadow") |> render() =~ ~s(aria-checked="true")

      assert CodeCheck.template(Serializer.serialize(editor(view).tree)) == :ok

      view |> element("#pb-toggle-shadow") |> render_click()

      assert attr_of(view, node.id, "class") == {:expr, ~S|[@variant, "lead"]|}
    end

    test "a switch reads as on when the element already carries its classes", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section class="sticky top-0 z-10">x</section>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-behavior") |> render_click()

      assert view |> element("#pb-toggle-sticky") |> render() =~ ~s(aria-checked="true")
      assert view |> element("#pb-toggle-shadow") |> render() =~ ~s(aria-checked="false")
    end

    # Listing the attributes a node already has is not the same as being able to give it one; before
    # this the only way to add `aria-label` or a data attribute was the code drawer.
    test "a new attribute can be added by name", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "aria-label", "value" => "Hero"}})
      |> render_submit()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> Node.attr_text("aria-label") ==
               "Hero"
    end

    # EVERY ATTRIBUTE IN THIS LIST USED TO BE A TEXT BOX, including the two a page is most often
    # edited through. A block's `<img src>` was a path to type from memory while the site's media
    # library sat one panel away, and its `<a href>` was a URL with nothing to open it.
    test "a picture's source offers the library, and a link offers to open itself", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "insert",
        "parent_id" => node_with_tag(view, "section").id,
        "template" => ~s(<img src="/uploads/a.png" alt="a" />)
      })

      image = node_with_tag(view, "img")
      render_click(view, "select", %{"id" => image.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-attributes") |> render_click()

      assert has_element?(view, "#pb-attr-row-pick-src")
      refute has_element?(view, "#pb-attr-row-open-src")
    end

    test "and a link offers to open itself where a picture does not", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "insert",
        "parent_id" => node_with_tag(view, "section").id,
        "template" => ~s(<a href="https://example.com">x</a>)
      })

      link = node_with_tag(view, "a")
      render_click(view, "select", %{"id" => link.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-attributes") |> render_click()

      assert has_element?(view, "#pb-attr-row-open-href")
      refute has_element?(view, "#pb-attr-row-pick-href")
    end

    # And the row is still the field it was: the widget decorates it, it does not replace it.
    test "a widget row still writes the attribute", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "data-role", "value" => "hero"}})
      |> render_submit()

      view
      |> element("#pb-attr-row-form-#{node.id}-data-role")
      |> render_change(%{"value" => "banner"})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> Node.attr_text("data-role") == "banner"
    end

    test "adding an attribute with no name changes nothing", %{view: view, node: node} do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "  ", "value" => "x"}})
      |> render_submit()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before
    end

    test "the field written to follows the breakpoint selector", %{view: view, node: node} do
      render_click(view, "set_breakpoint", %{"value" => "mobile"})

      refute has_element?(view, "#pb-style-base-gap")
      view |> element("#pb-style-form-mobile-gap") |> render_change(%{"value" => "6px"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{mobile: %{"gap" => "6px"}}
    end

    test "switching the breakpoint writes into that bucket instead", %{view: view, node: node} do
      render_click(view, "set_breakpoint", %{"value" => "mobile"})

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "mobile",
        "prop" => "py",
        "value" => "14px"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{mobile: %{"py" => "14px"}}
      # Per-field Reset only — the prototype has no group-level one.
      assert has_element?(view, "#pb-style-clear-mobile-py")
    end

    test "a state selector writes into the pseudo bucket", %{view: view, node: node} do
      render_click(view, "set_pseudo", %{"value" => "hover"})

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "hover",
        "prop" => "background",
        "value" => "#17161a"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{hover: %{"background" => "#17161a"}}
    end

    test "Reset clears only that bucket", %{view: view, node: node} do
      for {bucket, value} <- [{"base", "8px"}, {"mobile", "2px"}] do
        render_click(view, "op", %{
          "kind" => "set_style",
          "node_id" => node.id,
          "bucket" => bucket,
          "prop" => "gap",
          "value" => value
        })
      end

      render_click(view, "op", %{
        "kind" => "reset_styles",
        "node_id" => node.id,
        "bucket" => "mobile"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{base: %{"gap" => "8px"}}
    end

    test "clearing a field removes just that property", %{view: view, node: node} do
      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "8px"
      })

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => ""
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{}
    end
  end
end
