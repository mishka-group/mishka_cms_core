# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.InspectorTest do
  @moduledoc """
  The inspector panels, attributes that hold expressions, and layouts, components and error pages.
  """
  use MishkaCmsCore.BuilderLiveCase

  describe "panels" do
    test "switching the left panel to the inspector", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-palette-search")
      refute palette_hidden?(view)

      view |> element("#pb-lefttab-inspector") |> render_click()

      # HIDDEN, NOT REMOVED. The 177 cards stay in the DOM so coming back to the tab costs nothing;
      # what the reader sees is the same either way.
      assert palette_hidden?(view)
      assert render(view) =~ "Select an element on the canvas"
    end

    # STARRING NEVER REACHES THE SERVER. Which four of 177 components one author keeps reaching for
    # is not the site's data, so the star, the two chips and the recent row are the browser's from
    # end to end — the rules are tested in `assets/js/pb_prefs.test.js`. What the server owes them is
    # the handful of hooks and names they read, and that is what this pins: lose `data-name` and the
    # star has nothing to star.
    # WHAT A CARD WILL PUT ON THE PAGE, shown while the pointer rests on it.
    #
    # Everything about showing it is the client's: when to ask, where to put it, when to take it
    # away. The server renders and pushes, and these assert exactly that seam — the panel exists for
    # the hook to find, and the event answers with a document.
    # ENTER IN A STYLE FIELD USED TO RELOAD THE PAGE. A LiveView form with `phx-change` and no
    # `phx-submit` is not intercepted, so the browser applies its implicit-submission rule and does a
    # native GET to the current URL — taking the whole editing session with it.
    test "every style form can be submitted, so Enter never leaves the page", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      forms = ~r/<form[^>]*>/ |> Regex.scan(render(view)) |> List.flatten()
      style_forms = Enum.filter(forms, &(&1 =~ "pb-style-form" or &1 =~ "pb-attr-form"))

      assert style_forms != []
      for form <- style_forms, do: assert(form =~ "phx-submit")
    end

    test "and the search boxes that sit in a form do too", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      for id <- ~w(pb-find-form pb-block-search-form) do
        case Regex.run(~r/<form[^>]*id="#{id}"[^>]*>/, html) do
          nil -> :not_rendered_in_this_state
          [form] -> assert form =~ "phx-submit"
        end
      end
    end

    # A CONTRIBUTED CATEGORY NEEDS A CHIP TO REACH IT BY. The row was built from the core lists, so a
    # block an extension added under its own category could only ever be found under "all" — while
    # showing under every other filter too, because the merge happened after the filtering.
    test "the block category chips include the ones extensions brought", %{conn: conn, page: page} do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: MishkaCmsCore.Test.Plugins.BuilderBlockPlugin,
          event: "builder:blocks",
          extension: :mishka_installer,
          status: :started
        })

      :ok = MishkaInstaller.Event.EventHandler.do_compile("builder:blocks", :start, false)

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(
          :name,
          MishkaCmsCore.Test.Plugins.BuilderBlockPlugin,
          false
        )
      end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      assert has_element?(view, "#pb-blockcat-social-proof")
      assert has_element?(view, "#pb-blockcat-all")
    end

    # PUBLISH MODE KEEPS NOTHING, AND HAS TO SAY SO. Every other mode writes as you work; this one
    # deliberately does not. Silence about that is indistinguishable from a save that is failing.
    test "publish mode says out loud that changes are not being saved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-publish-bar")

      render_click(view, "set_stage", %{"stage" => "published"})
      node = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => node.id})

      assert has_element?(view, "#pb-publish-bar")
      assert has_element?(view, "#pb-publish-keep")
    end

    test "and offers a way to keep the work without publishing it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      node = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => node.id})

      view |> element("#pb-publish-keep") |> render_click()

      refute has_element?(view, "#pb-publish-bar")
    end

    # AND THE OFFER IS KEPT. The bar above is satisfied by a button that only takes the bar down, so
    # it green-lit a handler which cleared the session's `dirty?` first and left `autosave/1` —
    # which returns untouched on a clean session — nothing to write. The draft row is what says the
    # work survived, so the draft row is what this asserts.
    test "and the draft that button offers is really written", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      _written = render_async(view)

      [kept] = Drafts.list("page", page, recorded)
      assert String.starts_with?(kept.label, "Draft · ")
      refute kept.template =~ "<h1", "the draft carries the edit, not the document as it was"

      refute view |> editor() |> Map.fetch!(:dirty?),
             "and the session is clean because the write happened, not before it"
    end

    # THE BAR IS DOWN FOR ONE WRITE, NOT FOR GOOD. It hides behind a flag of its own while the draft
    # it offered is being written; a flag that stayed up would leave every later change in publish
    # mode unannounced, which is the warning this bar exists to make.
    test "and the bar comes back for the next change made in publish mode", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      view |> element("#pb-publish-keep") |> render_click()
      _written = render_async(view)
      refute has_element?(view, "#pb-publish-bar")

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})

      assert has_element?(view, "#pb-publish-bar")
    end

    # A PRESS WITH NOTHING TO KEEP MUST NOT SILENCE THE NEXT WARNING. The button is only drawn while
    # there is work, but what is drawn is one patch behind a change made in the same breath as the
    # click — so the press can arrive with a clean session, and no write starts for the flag to wait
    # on. It is armed off the write it really started, and there was none.
    test "and a press with nothing to keep leaves the warning able to appear", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "keep_as_draft", %{})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      assert has_element?(view, "#pb-publish-bar")
    end

    # A REFUSED WRITE PUTS THE BAR BACK. Taking it down is a claim that the work is kept, so it may
    # only outlive the press if the draft really was written. The editor says so in words too, but
    # the bar is the thing on screen for the rest of the sitting.
    test "and a draft write that fails leaves the bar saying so", %{conn: conn, page: page} do
      refuse_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      settled = render_async(view)

      assert Drafts.list("page", page, recorded) == [], "the gate refused, so nothing was written"
      assert has_element?(view, "#pb-publish-bar")
      assert settled =~ "Autosave is failing"
    end

    # AND NOTHING IS CALLED KEPT THAT WAS NOT WRITTEN. The canvas stays live for the whole round
    # trip — serialize, parse back, format, then the write — so an edit can land while the draft is
    # away being written, and it is not in that draft. Clearing `dirty?` for it anyway left work in
    # no draft at all, with the bar down and the leave prompt silent: the state this button exists
    # to abolish, reached by the button itself.
    test "and an edit made while that draft is being written is not called kept", %{
      conn: conn,
      page: page
    } do
      pause_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      assert_receive {:draft_write_paused, writing}

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
      send(writing, :release)
      _written = render_async(view)

      [kept] = Drafts.list("page", page, recorded)
      assert kept.template =~ "<p", "the write carried the document it serialized, and only that"

      assert view |> editor() |> Map.fetch!(:dirty?),
             "the edit it could not carry is still unkept work"

      assert has_element?(view, "#pb-publish-bar")
    end

    # AND A SECOND PRESS IS NOT SWALLOWED. A press arriving while the first write runs is queued
    # rather than overlapped, and the queue was replayed through `autosave/1` — which refuses
    # publish mode outright, so the retry died where it stood and the ••• menu's "Save draft now"
    # could be pressed all afternoon in publish mode for one row that never moved.
    test "and a press made during that write is written when it finishes", %{
      conn: conn,
      page: page
    } do
      pause_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      assert_receive {:draft_write_paused, first}

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
      render_click(view, "save", %{})
      send(first, :release)

      assert_receive {:draft_write_paused, queued}
      send(queued, :release)
      _written = render_async(view)

      [kept] = Drafts.list("page", page, recorded)
      refute kept.template =~ "<h1"
      refute kept.template =~ "<p", "the queued write carried the document as it had become"

      refute view |> editor() |> Map.fetch!(:dirty?)
      refute has_element?(view, "#pb-publish-bar")
    end

    # ONE SITTING, ONE ROW. The retry reads the draft to update off the socket's copy of the
    # session, and `mark_saved/2` only puts the new `draft_id` on the stored one — so a retry that
    # ran before that copy caught up saw no draft at all and made a second row for the same work.
    test "and a queued write updates the draft the first one made", %{conn: conn, page: page} do
      pause_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      assert_receive {:draft_write_paused, first}
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
      send(first, :release)

      assert_receive {:draft_write_paused, queued}
      send(queued, :release)
      _written = render_async(view)

      assert [_one] = Drafts.list("page", page, recorded)
    end

    # A COMPONENT IS TOLD THE TRUTH TOO. It has no draft resource, so the write this button starts
    # answers `:unsupported` and writes nothing — and the publish-mode sentence, matching first,
    # said the work had been kept anyway.
    test "and a component in publish mode is not told it was kept", %{conn: conn, site: site} do
      component =
        create_component!(
          name: "keepless",
          site_id: site.id,
          template: ~s(<div id="wrap"><h1>Hello</h1></div>)
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _settled = render_async(view)

      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      told = view |> element("#pb-publish-keep") |> render_click()
      assert told =~ "A component has no drafts"
      refute told =~ "Kept as a draft"

      _settled = render_async(view)
      assert has_element?(view, "#pb-publish-bar")
    end

    test "the hover preview panel is there for the hook to drive", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-card-preview[phx-hook='PbPaletteHover'][hidden]")
      assert has_element?(view, "#pb-card-preview [data-role='pb-card-preview-frame']")
      assert has_element?(view, "#pb-card-preview [data-role='pb-card-preview-note']")
    end

    # THE ONE TOKEN THAT MUST NEVER BE THERE. The frame holds a component's own markup, which is
    # authored in the CMS and therefore untrusted; `allow-same-origin` is granted so the panel can
    # read the drawn height and size itself to it, and that is only safe while nothing inside can
    # run. Add `allow-scripts` beside it and the frame can reach straight into the admin session.
    test "and the frame it draws into can never run scripts", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert html =~ ~s|sandbox="allow-same-origin"|
      refute html =~ "allow-scripts"
    end

    test "asking for a preview answers with a document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => "<p>a paragraph</p>"})

      assert_push_event(view, "pb:card-preview", %{template: template, html: html})
      assert template == "<p>a paragraph</p>"
      assert html =~ "<p>a paragraph</p>"
    end

    # A component that needs configuring says so, rather than showing an empty box that reads as a
    # broken component.
    test "and a template that will not render answers with the reason", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => "<p>{@nothing_supplies_this}</p>"})

      assert_push_event(view, "pb:card-preview", %{note: note})
      assert is_binary(note) and note != ""
    end

    test "an empty ask is ignored rather than rendered", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => ""})

      refute_push_event(view, "pb:card-preview", %{})
    end

    test "the palette carries what the star and recent rows need", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "starrable",
        template: ~s|<div class="p-4">hi</div>|
      )

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-palette[phx-hook='PbPalettePrefs'][data-scope]")
      assert has_element?(view, "#pb-palette-fav[data-pb-prefchip='fav']")
      assert has_element?(view, "#pb-palette-recent[data-pb-prefchip='recent']")
      assert has_element?(view, "[data-role='pb-count']")

      # Both empty states ship hidden — the server cannot know whether anything is starred.
      assert has_element?(view, "#pb-palette-empty-fav[hidden]")
      assert has_element?(view, "#pb-palette-empty-recent[hidden]")

      cell = view |> element("[data-role='pb-compcell']") |> render()
      assert cell =~ ~s(data-name=)
      assert cell =~ ~s(data-role="pb-fav")

      # NO `phx-click` ON THE STAR. It sits on top of the tile that places the component; an event
      # here would be a round trip, and a re-render of the tile under the pointer.
      star = view |> element("[data-role='pb-fav']") |> render()
      refute star =~ "phx-click"
    end

    # Clicking an element ON THE CANVAS means "work on this", so the chrome swings to its form. The
    # canvas is a second LiveView, so what reaches this one is the session broadcast — which is what
    # the test drives, origin and all.
    test "a canvas click opens the inspector, a panel selection does not", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      token = view |> editor() |> Map.fetch!(:token)

      {:ok, _session} = EditorSession.select(token, section.id, :panel)
      refute palette_hidden?(view)

      {:ok, _session} = EditorSession.select(token, section.id, :canvas)
      assert palette_hidden?(view)
      assert has_element?(view, "#pb-bp-mobile")
    end

    # The grip drags locally and reports once, so the bounds have to reach the browser: without
    # data-min/data-max the drag would run past the ceiling and then jump back when the server
    # clamped what it was finally told. Same numbers on both sides, from `Panels.resize_bounds/1`.
    test "the resize grips carry the same bounds the server clamps to", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      for {panel, id} <- [left: "#pb-grip-left", right: "#pb-grip-right"] do
        {min, max} = Panels.resize_bounds(panel)

        assert view |> element(id) |> render() =~ ~s(data-min="#{min}")
        assert view |> element(id) |> render() =~ ~s(data-max="#{max}")
      end

      # And the value the grip finally reports is clamped again here, because what arrives is
      # whatever the page chose to send.
      # The server's number is the FALLBACK of a custom property a drag overrides — see
      # `Panels.resize_bounds/1` and the `--pb-*` variables — so that is where the clamp shows up.
      render_click(view, "resize", %{"panel" => "left", "value" => 9_000})
      assert render(view) =~ "var(--pb-left-w, #{elem(Panels.resize_bounds(:left), 1)}px)"

      render_click(view, "resize", %{"panel" => "left", "value" => 10})
      assert render(view) =~ "var(--pb-left-w, #{elem(Panels.resize_bounds(:left), 0)}px)"
    end

    # A slot's properties are drawn from the SAME option lists the parent component's are, and the
    # panel reads `entry.features` unconditionally. Selecting any slot used to raise
    # `KeyError :features` and take the whole editor down with it.
    test "selecting a slot opens its properties instead of crashing", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "has-slots",
        template: "<div>{render_slot(@item)}</div>",
        slots: [
          %{
            "name" => "item",
            "opts" => %{"doc" => "One row"},
            "attrs" => [%{"name" => "color", "type" => "string", "opts" => %{}}]
          }
        ],
        helpers: [
          %{
            "name" => "color_variant",
            "code" => "defp color_variant(_, _), do: nil",
            "discriminators" => [%{"axis" => "color", "values" => ["primary", "danger"]}]
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="has-slots" site="#{site.name}"><:item>hi</:item></.component>),
        "parent_id" => section.id,
        "index" => "0"
      })

      slot = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :slot))
      assert slot, "the dropped component should carry a slot node"

      render_click(view, "select", %{"id" => slot.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      assert html =~ "Color"
      # The parent's option list reached the slot, so this is a picker and not a text box.
      assert html =~ "primary"
    end

    # `:global` is the component's `@rest` catch-all. Offering it wrote a literal `rest=""` into the
    # page and then rendered a control whose own copy said it did nothing.
    test "the property menu never offers the global catch-all", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "with-rest",
        attrs: [
          %{"name" => "title", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="with-rest" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "with-rest")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      html = render(view)

      # The component's own property is on the form…
      assert html =~ "Title"

      # …and its `@rest` catch-all is not a property at all: offering it wrote a literal `rest=""`
      # into the page and then drew a control whose own copy said it did nothing.
      refute html =~ ">Rest<"
      refute has_element?(view, "#pb-extra-rest")
    end

    # An icon attribute's value is a class name the Tailwind heroicons plugin resolves. Fifty-seven
    # of the kit's attributes are one, and every one used to be a text box the author had to type
    # `hero-exclamation-triangle` into from memory — a typo rendering nothing at all.
    test "an icon property offers the catalogue instead of a text box", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "iconed",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{"default" => "hero-check"}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconed" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "iconed")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # Closed, it is a chip naming the default — not an empty text input.
      assert has_element?(view, "#pb-icon-open-#{node.id}-icon")
      refute has_element?(view, "#pb-attr-icon")

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")
      assert has_element?(view, "#pb-icon-hero-academic-cap")

      # The four weights the set actually ships.
      assert has_element?(view, "#pb-icon-variant-outline")
      assert has_element?(view, "#pb-icon-variant-solid")
      assert has_element?(view, "#pb-icon-variant-mini")
      assert has_element?(view, "#pb-icon-variant-micro")

      # Searching narrows it, and the count says how much was left out.
      # THROUGH THE FIELD, which is the only thing that narrows the grid. The trigger is the input:
      # typing sets the attribute and filters the catalogue with the same keystrokes, so there is no
      # search box of its own to drive.
      render_change(view, "icon_typed", %{
        "name" => "icon",
        "node_id" => node.id,
        "value" => "arrow-up"
      })

      assert has_element?(view, "#pb-icon-hero-arrow-up")
      refute has_element?(view, "#pb-icon-hero-academic-cap")

      # Switching weight keeps the query and re-suffixes the results.
      render_click(view, "icon_variant", %{"variant" => "-solid"})
      assert has_element?(view, "#pb-icon-hero-arrow-up-solid")

      # Picking one writes it through the ordinary set_attr op, so it is undoable.
      view |> element("#pb-icon-hero-arrow-up-solid") |> render_click()

      assert Node.attr_text(component_node(view, "iconed"), "icon") == "hero-arrow-up-solid"
      assert view |> editor() |> Map.fetch!(:past) |> hd() |> Map.fetch!(:label) == "Set icon"
    end

    test "the icon picker closes on click-away", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "iconed-two",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconed-two" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "iconed-two")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")

      render_click(view, "close_icon_picker", %{})
      refute has_element?(view, "#pb-icon-picker-icon")
    end

    # BETWEEN A COMPONENT AND A WHOLE-PAGE PRESET there was nothing, so a landing page meant placing
    # a grid, a heading, a paragraph and a button and repeating it for every band down the page.
    test "a section drops in as one block", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-lefttab-blocks") |> render_click()
      assert has_element?(view, "#pb-block-features-four")

      before = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

      view |> element("#pb-block-features-four") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      after_place = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

      assert after_place > before + 20,
             "a four-across feature row is forty-odd nodes, not one"

      # …and it is ONE step, so a section leaves the way it arrived.
      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length() == before
    end

    test "the block list filters by category and by search", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      view |> element("#pb-blockcat-Footer") |> render_click()
      assert has_element?(view, "#pb-block-footer-columns")
      refute has_element?(view, "#pb-block-hero-centred")

      view |> element("#pb-blockcat-all") |> render_click()
      render_change(view, "block_query", %{"value" => "pricing"})

      assert has_element?(view, "#pb-block-pricing-three")
      refute has_element?(view, "#pb-block-hero-centred")
    end

    # Every block is plain HTML and Tailwind on purpose: one reaching for `chelekom-card` would fail
    # on an install without Chelekom, which is the assumption this whole effort has been removing.
    test "blocks depend on no kit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()
      view |> element("#pb-block-hero-centred") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      kinds =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.kind) |> Enum.uniq()

      refute :component in kinds
    end

    # A ROW OF SHAPES, NOT A WORD TO SPELL. A grid's column count was a blank text box whose
    # placeholder was the WORD "twelve", so `4` did nothing and the author had to guess `four`.
    test "a column count is picked by clicking a shape", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "colgrid",
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
      view |> element("#pb-comp-colgrid") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert has_element?(view, "#pb-cols-#{placed.id}-four"),
             "every column count the kit offers is a button"

      refute has_element?(view, "#pb-cols-#{placed.id}-four input"),
             "and none of them is a text field"

      view |> element("#pb-cols-#{placed.id}-four") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Map.fetch!(:attrs)
             |> Map.new()
             |> Map.get("cols") == {:string, "four"}
    end

    # SPACING AND COLOUR ARE WHAT PEOPLE REACH FOR FIRST, and both shipped folded shut — three folds
    # and a scroll below the component's own properties. Nothing said they were there.
    test "Layout and Appearance are open the first time a node is selected", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)

      assert html =~ "Padding", "the Layout controls are on screen without unfolding anything"
      assert has_element?(view, "#pb-swatch-white"), "and so is the background swatch row"
    end

    # PRESSING THE OPEN ONE CLOSES IT. Three toggles here were written as
    # `(open == name && nil) || name`, which yields `name` when they are EQUAL — `nil || name` is
    # `name` — so the picker opened and then would not close by the control that opened it. Only
    # click-away worked, and only click-away was tested.
    test "the icon picker closes when its own field is pressed again", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "iconed-three",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconed-three" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "iconed-three")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      refute has_element?(view, "#pb-icon-picker-icon")
    end

    # Same shape, same bug: choosing the library that is already chosen clears the filter.
    test "choosing the active icon library again clears it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "icon_library", %{"library" => "heroicons"})
      assert :sys.get_state(view.pid).socket.assigns.icon_library == "heroicons"

      render_click(view, "icon_library", %{"library" => "heroicons"})
      assert is_nil(:sys.get_state(view.pid).socket.assigns.icon_library)
    end

    # The examples modal answers "show me one the kit already wrote". The wizard answers the other
    # question — "give me THIS one" — from the component's own option lists.
    test "the wizard composes a component from its options and inserts it", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "wizardly",
        template: "<div class={color_variant(@variant, @kind)}>{render_slot(@inner_block)}</div>",
        attrs: [
          %{"name" => "variant", "type" => "string", "opts" => %{"default" => "default"}},
          %{"name" => "kind", "type" => "string", "opts" => %{"default" => "natural"}}
        ],
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}],
        helpers: [
          %{
            "name" => "color_variant",
            "code" => "defp color_variant(_, _), do: nil",
            # `natural` is in the colour list because a real kit's colour axis contains its own
            # attribute's default — alert's `kind` defaults to `natural` and the axis lists all
            # thirteen. A fixture that leaves it out is testing a shape no kit ships, and the
            # plausibility guard in `pair_leftovers/3` reads exactly that fact to tell a real
            # `color` → `kind` from the generator axis it refuses on `divider`.
            "discriminators" => [
              %{"axis" => "variant", "values" => ["default", "outline"]},
              %{"axis" => "color", "values" => ["natural", "primary", "danger"]}
            ]
          }
        ],
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="wizardly" site="#{site.name}"/>)}
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      assert has_element?(view, "#pb-example-tab-wizard")

      view |> element("#pb-example-tab-wizard") |> render_click()

      # Every axis the component declares, including the colour one whose helper parameter is named
      # `color` while the attribute is `kind`.
      assert has_element?(view, "#pb-wizard-variant-outline")
      assert has_element?(view, "#pb-wizard-kind-danger")

      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "wizard_pick", %{"name" => "kind", "value" => "danger"})

      # The choices reach the SESSION, because the preview is a second LiveView in an iframe.
      assert view |> editor() |> Map.fetch!(:wizard) == %{
               "variant" => "outline",
               "kind" => "danger"
             }

      # The code pane shows exactly what Insert will place.
      html = render(view)
      assert html =~ "variant=&quot;outline&quot;"
      assert html =~ "kind=&quot;danger&quot;"

      render_click(view, "insert_wizard", %{})

      placed = component_node(view, "wizardly")
      assert Node.attr_text(placed, "variant") == "outline"
      assert Node.attr_text(placed, "kind") == "danger"

      # …and it is an ordinary node: on the history, undoable like anything else.
      assert view |> editor() |> Map.fetch!(:past) != []
    end

    # THE CHOICES LIVE IN TWO PLACES, because the preview is a second LiveView: the socket renders
    # the controls and the SESSION is what the iframe can read. Every clearing point cleared one of
    # them, so a variant picked for one component survived the modal that made it — into the next
    # component's wizard, and into a preview still composing from choices nobody could see.
    test "closing the wizard lets go of the choices in both places", %{
      conn: conn,
      page: page,
      site: site
    } do
      wizardly!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})

      assert view |> editor() |> Map.fetch!(:wizard) == %{"variant" => "outline"}

      render_click(view, "close_examples", %{})

      assert view |> editor() |> Map.fetch!(:wizard) == %{},
             "the session kept choices the closed modal made"

      assert :sys.get_state(view.pid).socket.assigns.wizard == %{}
    end

    test "and inserting from it does too", %{conn: conn, page: page, site: site} do
      wizardly!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "insert_wizard", %{})

      assert view |> editor() |> Map.fetch!(:wizard) == %{},
             "the session kept the choices an insert had already spent"
    end

    test "and opening another component's wizard starts from that component", %{
      conn: conn,
      page: page,
      site: site
    } do
      wizardly!(site)
      create_component!(site_id: site.id, name: "plainly", template: "<div>plain</div>")

      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "close_examples", %{})

      show_examples!(view, "plainly")

      assert view |> editor() |> Map.fetch!(:wizard) == %{},
             "one component's picks were carried into another component's wizard"
    end

    # THE PALETTE CARD AND THE WIZARD MUST AGREE. A preset is what a DRAG of this component places,
    # and the wizard opened on the kit's defaults instead — so the preview showed one thing, the
    # card placed another, and "make this the default" saved only what the reader had re-picked,
    # quietly dropping the rest of a preset they never meant to change.
    test "the wizard opens on this component's stored preset", %{
      conn: conn,
      page: page,
      site: site
    } do
      wizardly!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "save_preset", %{})
      render_click(view, "close_examples", %{})

      show_examples!(view, "wizardly")

      assert view |> editor() |> Map.fetch!(:wizard) == %{"variant" => "outline"},
             "the wizard opened on the kit's default while a drag would place the preset"
    end

    defp wizardly!(site) do
      create_component!(
        site_id: site.id,
        name: "wizardly",
        template: "<div class={color_variant(@variant, @kind)}>{render_slot(@inner_block)}</div>",
        attrs: [
          %{"name" => "variant", "type" => "string", "opts" => %{"default" => "default"}},
          %{"name" => "kind", "type" => "string", "opts" => %{"default" => "natural"}}
        ],
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}],
        helpers: [
          %{
            "name" => "color_variant",
            "code" => "defp color_variant(_, _), do: nil",
            "discriminators" => [
              %{"axis" => "variant", "values" => ["default", "outline"]},
              %{"axis" => "color", "values" => ["natural", "primary", "danger"]}
            ]
          }
        ],
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="wizardly" site="#{site.name}"/>)}
          ]
        }
      )
    end

    test "the wizard's preview canvas renders the composed component", %{
      conn: conn,
      page: page,
      site: site
    } do
      # The options are declared on the attributes here rather than mined from a helper: this test is
      # about the preview canvas rendering what the wizard composed, and a helper that fails to
      # compile would fail it for an unrelated reason.
      # The canvas renders a component through its COMPILED module, which a database row alone does
      # not produce inside a test.
      define_component!("previewable", site, "<div>previewed alert</div>")

      create_component!(
        site_id: site.id,
        name: "previewable",
        template: "<div class={@variant}>previewed alert</div>",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "default", "values" => ["default", "outline"]}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}/wizard/previewable")

      assert html =~ "previewed alert"
      refute has_element?(canvas, "#pb-preview-bar")
    end

    # THE WIZARD LIVED BEHIND A DOOR WITH NO HANDLE. The badge that opens this modal was gated on
    # `has_examples?` — a calculation over `extra.examples` / `extra.demo_examples` — and the Wizard
    # tab is inside it. A kit shipping good `attrs` and no `extra` got a perfect palette tile, no
    # badge, and therefore no option pickers, no live preview and no Insert.
    test "a component with options but no examples still gets the badge", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "optiony",
        template: "<div class={@variant}>x</div>",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "default", "values" => ["default", "outline"]}
          }
        ],
        extra: %{}
      )

      {:ok, view, _html} = open_builder(conn, page)

      entry = Enum.find(editor(view).components, &(&1.name == "optiony"))

      refute entry[:has_examples?], "this component deliberately ships no examples"
      assert entry[:offers_options?], "but it does declare an option list"

      assert has_element?(view, "[phx-value-name=optiony][data-role=pb-variantbtn]"),
             "the badge is the only way to reach the Wizard"
    end

    # Landing a reader on an empty Examples tab would be a worse door than the one they could not
    # open before.
    test "a component with only options opens on the Wizard tab", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "wizardonly",
        template: "<div class={@variant}>x</div>",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "default", "values" => ["default", "outline"]}
          }
        ],
        extra: %{}
      )

      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "wizardonly")

      assert :sys.get_state(view.pid).socket.assigns.example_tab == :wizard
    end

    test "a component with examples still opens on Examples", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "exampley",
        template: "<div>x</div>",
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="exampley" site="#{site.name}"/>)}
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "exampley")

      assert :sys.get_state(view.pid).socket.assigns.example_tab == :examples
    end

    test "a component with no option lists gets no wizard tab", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "plainly",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{}}],
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="plainly" site="#{site.name}"/>)}
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "plainly")

      refute has_element?(view, "#pb-example-tab-wizard")
    end

    # A NUMBER WRITTEN AS A STRING IS NOT A NUMBER. The stepper wrote `value="45"` onto an attribute
    # the kit declares `:integer`, which is a type error where Phoenix checks it and arithmetic on a
    # binary where it does not — a progress bar set to 45 drew a bare track and a section drew 0%,
    # so the box looked as though it did nothing. Reported for the linear bar and again for the
    # circular ones; it is every numeric attribute in the kit.
    test "a numeric property is written as an expression, not a string", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "counted",
        attrs: [
          %{"name" => "value", "type" => "integer", "opts" => %{"default" => 0}},
          %{"name" => "label", "type" => "string", "opts" => %{}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="counted" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "counted")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      view
      |> element(~s(form[phx-value-name="value"]))
      |> render_change(%{"value" => "45"})

      assert Node.attr(component_node(view, "counted"), "value") == {:expr, "45"},
             "the number went in as a string, which the component cannot do arithmetic on"

      # AND A STRING PROPERTY IS STILL A STRING. The kind is keyed on the DECLARED type, not on the
      # control, so a text box beside it is untouched.
      view
      |> element(~s(form[phx-value-name="label"]))
      |> render_change(%{"value" => "hello"})

      assert Node.attr(component_node(view, "counted"), "label") == {:string, "hello"}
    end

    # `kind="danger"` matches none of the component's clauses — they are written against the ATOM
    # `:danger` — so it falls through to the catch-all and every colour renders identically. The
    # kit's own examples write `kind={:primary}`; so must the panel.
    test "an atom property is written as an expression, not a string", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "atomic",
        attrs: [
          %{
            "name" => "kind",
            "type" => "atom",
            "opts" => %{"default" => "natural", "values" => ["natural", "danger", "success"]}
          },
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "base", "values" => ["base", "outline"]}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="atomic" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "atomic")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The control offers the bare name but carries the atom form as its value.
      html = render(view)
      assert html =~ ~s(value=":danger")
      assert html =~ ~s(phx-value-value_kind="expr")

      # Driven through the CONTROL, not by pushing the event by hand — three values make this a
      # segmented control, and the pill carries the atom form in its own `value`.
      view
      |> element(~s(button[phx-value-name="kind"][value=":danger"]))
      |> render_click()

      assert Node.attr(component_node(view, "atomic"), "kind") == {:expr, ":danger"}

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize() =~ "kind={:danger}"

      # …and the control marks it chosen, matching the stored `:danger` against the bare label.
      pill =
        render(view)
        |> String.split("<button")
        |> Enum.find(&String.contains?(&1, ~s(value=":danger")))

      assert pill, "the panel should render a pill carrying the atom form"
      assert pill =~ "bg-white"
    end

    test "a string property is still written as a string", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "stringy",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "base", "values" => ["base", "outline"]}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="stringy" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "stringy")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      refute html =~ ~s(value=":outline")
      assert html =~ ~s(value="outline")
    end

    # `kind={:danger}` is a literal like `size={5}` — parsing it is not evaluating it. Refusing atoms
    # meant the attribute never reached the component, so it rendered whatever its catch-all renders
    # and EVERY Chelekom alert came out `natural` whichever colour was chosen — including the kit's
    # own examples, which are written `kind={:primary}`.
    test "an atom expression reaches the component on the canvas", %{
      conn: conn,
      page: page,
      site: site
    } do
      define_component!("atom-canvas", site, "<div>atom canvas</div>")

      create_component!(
        site_id: site.id,
        name: "atom-canvas",
        template: "<div>atom canvas</div>",
        attrs: [%{"name" => "kind", "type" => "atom", "opts" => %{"default" => "natural"}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="atom-canvas" site="#{site.name}" kind={:danger}/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "atom-canvas")
      assert Node.attr(node, "kind") == {:expr, ":danger"}

      # The canvas is a second LiveView; what matters is that it renders the node without dropping
      # the attribute on the way in.
      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "atom canvas"
      refute html =~ "failed to render"
    end

    # A dropdown property could never be changed: `phx-change` on a bare `<select>` outside a form
    # fires no event, so 381 of the kit's attributes — `variant` and `color` among them — were inert
    # while the short ones beside them worked, because a segmented control is a button.
    test "a dropdown property applies to the document", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "droppy",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{
              "default" => "base",
              "values" => ["base", "outline", "shadow", "bordered", "gradient", "filled"]
            }
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="droppy" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "droppy")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # Six values, so this is a dropdown rather than a segmented control.
      assert has_element?(view, ~s(form[phx-value-name="variant"] select))

      view
      |> element(~s(form[phx-value-name="variant"]))
      |> render_change(%{"value" => "outline"})

      assert Node.attr_text(component_node(view, "droppy"), "variant") == "outline"

      # …and clearing it removes the attribute rather than writing an empty string.
      view
      |> element(~s(form[phx-value-name="variant"]))
      |> render_change(%{"value" => ""})

      assert is_nil(Node.attr(component_node(view, "droppy"), "variant"))
    end

    # The site's compiled stylesheet is generated from the classes its own pages RENDER, so a
    # component's DEFAULT icon appears in no page's HTML and has no rule — `chelekom-alert` drew an
    # empty 28px box where its icon belongs. The canvas supplies the rules for the icons in play.
    test "the canvas carries the CSS for the icons it renders", %{
      conn: conn,
      page: page,
      site: site
    } do
      define_component!("iconful", site, "<div>iconful</div>")

      create_component!(
        site_id: site.id,
        name: "iconful",
        template: "<div>iconful</div>",
        attrs: [
          %{"name" => "icon", "type" => "any", "opts" => %{"default" => "hero-bell"}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconful" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # The DEFAULT reaches the stylesheet even though the document never names it…
      assert html =~ "pb-canvas-icons"
      assert html =~ ".hero-bell{"
      assert html =~ "background-color:currentColor"

      # …inside Tailwind's `components` layer, so a size utility on the icon wins over it.
      icons =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#pb-canvas-icons")
        |> LazyHTML.text()
        |> String.trim()

      layered = MishkaCmsCore.Runtime.PageBuilder.Icons.layer_order() <> "\n@layer components{"

      assert String.starts_with?(icons, layered)
      assert String.ends_with?(icons, "}")
    end

    test "an icon set on a node reaches the canvas stylesheet too", %{
      conn: conn,
      page: page,
      site: site
    } do
      define_component!("iconset", site, "<div>iconset</div>")

      create_component!(
        site_id: site.id,
        name: "iconset",
        template: "<div>iconset</div>",
        attrs: [%{"name" => "icon", "type" => "any", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="iconset" site="#{site.name}" icon="hero-rocket-launch"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ".hero-rocket-launch{"
    end

    # Committing on blur meant a change only landed when you clicked somewhere else: typing a title
    # and watching the canvas showed nothing until you clicked away. Every field is a debounced form
    # now — which is also the only shape LiveView delivers `phx-value-*` through.
    test "a text property applies as you type, without leaving the field", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "typey",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="typey" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "typey")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The field is a form with a debounce, not a bare input that waits for blur.
      assert has_element?(view, ~s(form[phx-value-name="title"] input[phx-debounce]))

      view
      |> element(~s(form[phx-value-name="title"]))
      |> render_change(%{"value" => "Heads up"})

      assert Node.attr_text(component_node(view, "typey"), "title") == "Heads up"

      # Clearing it removes the property rather than writing an empty string.
      view
      |> element(~s(form[phx-value-name="title"]))
      |> render_change(%{"value" => ""})

      assert is_nil(Node.attr(component_node(view, "typey"), "title"))
    end

    # A design token is a declaration in the site's own theme stylesheet — `--danger-light: #de1135`
    # — and every component that resolves through it changes at once. That is the one thing the
    # Studio can do that no per-element control can, and it was sample data until now.
    test "the Studio lists the site's real tokens and writes one back", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n  --danger-light: #de1135;\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      html = render(view)

      # The site's OWN token, not the sample set.
      assert html =~ "Danger light"
      assert has_element?(view, "#pb-token-value-danger-light")

      view
      |> element("#pb-token-form-danger-light")
      |> render_change(%{"value" => "#ff0000"})

      assert MishkaCmsCore.Runtime.PageBuilder.Tokens.list(site.id)
             |> Enum.find(&(&1.key == "danger-light"))
             |> Map.fetch!(:value) == "#ff0000"
    end

    test "the swatch is a colour picker, and writing through it sets the token", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content:
              ":root {\n  --pick-full: #de1135;\n  --pick-short: #abc;\n  --pick-oklch: oklch(0.7 0.1 200);\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      # The token table loads in a Task, so the click returns before the rows exist — same reason
      # `open_builder/2` awaits after `live/2`.
      _loaded = render_async(view)

      assert has_element?(
               view,
               ~s(input#pb-token-swatch-pick-full[type="color"][value="#de1135"])
             )

      # `#abc` is `#aabbcc` — a colour input accepts only the six-digit form.
      assert has_element?(
               view,
               ~s(input#pb-token-swatch-pick-short[type="color"][value="#aabbcc"])
             )

      # `oklch(…)` IS a colour token, and a colour input cannot hold one: handing it a value it
      # cannot parse would show black and write black back on the first click. It keeps the plain
      # swatch, and its text field stays the way to edit it.
      refute has_element?(view, "#pb-token-swatch-pick-oklch")
      assert has_element?(view, "#pb-token-value-pick-oklch")

      view
      |> element("#pb-token-swatch-form-pick-full")
      |> render_change(%{"value" => "#00ff00"})

      assert MishkaCmsCore.Runtime.PageBuilder.Tokens.list(site.id)
             |> Enum.find(&(&1.key == "pick-full"))
             |> Map.fetch!(:value) == "#00ff00"
    end

    test "load more grows the list, and editing a token keeps what was loaded", %{
      conn: conn,
      page: page
    } do
      declarations =
        Enum.map_join(1..40, "\n", fn n ->
          "  --bulk-#{String.pad_leading(to_string(n), 2, "0")}: #de11#{String.pad_leading(to_string(n), 2, "0")};"
        end)

      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n#{declarations}\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      assert token_rows(render(view)) == 30

      view |> element("#pb-token-more") |> render_click()
      assert token_rows(render(view)) == 40

      # The reader built that depth by clicking. Writing a token reloads the list — and the reload
      # has to return everything they had, not drop them back to the first page.
      view
      |> element("#pb-token-swatch-form-bulk-01")
      |> render_change(%{"value" => "#00ff00"})

      assert token_rows(render(view)) == 40
    end

    test "a value a stylesheet cannot hold is refused with a reason", %{conn: conn, page: page} do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n  --brand: #0b6f68;\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      html =
        view
        |> element("#pb-token-form-brand")
        |> render_change(%{"value" => "red; } body { display: none"})

      assert html =~ "not a value a stylesheet can hold"
    end

    test "the inspector shows the selected element", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      assert html =~ "section"
      assert html =~ ~s(data-role="pb-bptabs")
      assert html =~ "Attributes"
    end

    # TWO ELEMENTS ANSWERING TO ONE ID. Every palette entry is a worked example and an example names
    # things — the kit's delete dialog ships `id="modal-delete-page"` with `id="btn-delete-cancel"`
    # inside it. Placing one twice, which is how an author builds the second dialog, put both names
    # in the document twice: the second button then opened the FIRST dialog, and LiveView raises
    # trying to patch a container it cannot tell apart.
    test "placing the same snippet twice renumbers the copy and repoints its own wiring", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      snippet =
        ~S|<div id="modal-delete-page">Are you sure?</div>| <>
          ~S|<button id="btn-delete" phx-click={JS.exec("data-pb-open", to: "#modal-delete-page")}>Delete</button>|

      for index <- ["0", "1"] do
        render_click(view, "op", %{
          "kind" => "insert",
          "template" => snippet,
          "parent_id" => section.id,
          "index" => index
        })
      end

      tree = editor(view).tree
      written = for node <- Tree.walk(tree), {:string, id} <- [Node.attr(node, "id")], do: id

      assert Enum.sort(written) == [
               "btn-delete",
               "btn-delete-2",
               # the fixture's own <section id="hero">
               "hero",
               "modal-delete-page",
               "modal-delete-page-2"
             ]

      assert length(Enum.uniq(written)) == length(written), "no id may be claimed twice"

      # And the copy's own button opens the copy, not the dialog that was already there.
      openers =
        for node <- Tree.walk(tree),
            {:expr, source} <- [Node.attr(node, "phx-click")],
            do: source

      assert Enum.sort(openers) == [
               ~S|JS.exec("data-pb-open", to: "#modal-delete-page")|,
               ~S|JS.exec("data-pb-open", to: "#modal-delete-page-2")|
             ]
    end

    # DUPLICATE USED TO ANSWER THIS DIFFERENTLY AND WORSE: it replaced the written id with a random
    # one, so `modal-delete-page` became `phx-F_3nK…` — the author's name for the element thrown
    # away — and nothing rewrote the copy's own button, which went on opening the original.
    test "duplicating keeps the author's name for the element and takes the next number", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~S|<div id="pricing-card"><a href="#pricing-card">anchor</a></div>|,
        "parent_id" => section.id,
        "index" => "0"
      })

      card =
        editor(view).tree
        |> Tree.walk()
        |> Enum.find(&(Node.attr(&1, "id") == {:string, "pricing-card"}))

      render_click(view, "op", %{"kind" => "duplicate", "node_id" => card.id})

      tree = editor(view).tree
      written = for node <- Tree.walk(tree), {:string, id} <- [Node.attr(node, "id")], do: id

      assert Enum.sort(written) == ["hero", "pricing-card", "pricing-card-2"]

      hrefs = for node <- Tree.walk(tree), {:string, href} <- [Node.attr(node, "href")], do: href
      assert Enum.sort(hrefs) == ["#pricing-card", "#pricing-card-2"]
    end

    # A SEARCH BOX WITH NO WAY OUT. Every filtered list in the editor is filtered by a word held on
    # the SERVER, so selecting the text and deleting it is the only way back to the full list — and
    # nothing on the field said so. The ✖ is shown by `peer-placeholder-shown:hidden`, which is a
    # CSS answer to a CSS question: an input is `:placeholder-shown` exactly while it is empty.
    test "every live text field in the editor carries a clear control", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      render_click(view, "set_left_tab", %{"tab" => "blocks"})
      render_click(view, "toggle_command", %{})
      render_click(view, "open_find", %{})

      html = render(view)

      for field <- ~w(pb-palette-search pb-block-search pb-command-input pb-find-input
                      pb-replace-input) do
        assert html =~ ~s(data-for="#{field}"),
               "#{field} has no clear control"
      end

      # Shown by CSS alone, so an empty field never draws one and no round trip reveals it.
      assert html =~ "peer-placeholder-shown:hidden"
    end

    test "clicking the clear control blanks the field the server is filtering by", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      render_click(view, "palette_query", %{"value" => "zzzznothing"})
      assert view |> element("#pb-palette-search") |> render() =~ ~s(value="zzzznothing")

      view |> element(~s([data-for="pb-palette-search"])) |> render_click()

      # The box AND the query behind the list, in one round trip — clearing only the box would leave
      # the list filtered by a word no longer written anywhere.
      assert view |> element("#pb-palette-search") |> render() =~ ~s(value="")
    end

    # AND THE CONTROL MUST NOT FOCUS THE FIELD IT JUST CLEARED. LiveView never overwrites the value
    # of a focused input — `mergeFocusedInput` copies every attribute except `value` — so a
    # `JS.focus` in this chain left the box still reading the old word over a list that had gone back
    # to everything. Measured in a browser; the half-cleared state is invisible to a render test,
    # which is why the command itself is asserted here.
    test "the clear control pushes and does not focus the field", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      command =
        view
        |> element(~s([data-for="pb-palette-search"]))
        |> render()

      assert command =~ ~s([&quot;push&quot;)
      refute command =~ "focus", "focusing the field stops LiveView from clearing it"
    end

    # ONE FORM, TWO FIELDS, ONE HANDLER THAT READS BOTH. Clearing the search term by pushing only
    # `find` would have sent no `replace` at all, and the handler's `params["replace"] || ""` would
    # have thrown away the replacement text sitting in the box beside it.
    test "clearing Find leaves Replace alone, and the other way round", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_find", %{})
      render_click(view, "find_query", %{"find" => "Contact", "replace" => "Reach"})

      view |> element(~s([data-for="pb-find-input"])) |> render_click()

      assert view |> element("#pb-find-input") |> render() =~ ~s(value="")
      assert view |> element("#pb-replace-input") |> render() =~ ~s(value="Reach")

      render_click(view, "find_query", %{"find" => "Contact", "replace" => "Reach"})
      view |> element(~s([data-for="pb-replace-input"])) |> render_click()

      assert view |> element("#pb-find-input") |> render() =~ ~s(value="Contact")
      assert view |> element("#pb-replace-input") |> render() =~ ~s(value="")
    end

    # THE CHIP PROMISED AN EDITOR THAT DID NOT EXIST. An expression on the canvas carries the title
    # "edit its source in the inspector", and the inspector had nothing for one — so `{@inner_content}`
    # in a layout and `{render_slot(@inner_block)}` in a component, the two expressions those
    # documents are built on, could be selected, moved and deleted but changed only through the code
    # drawer.
    test "an expression's source is editable in the inspector", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "shell",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))
      assert expression, "the fixture has to contain an expression"

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})
      assert has_element?(view, "#pb-expr-input-#{expression.id}")

      render_change(view, "op", %{
        "kind" => "set_text",
        "node_id" => expression.id,
        "text" => "@inner_content |> raw()"
      })

      assert Tree.get(editor(view).tree, expression.id).text == "@inner_content |> raw()"
      assert {:ok, heex} = Serializer.to_heex(editor(view).tree)
      assert heex =~ "{@inner_content |> raw()}"
    end

    # A TEXT FIELD WHOSE ONLY GUIDANCE IS A PLACEHOLDER asks the author to remember the names of
    # things this editor already knows. The box stays — what goes in it is Elixir — but beside it now
    # are the names THIS document actually has, read off its own declaration rather than listed here.
    test "and the box offers what the component itself declares", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "offering",
          template: ~s|<div>{@size}</div>|,
          attrs: [%{"name" => "size", "type" => "string"}, %{"name" => "tone", "type" => "atom"}],
          slots: [%{"name" => "inner_block"}, %{"name" => "actions"}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      assert has_element?(view, "#pb-expr-offer-#{expression.id}-size")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-tone")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-actions")

      # A slot is offered as the call that RENDERS it, because naming it is not what anybody wants.
      assert view |> element("#pb-expr-offer-#{expression.id}-inner_block") |> render() =~
               "render_slot(@inner_block)"

      # And the free-text box is still there.
      assert has_element?(view, "#pb-expr-input-#{expression.id}")
    end

    test "and pressing one writes it", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "offering-write",
          template: ~s|<div>{@size}</div>|,
          attrs: [%{"name" => "size", "type" => "string"}],
          slots: [%{"name" => "actions"}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      view |> element("#pb-expr-offer-#{expression.id}-actions") |> render_click()

      assert Tree.get(editor(view).tree, expression.id).text == "render_slot(@actions)"

      # One op, so one undo back to what was typed before.
      render_click(view, "undo", %{})
      assert Tree.get(editor(view).tree, expression.id).text == "@size"
    end

    # READ OFF THE RECORD, so it follows the declaration rather than a list in the editor.
    test "offering nothing for a component that declares nothing", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "offering-nothing",
          template: ~s|<div>{@size}</div>|,
          attrs: [],
          slots: []
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      refute has_element?(view, "#pb-expr-offers-#{expression.id}")
      assert has_element?(view, "#pb-expr-input-#{expression.id}"), "the box is still there"
    end

    # An error page is handed three things on exactly the same footing as a layout's one: the
    # compiler binds `conn`, `status` and `site` before the stored template renders, unconditionally.
    # It was falling into the page's clause — which offers nothing, because a page's assigns come
    # from handlers — so the one section with guaranteed assigns was the one offered none.
    test "an error page offers the three its compiler binds", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          name: "offering-errors",
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => ~s(<div>{@status}</div>)}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      assert has_element?(view, "#pb-expr-offer-#{expression.id}-status")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-conn")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-site")

      # And it stops being told about handlers it cannot hold.
      html = render(view)
      assert html =~ "served by a controller"
      refute html =~ "the page's own handlers"
    end

    # A layout is handed exactly one thing and it is the thing a layout is FOR; a page's assigns come
    # from handlers this editor does not evaluate, so it offers none rather than guessing.
    test "a layout offers the one assign it is handed, and a page offers none", %{
      conn: conn,
      site: site,
      page: page
    } do
      layout =
        create_layout!(
          name: "offering-shell",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      assert has_element?(view, "#pb-expr-offer-#{expression.id}-inner_content")

      {:ok, pages, _html} = open_builder(conn, page)
      on_page = Enum.find(Tree.walk(editor(pages).tree), &(&1.kind == :eex))

      if on_page do
        render_click(pages, "set_left_tab", %{"tab" => "inspector"})
        render_click(pages, "select", %{"id" => on_page.id})
        refute has_element?(pages, "#pb-expr-offers-#{on_page.id}")
      end
    end

    # A `<%= for … do %>` owns everything nested inside it, so a text box would rewrite the block and
    # drop its children. It opens the document's code instead of offering one — on the Template tab,
    # which is where the block is, whichever tab the window was last left on.
    test "a block expression is sent to the code rather than given a box", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><%= for post <- @posts do %><p>x</p><% end %></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      block = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex_block))
      assert block, "the fixture has to contain a block expression"

      render_click(view, "open_source", %{"tab" => "styles"})
      render_click(view, "close_source", %{})

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => block.id})

      assert has_element?(view, "#pb-expr-block-note")
      refute has_element?(view, "#pb-expr-input-#{block.id}")

      view |> element("#pb-expr-block-open-code") |> render_click()

      assert has_element?(view, "#pb-source-modal")
      assert has_element?(view, "#pb-source-copy"), "the Template tab, not the one it was left on"
    end

    # WHAT AN EXPRESSION CAN NAME DEPENDS ON WHAT IS BEING EDITED, and the panel that offers them
    # has to agree: a page is never handed `@inner_content`.
    test "the element library offers the page-content slot only where it exists", %{
      conn: conn,
      site: site,
      page: page
    } do
      layout =
        create_layout!(name: "shell", site_id: site.id, template: ~s(<div>{@inner_content}</div>))

      {:ok, layout_view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      render_click(layout_view, "set_left_tab", %{"tab" => "blocks"})
      assert render(layout_view) =~ "Page content"

      {:ok, page_view, _html} = open_builder(conn, page)
      render_click(page_view, "set_left_tab", %{"tab" => "blocks"})

      page_html = render(page_view)
      refute page_html =~ "Page content"
      # The one that belongs everywhere is still there.
      assert page_html =~ "Any Elixir the document can evaluate"
    end

    # A RUNTIME COMPONENT IS BUILT ON FIRST USE, which is right — a kit of 136 must not compile 136
    # modules to open a page that places five. But the canvas walks the tree NODE BY NODE and blocks
    # on each one in turn: measured cold against the real kit, five components are 623 ms serial and
    # 358 ms asked for together, because `chelekom-button-link` alone is 295 ms of it.
    #
    # So the mount asks for all of them at once. Which components get built does not change, and
    # neither does when they are first needed — only the shape of the wait.
    test "opening the editor compiles the document's components before the canvas asks", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          name: "warm-box",
          site_id: site.id,
          template: ~S|<div class="warm">{render_slot(@inner_block)}</div>|
        )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<div id="root"><.component component_name="warm-box" site="#{site.name}">hi</.component></div>|
        )

      module = Helpers.module_name(component.name, site.name, "Component")
      :code.purge(module)
      :code.delete(module)
      refute Helpers.loaded?(module), "the fixture has to start cold"

      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      # The canvas has never mounted; the module is there because the mount asked for it.
      assert Helpers.loaded?(module),
             "the editor did not warm the components its own document uses"
    end

    test "the layers panel lists the document's elements", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-layers")
      assert render(view) =~ "section"
    end

    test "the audit rail reports a real finding, grouped and scored", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~s(<img src="a.png">),
        "parent_id" => section.id,
        "index" => "0"
      })

      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Image missing alt text"
      assert html =~ "no alt attribute"
      assert html =~ "Accessibility"
      assert html =~ "1 issue"
      # A blocker costs 12, so the ring reads 88 rather than a flat 100.
      assert html =~ "88"
      assert has_element?(view, ~s([data-rule="img-alt"]))
    end

    test "every group is shown even when it passes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      # A group that vanishes when it passes reads as a check that never ran.
      assert html =~ "Accessibility"
      assert html =~ "SEO &amp; Meta"
      assert html =~ "Performance"
      assert html =~ "healthy"
      assert html =~ "Page score"

      # SEO is measured from the page's own fields: this fixture has a description but no social
      # image and a short title, and that is exactly what the rail reports.
      assert html =~ "Open Graph image not set"
      assert html =~ "Add an og:image tag so link previews show a picture."
      refute html =~ "site default"
      assert html =~ "Title is short"
      refute html =~ "Meta description missing"
    end

    # The SEO lines read the record, not the canvas — a page that sets its tags is clean.
    test "a page with its meta tags set passes the SEO checks", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          title: String.duplicate("a", 52),
          description: "A real description for this page.",
          seo_tags: [
            %{tag: "meta", attrs: %{"name" => "description"}, content: "A real description."},
            %{tag: "meta", attrs: %{"property" => "og:image"}, content: "/img/social.png"}
          ],
          template: ~s(<div id="root"><h1>Title</h1></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      refute html =~ "Meta description missing"
      refute html =~ "Open Graph image not set"
      refute html =~ "Title is short"
    end

    # `<title>` reads the page's `title`; its `name` is the key it is filed under.
    test "the title is measured on the page's title, not its name", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          name: String.duplicate("a", 52),
          title: "Short",
          template: ~s(<div id="root"><h1>Title</h1></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Title is short"
    end

    # A layout has no `title` and names no tab, so nothing is asked about one.
    test "a layout is asked nothing about a title", %{conn: conn, site: site} do
      layout =
        create_layout!(site_id: site.id, template: ~s(<div id="shell">{@inner_content}</div>))

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _settled = render_async(view)
      view |> element("#pb-rail-audit") |> render_click()
      html = render(view)

      assert html =~ "SEO &amp; Meta"
      refute html =~ "Title is short"
      refute html =~ "Title is long"
      refute html =~ "Page has no title"
    end

    test "Fix scopes the assistant to the finding's own element", %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_ai_backend, MishkaCmsCore.Test.AiBackendStub)
      MishkaCmsCore.Test.AiBackendStub.answer([])

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :builder_ai_backend)
        Application.delete_env(:mishka_cms_core, :test_ai_answer)
      end)

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~s(<img src="a.png">),
        "parent_id" => section.id,
        "index" => "0"
      })

      view |> element("#pb-rail-audit") |> render_click()
      view |> element(~s([data-rule="img-alt"])) |> render_click()

      html = render(view)
      assert html =~ "Write an alt attribute"
      # The offending node is selected, so the request is scoped to it.
      assert editor(view).selection
      assert has_element?(view, "#pb-ai-form")
    end

    test "a heading that skips a level is reported", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><h1>A</h1><h3>B</h3></div>))
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Heading order skips a level"
      assert html =~ "h1 is followed directly by h3"
    end

    # A field with no form around it renders perfectly and submits nothing, so the rail is the only
    # place the author can find out.
    test "a field with no form around it is a blocker in the Forms group", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>Sign up</h1><input name="email" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Forms"
      assert html =~ "This field is not inside a form"
      assert html =~ "never leaves the page"
      assert has_element?(view, ~s([data-rule="field-no-form"]))
    end

    test "the Forms group is not shown on a page with no form and no field", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Accessibility"
      refute html =~ "Every field is inside a form"
    end

    test "Fix wraps the stray field in a real form, in one undo step", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>Sign up</h1><input name="email" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()
      view |> element(~s([data-rule="field-no-form"])) |> render_click()

      assert [spec] = declared_forms(view)
      assert spec.as == "form"
      assert spec.assign == :form_form
      assert spec.id == "form"
      assert spec.change =~ ~r/^form-[a-z2-7]{5}-validate$/
      assert spec.submit =~ ~r/^form-[a-z2-7]{5}-submit$/
      assert spec.fields == [%{key: :email, type: :string, rules: []}]

      refute render(view) =~ "This field is not inside a form"

      undo!(view)

      assert declared_forms(view) == []
      assert node_with_tag(view, "input")
    end

    test "Fix appends a submit button to a form that has none", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name={f[:email].name} /></.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "This form has no submit button"

      view |> element(~s([data-rule="form-no-submit"])) |> render_click()

      [send] =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.filter(&(&1.tag == "button"))

      assert Node.attr_text(send, "type") == "submit"
      assert Node.attr_text(send, "class") =~ "bg-slate-900"
      assert node_parent(view, send.id) == node_with_tag(view, ".form").id

      refute render(view) =~ "This form has no submit button"
    end

    # A code author's Fix opens the form's On submit in the Code window; the assistant is not asked.
    test "Fix on a form nothing receives opens its On submit for a code author", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name={f[:email].name} /><button type="submit">Send</button></.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Nothing receives this form"

      view |> element(~s([data-rule="form-no-destination"])) |> render_click()

      assert has_element?(view, "#pb-form-handlers")
      assert [%{"name" => "q_submit"}] = fragments(view).events
      refute has_element?(view, "#pb-ai-form")
    end

    # A RULE IS NOT A FINDING. `form-no-destination` fires once per form, so naming the Fix button
    # after the rule alone put two elements with one id in the document as soon as a page had two
    # forms. `document.getElementById` answers whichever came first, so the second row's Fix drove
    # the first row's node.
    test "two forms raising one rule get one Fix button each, with ids of their own", %{
      conn: conn,
      site: site
    } do
      form = fn seed ->
        ~s(<.form :let={f} id="#{seed}-form" as={:#{seed}} for={assigns[:#{seed}_form]} ) <>
          ~s(phx-change="#{seed}_validate" phx-submit="#{seed}_submit">) <>
          ~s(<input name={f[:email].name} /><button type="submit">Send</button></.form>)
      end

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root">) <> form.("one") <> form.("two") <> ~s(</div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      ids =
        view
        |> render()
        |> then(&Regex.scan(~r/id="(pb-audit-fix-form-no-destination[^"]*)"/, &1))
        |> Enum.map(&List.last/1)

      assert length(ids) == 2
      assert length(Enum.uniq(ids)) == 2
    end

    # THE ONE PAGE WHERE THE EDITOR KNOWS BOTH CANDIDATES. Two forms used to send this Fix to the
    # assistant, which from the author's seat is a button that only changes panels.
    test "Fix moves a stray submit button into a form even when the page has two", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /><button type="submit">Send</button></.form><.form :let={g} id="signup-form" as={:signup} for={assigns[:signup_form]} phx-change="signup_validate" phx-submit="signup_submit"><input name={g[:email].name} /><button type="submit">Join</button></.form><button type="submit">Go</button></div>),
          events: [
            %{name: "contact_submit", code: "{:noreply, socket}"},
            %{name: "signup_submit", code: "{:noreply, socket}"}
          ]
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "This submit button is not inside a form"

      stray = view |> tagged("button") |> List.last()
      view |> element(~s([data-rule="submit-no-form"])) |> render_click()

      assert node_parent(view, stray.id) ==
               view |> tagged(".form") |> List.last() |> Map.fetch!(:id)

      refute has_element?(view, "#pb-ai-form")
    end
  end

  describe "an attribute that holds an expression" do
    setup %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~S"""
          <section id="hero">
            <div phx-click={JS.toggle_class("is-open", to: ".pb-1")} :if={assigns[:current_user]} data-role="hero">
              secret
            </div>
          </section>
          """
        )

      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "div")

      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-attributes") |> render_click()

      %{view: view, node: node}
    end

    test "the box offers the source, and the mark says that is what it is", %{view: view} do
      assert field_value(view, "pb-attr-row-phx-click") == @click_source
      assert field_value(view, "pb-attr-row-:if") == @condition_source

      assert has_element?(view, "#pb-attr-row-expr-phx-click")
      assert has_element?(view, ~s([id="pb-attr-row-expr-:if"]))

      # A plain attribute reads as itself and carries no mark.
      assert field_value(view, "pb-attr-row-data-role") == "hero"
      refute has_element?(view, "#pb-attr-row-expr-data-role")
    end

    # STATED, NOT INFERRED. The write says what the box is holding, so what the row does no longer
    # depends on `Op` reading the tree back to guess it.
    test "each row says which kind its write is", %{view: view, node: node} do
      for {name, kind} <- [{"phx-click", "expr"}, {":if", "expr"}, {"data-role", "string"}] do
        assert has_element?(
                 view,
                 ~s(form[id="pb-attr-row-form-#{node.id}-#{name}"][phx-value-value_kind="#{kind}"])
               ),
               "the #{name} row does not state that it writes #{kind}"
      end
    end

    test "a row posted back unchanged leaves the expression as it was", %{view: view, node: node} do
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      assert attr_of(view, node.id, "phx-click") == {:expr, @click_source}

      # Twice, because the braces were cumulative: a second pair is what a second edit used to add.
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      assert attr_of(view, node.id, "phx-click") == {:expr, @click_source}
      assert editor_html(view) =~ ~s(phx-click={#{@click_source}})
    end

    test "and a touched condition is still a condition, not a truthy tuple", %{
      view: view,
      node: node
    } do
      commit_row(view, "pb-attr-row-form-#{node.id}-:if", field_value(view, "pb-attr-row-:if"))

      assert attr_of(view, node.id, ":if") == {:expr, @condition_source}
      assert editor_html(view) =~ ~s(:if={#{@condition_source}})
      refute editor_html(view) =~ "{{"
    end

    test "an edit reaches the expression, not the braces that used to be round it", %{
      view: view,
      node: node
    } do
      # What the author does by hand: click into the row, add a space, blur. Taken from the BOX and
      # not from the source behind it, because what the row offers is the whole of what an edit
      # sends back — braces round it and all, when there were any.
      edited =
        view |> field_value("pb-attr-row-phx-click") |> String.replace(", to:", ",  to:")

      commit_row(view, "pb-attr-row-form-#{node.id}-phx-click", edited)

      assert attr_of(view, node.id, "phx-click") ==
               {:expr, String.replace(@click_source, ", to:", ",  to:")}
    end

    test "what the rows wrote survives serializing and parsing it again", %{
      view: view,
      node: node
    } do
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      commit_row(view, "pb-attr-row-form-#{node.id}-:if", field_value(view, "pb-attr-row-:if"))

      markup = editor_html(view)
      {:ok, reparsed} = Tree.parse(markup)

      assert Serializer.serialize(reparsed) == markup

      again = reparsed |> Tree.walk() |> Enum.find(&(&1.tag == "div"))

      assert Node.attr(again, "phx-click") == {:expr, @click_source}
      assert Node.attr(again, ":if") == {:expr, @condition_source}
    end

    # AND THE PAGE STILL ANSWERS. What the rows store is only half the promise: the other half is the
    # compiler reading that markup back, which is the path a published page is served through. A
    # one-tuple raises there rather than rendering, and a `:if` holding one is truthy whatever it was
    # guarding — so the element a signed-out visitor must not see came back for everyone.
    test "and the markup they leave behind renders the way the page is served", %{
      view: view,
      node: node
    } do
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      commit_row(view, "pb-attr-row-form-#{node.id}-:if", field_value(view, "pb-attr-row-:if"))

      markup = editor_html(view)

      signed_out = LiveViewCompiler.render_template(markup, %{})

      assert is_binary(signed_out),
             "the page no longer renders at all: #{inspect(signed_out, limit: 3)}"

      refute signed_out =~ "secret", "the condition no longer hides what it guards"

      signed_in = LiveViewCompiler.render_template(markup, %{current_user: %{id: "u1"}})

      assert is_binary(signed_in),
             "the page no longer renders for a visitor who is signed in: #{inspect(signed_in, limit: 3)}"

      assert signed_in =~ "secret"
      assert signed_in =~ "toggle_class"
    end

    # THE BOX BESIDE THE LIST COULD DELETE WHAT THE LIST WAS SHOWING. It sends a name and whatever is
    # typed next to it, and an empty value is how every other control in the panel says "take this
    # attribute off" — so typing the name of a row that is already there, with the value box left
    # alone, removed it. On `:if` that publishes to everyone what the condition was keeping back.
    test "a name the element already carries is not added over the top of it", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => ":if", "value" => ""}})
      |> render_submit()

      assert attr_of(view, node.id, ":if") == {:expr, @condition_source}
      assert editor_html(view) =~ ~s(:if={#{@condition_source}})

      signed_out = LiveViewCompiler.render_template(editor_html(view), %{})

      assert is_binary(signed_out)

      refute signed_out =~ "secret",
             "the condition the add box was typed at is no longer guarding"
    end

    # AND NOT WITH A VALUE BESIDE IT EITHER. The row is in the list above the box with its own field;
    # an add reaching the same name is a name typed twice, and taking the second one would throw away
    # what the first holds — on `class` that is everything the style panel wrote.
    test "and a value typed beside a name already in the list does not replace it", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "data-role", "value" => "banner"}})
      |> render_submit()

      assert attr_of(view, node.id, "data-role") == {:string, "hero"}
    end

    # AND THE READER IS TOLD WHERE THE NAME WENT. A refusal that changes nothing on screen is a box
    # that swallowed what was typed into it, so the row holding that name is rung the same way a
    # property row arrived at from the tree is.
    test "the row that already holds the name is rung instead", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "data-role", "value" => ""}})
      |> render_submit()

      assert view
             |> element(~s([id="pb-attr-row-#{node.id}-data-role"]))
             |> render() =~ "bg-[#f7f6ff]"

      refute view
             |> element(~s([id="pb-attr-row-#{node.id}-phx-click"]))
             |> render() =~ "bg-[#f7f6ff]"
    end

    # A HEEX SPECIAL IS NOT A LITERAL. `:if`, `:for` and `:let` must be an expression between braces,
    # and this box only ever writes one of the words typed into it: `:for="item <- @items"` is not a
    # loop, it is a template the compiler refuses outright, so the page stopped rendering at all.
    test "a name HEEx reserves is refused rather than written as a string", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => ":for", "value" => "item <- @items"}})
      |> render_submit()

      assert attr_of(view, node.id, ":for") == nil
      refute editor_html(view) =~ ":for"

      assert is_binary(LiveViewCompiler.render_template(editor_html(view), %{})),
             "the page the add box left behind no longer compiles"
    end

    # And a name it does not carry is still added, with the empty row the author came for: the old
    # write sent `value: ""`, which the funnel read as a removal, so nothing appeared at all.
    test "a name the element does not carry arrives as a row to type into", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "aria-label", "value" => ""}})
      |> render_submit()

      assert attr_of(view, node.id, "aria-label") == {:string, ""}
      assert has_element?(view, "#pb-attr-row-#{node.id}-aria-label")
    end

    # INCLUDING `id`. A component is refused that one because the property list above already offers
    # it; an element declares nothing, its list holds `id` like any other row, and this box is the
    # only place the panel has to give an element one.
    test "and an element with no id can still be given one", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "id", "value" => "hero-copy"}})
      |> render_submit()

      assert attr_of(view, node.id, "id") == {:string, "hero-copy"}
    end
  end

  # THE SAME LIST A SECOND TIME. A component's Advanced disclosure is built from the same rows, for
  # the attributes it never declared and takes through its `@rest` catch-all — so a `phx-*` on a
  # component corrupted exactly the way one on an element did.
  describe "a component attribute that holds an expression" do
    test "the Advanced row keeps the expression it shows", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "with-rest",
        attrs: [
          %{"name" => "title", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="with-rest" site="#{site.name}" phx-click={#{@click_source}}/>),
        "parent_id" => node_with_tag(view, "section").id,
        "index" => "0"
      })

      node = component_node(view, "with-rest")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert field_value(view, "pb-extra-phx-click") == @click_source
      assert has_element?(view, "#pb-extra-expr-phx-click")

      assert has_element?(
               view,
               ~s(form[id="pb-extra-form-#{node.id}-phx-click"][phx-value-value_kind="expr"])
             ),
             "the Advanced row does not state that it writes an expression"

      commit_row(
        view,
        "pb-extra-form-#{node.id}-phx-click",
        field_value(view, "pb-extra-phx-click")
      )

      assert attr_of(view, node.id, "phx-click") == {:expr, @click_source}
      assert editor_html(view) =~ ~s(phx-click={#{@click_source}})
    end
  end

  # THE BOX HAD NO IDEA WHAT THE NODE ALREADY HELD. It is free text, it sends a name and no value,
  # and the write went straight to the session with `value: ""` — past the rule that turns an empty
  # value into a removal, so the empty one landed. A string attribute came back as `color=""`, which
  # beats the component's own default; an expression came back as `:if={}`, which HEEx reads as nil,
  # so the element and everything inside it left the published page while the tree went on showing
  # the node. The comment above the handler said a duplicate name was a no-op; nothing checked.
  describe "the Advanced attribute editor" do
    setup %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "with-advanced",
        template: ~s(<div class={@color} {@rest}>advanced</div>),
        attrs: [
          %{"name" => "color", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      page = create_page!(site_id: site.id, template: @template)
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="with-advanced" site="#{site.name}" color="primary" aria-label="Hero" :if={#{@condition_source}}/>),
        "parent_id" => node_with_tag(view, "section").id,
        "index" => "0"
      })

      node = component_node(view, "with-advanced")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      %{view: view, node: node}
    end

    defp add_extra(view, node, name),
      do: view |> form("#pb-extra-form-#{node.id}", %{"name" => name}) |> render_submit()

    test "a name the node does not carry arrives as a row to type into", %{
      view: view,
      node: node
    } do
      refute has_element?(view, "#pb-extra-data-role")

      add_extra(view, node, "data-role")

      assert has_element?(view, "#pb-extra-data-role")
      assert field_value(view, "pb-extra-data-role") == ""
      assert attr_of(view, node.id, "data-role") == {:string, ""}
    end

    # The name is trimmed on the way in, so the row it lands on is the one the author meant.
    test "and the space around what was typed is not part of the name", %{view: view, node: node} do
      add_extra(view, node, "  data-role  ")

      assert has_element?(view, "#pb-extra-data-role")
      assert attr_of(view, node.id, "data-role") == {:string, ""}
    end

    test "a name already on the node keeps the value it is holding", %{view: view, node: node} do
      add_extra(view, node, "aria-label")

      assert attr_of(view, node.id, "aria-label") == {:string, "Hero"}
      assert field_value(view, "pb-extra-aria-label") == "Hero"
    end

    # AND THE READER IS TOLD WHERE IT WENT. Refusing without changing anything on screen is a box
    # that swallowed what was typed into it, so the row holding that name is rung the same way a
    # property row arrived at from the tree is.
    test "and the row holding it is rung instead", %{view: view, node: node} do
      add_extra(view, node, "aria-label")

      assert view |> element("#pb-extra-row-aria-label") |> render() =~ "bg-[#f7f6ff]"

      add_extra(view, node, "data-role")

      refute view |> element("#pb-extra-row-aria-label") |> render() =~ "bg-[#f7f6ff]"
      assert view |> element("#pb-extra-row-data-role") |> render() =~ "bg-[#f7f6ff]"
    end

    # A HEEX SPECIAL IS NOT A LITERAL. `:if`, `:for` and `:let` must be an expression between braces,
    # and this box has no value to put in one: `:for=""` is not a loop over nothing, it is a template
    # the compiler refuses outright, so the whole page stopped rendering rather than one element.
    test "a name HEEx reserves is refused even when the node does not carry it", %{
      view: view,
      node: node
    } do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)

      add_extra(view, node, ":for")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before

      refute editor_html(view) =~ ":for"
    end

    # `color` is DECLARED, so Advanced never lists it — the author is typing a name with no row on
    # screen to say it is already set, and the panel is the only thing that can know.
    test "a declared property is not blanked by a name Advanced does not list", %{
      view: view,
      node: node
    } do
      add_extra(view, node, "color")

      assert attr_of(view, node.id, "color") == {:string, "primary"}
      refute has_element?(view, "#pb-extra-color")
    end

    # AND THE ELEMENT IS STILL ON THE PAGE. `:if={}` is not a condition that never matches, it is a
    # condition HEEx reads as nil — the element and its subtree are never emitted at all.
    test "an existing condition is not emptied out from under the page", %{
      view: view,
      node: node
    } do
      add_extra(view, node, ":if")

      assert attr_of(view, node.id, ":if") == {:expr, @condition_source}
      assert editor_html(view) =~ ~s(:if={#{@condition_source}})
      refute editor_html(view) =~ ":if={}"
    end

    # AND NOT WHEN IT IS UNSET EITHER. A declared property with nothing written on the node is the
    # component's own default doing its job. `color=""` beats that default, and Advanced would not
    # list the row it had just written — so the component changed on the canvas and nothing on
    # screen said why.
    test "a declared property the node has not set keeps its default", %{view: view, site: site} do
      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="with-advanced" site="#{site.name}"/>),
        "parent_id" => node_with_tag(view, "section").id,
        "index" => "1"
      })

      plain =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(
          &(Node.component_name(&1) == "with-advanced" and is_nil(Node.attr(&1, "color")))
        )

      render_click(view, "select", %{"id" => plain.id})
      add_extra(view, plain, "color")

      assert attr_of(view, plain.id, "color") == nil
      refute has_element?(view, "#pb-extra-color")
    end

    # AND A REFUSAL IS SAID OUT LOUD. The write went straight to the session and threw the answer
    # away, so an op the session declines left the author looking at a box that had done nothing and
    # explained nothing.
    test "a refused write says so rather than leaving the row missing", %{view: view, node: node} do
      render_click(view, "toggle_lock", %{"id" => node.id})

      add_extra(view, node, "data-role")

      assert has_element?(view, "#flash-error")
      assert attr_of(view, node.id, "data-role") == nil
    end

    # The dynamic wrapper's own two attributes are on the node like any other, so the same lookup
    # covers them: blanking `site` is a component that no longer resolves to anything.
    test "the wrapper's own attributes survive being typed at", %{view: view, node: node} do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)

      add_extra(view, node, "site")
      add_extra(view, node, "component_name")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before
    end

    test "typing nothing into the box changes nothing", %{view: view, node: node} do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)

      add_extra(view, node, "   ")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before
    end
  end

  describe "a layout, which is not a page with a header on it" do
    @body_layout ~s(<body class="min-h-screen bg-white"><main>{@inner_content}</main></body>)

    # A LAYOUT'S ROOT IS `<body>` — every one in this CMS opens with the element a page is wrapped in
    # — and a document may hold only one. The canvas is an ordinary document that already has a body,
    # so the parser merged the second one's attributes onto the first and dropped the tag: the node
    # the editor was pointing at was not in the frame at all. It looked right on the first render,
    # because the merge happened; every patch after that discarded the attributes outright.
    test "the root <body> is drawn as a container the frame can actually hold", %{
      conn: conn,
      site: site
    } do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      root = node_with_tag(view, "body")

      assert has_element?(canvas, ~s(div[data-node-id="#{root.id}"])),
             "the layout's root is selectable, draggable and stylable like any other container"

      refute has_element?(canvas, ~s(body[data-node-id="#{root.id}"])),
             "a second <body> is dissolved by the parser, taking the node with it"
    end

    # THE HALF THAT PROVES IT. Standing in for the tag is only worth anything if an edit to the root
    # now shows: the old behaviour recorded the override, wrote it into the saved template, and left
    # the frame exactly as it was — an editor that appears to ignore you.
    test "and recolouring that root reaches the frame", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      root = node_with_tag(view, "body")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => root.id,
        "bucket" => "base",
        "prop" => "background",
        "value" => "#ff0000"
      })

      assert canvas |> element(~s(div[data-node-id="#{root.id}"])) |> render() =~ "bg-[#ff0000]"

      # And the substitution is what the canvas draws, never what the document says.
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "<body"
    end

    # THE ONE THING A LAYOUT IS FOR. Take `@inner_content` out and the layout still compiles, saves
    # and previews — and every page wrapped in it serves this chrome with the page missing. The audit
    # said "0 blockers" over exactly that document.
    test "the audit names a layout that renders no page", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      view |> element("#pb-rail-audit") |> render_click()
      assert render(view) =~ "The page renders inside this layout"

      render_click(view, "op", %{"kind" => "delete", "node_id" => expression_node(view).id})

      html = render(view)
      assert html =~ "This layout renders no page"
      assert html =~ "every page on it loses its content"
    end

    test "a layout whose @inner_content is hidden from visitors is named, and not published",
         %{conn: conn, site: site} do
      template = ~s(<body><main>{@inner_content}</main></body>)
      layout = create_layout!(site_id: site.id, template: template)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "main").id
      })

      view |> element("#pb-rail-audit") |> render_click()
      assert render(view) =~ "@inner_content is inside an element hidden from visitors"

      publish!(view)

      assert flashes(view) =~
               "Not published — @inner_content is inside an element hidden from visitors"

      stored =
        Ash.get!(MishkaCmsCore.Runtime.Layout, layout.id, authorize?: false, tenant: site.id)

      assert stored.template == template
    end

    # A LAYOUT'S HEADINGS ARE HALF AN OUTLINE. Its h1 is the site name and its h3s label the footer;
    # the page's own headings land between them through `@inner_content`, so the `h1 → h3` it reads
    # as on its own is a gap the page fills. Every seeded layout wore the warning.
    test "no heading-order warning over an outline the page completes", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template:
            ~s(<body><h1>Site</h1><main>{@inner_content}</main><footer><h3>More</h3></footer></body>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)

      refute html =~ "Heading order skips a level"

      # And no tick either: "no level is skipped" is a claim about a document this rail is holding
      # half of, so it is withheld in both directions rather than only in the one that stings.
      refute html =~ "Heading order is sound"
      refute html =~ "Page opens at h1"
    end

    # And a page, which is a whole document, keeps it.
    test "while a page still gets one", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><h1>Top</h1><h3>Then</h3></div>))

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Heading order skips a level"
    end

    # Structure is a question only a layout has an answer to, so a page must not grow an empty
    # heading that reads as a check which failed to run.
    test "and says nothing of the kind on a page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-rail-audit") |> render_click()

      refute render(view) =~ "Structure"
    end

    # Publishing is the deliberate "make this live", and this one is already broken — the same
    # promise a required property makes, made by the section instead of by a component.
    test "publishing a layout that renders no page is refused", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      slot = expression_node(view)
      render_click(view, "op", %{"kind" => "delete", "node_id" => slot.id})

      assert publish!(view) =~ "Not published"

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Layout, layout.id, action: :master_get, authorize?: false)

      assert reloaded.template == @body_layout, "the live layout is untouched"
    end

    # The chip whose whole job is to say which document a save lands on called every one of them a
    # page, because the words were written into the markup.
    test "the stage chip names the layout rather than a page", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, _view, html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert html =~ "Live layout"
      refute html =~ "Live page"
    end
  end

  describe "what the canvas shows a run of text" do
    # `&copy;` is what a footer is written with, and a layout's footer is where it lives. Interpolated
    # it renders `&amp;copy;`, so the author read the six letters they typed while the published page
    # and the shareable preview both showed ©.
    test "a character reference is drawn as the character it names", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>&copy; 2026 &mdash; Mishka</p>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      paragraph = canvas |> element(~s(p[data-node-id])) |> render()

      assert paragraph =~ "© 2026 — Mishka"
      refute paragraph =~ "&amp;copy;", "the reference was shown as its own six letters"

      # And the document is untouched by any of that — the substitution is what the frame draws.
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~
               "&copy; 2026 &mdash; Mishka"
    end

    # THE BOX SAYS `plaintext-only` AND MEANT IT NOWHERE. The hook pushes `textContent`, so the three
    # characters that mean something to HTML arrived as the characters typed and went into the
    # template as markup: typing `<b>bold</b>` put a real element in the document, and the same
    # keystrokes could have put a `<script>` on a published page.
    test "typing stays text, whatever is typed", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>original</p>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(canvas, "set_text", %{"id" => text.id, "text" => "Fish & Chips <b>bold</b>"})

      saved = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()

      assert saved =~ "Fish &amp; Chips &lt;b&gt;bold&lt;/b&gt;"
      refute saved =~ "<b>", "typed characters became an element in the document"

      # And it comes back to the author as what they typed rather than as markup: the run is still one
      # text node, and no `<b>` was ever built from it.
      assert render(canvas) =~ "Fish &amp; Chips &lt;b&gt;bold&lt;/b&gt;"
      refute has_element?(canvas, ~s(span[data-kind="text"] b))
    end
  end

  describe "the controls a node can actually take" do
    # `{@inner_content}` is the one node every layout has and the first thing anyone clicks. The
    # Inspector offered it breakpoints, states, spacing, typography and the whole Appearance section
    # — and the serializer emits an expression verbatim, with nowhere to put a class, so every one of
    # those controls recorded an override that was dropped on the way out.
    test "an expression is not offered styling that would be dropped", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~s(<main class="wrap">{@inner_content}</main>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      render_click(view, "select", %{"id" => expression_node(view).id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, ~s([data-role="pb-bptabs"]))
      assert has_element?(view, "#pb-not-styleable")
      assert has_element?(view, "#pb-select-parent"), "and it says where the styling does belong"
    end

    test "nor is a run of text", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>words</p>))

      {:ok, view, _html} = open_builder(conn, page)

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(view, "select", %{"id" => text.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      assert has_element?(view, "#pb-not-styleable")
      assert render(view) =~ "double-click it on the canvas"
    end

    # A `<style>` renders nothing a visitor sees, so the style surface would record overrides for an
    # element that shows none of them. It is offered its attributes, the nonce it is saved with and
    # a way to where its rules belong instead.
    test "a style block is offered its attributes and where its rules belong", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<div><style>.x { color: red; }</style></div>))

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "style").id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, ~s([data-role="pb-bptabs"]))
      assert has_element?(view, "#pb-not-styleable")
      assert has_element?(view, "#pb-style-nonce-note")

      assert has_element?(
               view,
               ~s(#pb-raw-block-home[href="/admin/dashboard/runtime/stylesheets"])
             )

      refute has_element?(view, "#pb-css-toggle"), "it has no CSS box of its own"
      refute has_element?(view, "#pb-act-toggle"), "nothing to click"
      refute has_element?(view, "#pb-hook-toggle"), "nothing to hook"
      assert has_element?(view, "#pb-when-toggle"), "whether it renders is still a condition"
    end

    test "a script block points at JS hooks and is promised no nonce", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~S|<div><script>console.log(1)</script></div>|)

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "script").id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert has_element?(view, "#pb-not-styleable")
      refute has_element?(view, "#pb-style-nonce-note")
      assert has_element?(view, ~s(#pb-raw-block-home[href="/admin/dashboard/runtime/js-hooks"]))
    end

    # The element it sits in still gets everything, which is the half that proves the gate is about
    # the node rather than about the panel.
    test "the element around it still gets the whole surface", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>words</p>))

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, "#pb-not-styleable")
    end
  end

  describe "the other three sections" do
    test "a layout opens and saves through its own attribute", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~s(<main><p>Layout body</p>{@inner_content}</main>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert node_with_tag(view, "main")

      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => p.id,
        "name" => "class",
        "value" => "lead"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Layout, layout.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="lead")
    end

    test "a component opens and saves through its own attribute", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "editable-box",
          template: ~s(<div class="box"><span>Inside</span></div>)
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert has_element?(view, "#pb-root")
      assert view |> editor() |> Map.fetch!(:section) == "component"

      span = node_with_tag(view, "span")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => span.id,
        "name" => "class",
        "value" => "inner"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Component, component.id,
          action: :master_get,
          authorize?: false
        )

      assert reloaded.template =~ ~s(class="inner")
      assert reloaded.template =~ "Inside"
    end

    # An error page stores a LIST of per-status templates and has no `template` attribute at all, so
    # this is the section that would break if the editor assumed one document per record.
    test "an error page edits one status and writes it back into the list", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      # It opens on the 404 entry — the document itself lives in the canvas iframe, so the session
      # tree is where to look — and offers both statuses.
      assert editor_html(view) =~ "Not found"
      assert has_element?(view, "#pb-status-404")
      assert has_element?(view, "#pb-status-500")

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => hd(h1.children),
        "text" => "Missing"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      # Ash hands typed map entries back atom-keyed even when they were written with string keys.
      by_status =
        Map.new(reloaded.error_pages, fn entry ->
          {entry["status"] || entry[:status], entry["template"] || entry[:template]}
        end)

      assert by_status[404] =~ "Missing"
      # The other status must be untouched — saving one entry cannot clobber the list.
      assert by_status[500] =~ "Boom"
    end

    test "an error page can be opened directly on another status", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      assert editor_html(view) =~ "Boom"
      refute editor_html(view) =~ "Not found"
    end

    # The page an offline site shows is an entry of its own, beside the codes, addressed as
    # `?status=offline`. Read as a number, that address opened the 404 and published over it.
    test "the offline page opens on its own tab and publishes into its own entry", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => "offline", "template" => "<h1>Soon</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=offline")

      assert editor_html(view) =~ "Soon"
      refute editor_html(view) =~ "Not found"
      assert has_element?(view, "#pb-status-offline")

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => hd(h1.children),
        "text" => "Back later"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      by_status = Map.new(reloaded.error_pages, &{&1.status, &1.template})

      assert by_status[:offline] =~ "Back later"
      assert by_status[404] =~ "Not found"
    end

    # SWITCHING STATUS IS NOT OPENING ONE FRESH, and that is the whole difference. The tab strip is a
    # `navigate` link, so pressing 500 remounts — and a remount RESUMES the session this actor already
    # has open on this document, which is what stops a reload throwing work away. The session is keyed
    # on section, record and actor, so the status was not part of what it is a session FOR: the strip
    # lit 500, `@status` became 500, and the tree stayed the 404 one.
    test "and switching status inside an open session changes the document", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, first, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=404")

      assert editor_html(first) =~ "Not found"

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      assert editor_html(second) =~ "Boom"

      refute editor_html(second) =~ "Not found",
             "the strip said 500 and the canvas was still showing 404"
    end

    # SEO IS ADVICE ABOUT FIELDS THE RECORD HAS. `ErrorPage` declares no `seo_tags` at all, so the
    # group asked a 404 for a meta description, an Open Graph image and a 50–60 character title it
    # cannot hold — and "Meta description missing" is a BLOCKER, which made a perfectly good error
    # page the only red score ring in the editor.
    test "the audit asks an error page nothing about SEO", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      view |> element("#pb-rail-audit") |> render_click()
      html = render(view)

      refute html =~ "Meta description missing"
      refute html =~ "Open Graph image not set"
      refute html =~ "SEO &amp; Meta"

      # The outline IS its own, though — an error page is a whole document, not a fragment.
      assert html =~ "Heading order is sound"
    end

    # And a page, which declares `seo_tags`, keeps the whole group — the gate is the resource's
    # fields, not a list of sections written down twice.
    test "while a page, which has those fields, still gets asked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Open Graph image not set"
    end

    # AND THE COST OF GETTING IT WRONG, which is why this is not a cosmetic bug. `save_fields/3`
    # replaces the entry named by `@status` with whatever the tree serialises to — so a tree left over
    # from 404, saved while the strip reads 500, writes the 404 markup into the 500 entry and the real
    # 500 page is gone with nothing said.
    test "so publishing after a switch cannot write one status over another", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, _first, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=404")

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      publish!(second)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      by_status =
        Map.new(reloaded.error_pages, fn entry ->
          {entry["status"] || entry[:status], entry["template"] || entry[:template]}
        end)

      assert by_status[500] =~ "Boom", "the 404 tree was published over the 500 entry"
      assert by_status[404] =~ "Not found"
    end
  end
end
