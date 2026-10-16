# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.AccessAndCodeTest do
  @moduledoc """
  Who may open the builder, editing, publishing, presence, the assistant, and author-written code.
  """
  use MishkaCmsCore.BuilderLiveCase

  # THE PAGE AREA WRITES THE PAGE'S CODE: its own type needs no code name of its own.
  describe "a page admin" do
    setup %{site: site} do
      {:ok, pages: narrow_conn(site, ["admin:dashboard:runtime:page"])}
    end

    test "opens the Handlers tab with its form and adds a handler", %{pages: pages, site: site} do
      {:ok, view, _html} = open_builder(pages, deep_forms_page!(site, written(["save"])))

      render_click(view, "open_source", %{"tab" => "events"})
      assert has_element?(view, "#pb-source-modal #pb-code-form")

      render_click(view, "add_code", %{"tab" => "events"})
      assert length(fragments(view).events) == 2
    end

    test "applies a template typed into the Template tab", %{pages: pages, page: page} do
      {:ok, view, _html} = open_builder(pages, page)
      view |> element("#pb-code") |> render_click()
      assert has_element?(view, "#pb-source-form")

      render_click(view, "apply_source", %{"source" => ~s(<div id="typed">typed</div>)})
      assert Serializer.serialize(editor(view).tree) =~ "typed"
    end

    test "corrects a broken template on the recovery screen", %{pages: pages, site: site} do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(pages, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert {:error, {:live_redirect, _to}} =
               view
               |> element("#pb-recover-form")
               |> render_submit(%{"template" => "<div><p>mended</p></div>"})

      assert Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: site.id).template ==
               "<div><p>mended</p></div>"
    end
  end

  # EACH TYPE'S BUILDER OPENS FOR ITS OWN RUNTIME AREA OR `admin:dashboard:code`, asked at mount and
  # again by the canvas, which is addressed by a session token rather than by the document.
  describe "who may open which builder" do
    test "the page area opens the page builder and not the layout builder", %{
      site: site,
      page: page
    } do
      conn = narrow_conn(site, ["admin:dashboard:runtime:page"])

      {:ok, view, _html} = open_builder(conn, page)
      assert has_element?(view, "#pb-root")

      layout = create_layout!(site_id: site.id)

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert to == "/admin/dashboard/runtime/layouts"
      assert flash["error"] =~ "permission to open the layout builder"
    end

    test "the layout area alone does not open the page builder", %{site: site, page: page} do
      conn = narrow_conn(site, ["admin:dashboard:runtime:layout"])

      for path <- [
            "/admin/dashboard/runtime/builder/page/#{page.id}",
            "/admin/dashboard/runtime/builder/page"
          ] do
        assert {:error, {:redirect, %{to: "/admin/dashboard/runtime/pages"}}} = live(conn, path)
      end
    end

    test "code opens every builder", %{site: site, page: page} do
      conn = narrow_conn(site, ["admin:dashboard:code"])

      for path <- [
            "/admin/dashboard/runtime/builder/page/#{page.id}",
            "/admin/dashboard/runtime/builder/layout/#{create_layout!(site_id: site.id).id}",
            "/admin/dashboard/runtime/builder/component/#{create_component!(site_id: site.id).id}",
            "/admin/dashboard/runtime/builder/error-page/#{create_error_page!(site_id: site.id).id}"
          ] do
        assert {:ok, _view, _html} = live(conn, path), path
      end
    end

    test "an error page, addressed error-page, opens for its own area", %{site: site} do
      error_page = create_error_page!(site_id: site.id)
      path = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"

      assert {:ok, _view, _html} =
               live(narrow_conn(site, ["admin:dashboard:runtime:error_page"]), path)

      assert {:error, {:redirect, %{to: "/admin/dashboard/runtime/error-pages"}}} =
               live(narrow_conn(site, ["admin:dashboard:runtime:page"]), path)
    end

    test "the canvas refuses a session of a builder the reader may not open", %{
      conn: conn,
      site: site,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      path = "/admin/dashboard/runtime/builder-canvas/#{token(view)}"

      {:ok, _canvas, html} = live(narrow_conn(site, ["admin:dashboard:runtime:layout"]), path)

      assert html =~ "You do not have permission to open this builder."

      {:ok, canvas, _html} = live(narrow_conn(site, ["admin:dashboard:runtime:page"]), path)

      refute :sys.get_state(canvas.pid).socket.assigns.missing?
    end

    test "a plugin's rail is drawn for a holder of the name it names and nobody else", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(MishkaCmsCore.Test.Plugins.BuilderGatedRailProbe, "builder:rails")
      key = MishkaCmsCore.Test.Plugins.BuilderGatedRailProbe.key()

      {:ok, view, _html} = open_builder(conn, page)
      assert has_element?(view, "#pb-rail-#{key}")

      narrow = narrow_conn(site, ["admin:dashboard:runtime:page"])
      {:ok, view, _html} = open_builder(narrow, page)

      refute has_element?(view, "#pb-rail-#{key}")
      render_click(view, "set_right_tab", %{"tab" => key})
      refute has_element?(view, "#pb-gated-rail-body")
    end

    test "a plugin's Studio tab is drawn for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(MishkaCmsCore.Test.Plugins.BuilderGatedStudioProbe, "builder:studio:tabs")
      tab = "#pb-studio-" <> MishkaCmsCore.Test.Plugins.BuilderGatedStudioProbe.key()

      view = open_studio(conn, page)
      assert has_element?(view, tab)

      narrow = narrow_conn(site, ["admin:dashboard:runtime:page"])
      view = open_studio(narrow, page)
      assert has_element?(view, "#pb-studio-tokens")
      refute has_element?(view, tab)
    end

    test "a plugin's toolbar action is drawn for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(
        MishkaCmsCore.Test.Plugins.BuilderGatedToolbarProbe,
        "builder:canvas:toolbar"
      )

      button = "#pb-eltb-" <> MishkaCmsCore.Test.Plugins.BuilderGatedToolbarProbe.key()

      for {who, drawn?} <- [
            {conn, true},
            {narrow_conn(site, ["admin:dashboard:runtime:page"]), false}
          ] do
        {:ok, view, _html} = open_builder(who, page)
        render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})

        {:ok, canvas, _html} =
          live(who, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

        assert has_element?(canvas, button) == drawn?
      end
    end

    test "a plugin's command is in the palette for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(MishkaCmsCore.Test.Plugins.BuilderGatedCommandProbe, "builder:commands")
      command = "#pb-cmd-" <> MishkaCmsCore.Test.Plugins.BuilderGatedCommandProbe.key()

      for {who, drawn?} <- [
            {conn, true},
            {narrow_conn(site, ["admin:dashboard:runtime:page"]), false}
          ] do
        {:ok, view, _html} = open_builder(who, page)
        render_click(view, "toggle_command", %{})

        assert has_element?(view, "#pb-cmd-save"), "the palette is open"
        assert has_element?(view, command) == drawn?
      end
    end

    # NOTHING DRAWS A CONTRIBUTED SECTION YET: the Inspector draws its own. What the builder holds
    # for the reader is what it would draw from, so that is what is asked.
    test "a plugin's Inspector section is held for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(
        MishkaCmsCore.Test.Plugins.BuilderGatedSectionProbe,
        "builder:inspector:sections"
      )

      key = MishkaCmsCore.Test.Plugins.BuilderGatedSectionProbe.key()

      for {who, held?} <- [
            {conn, true},
            {narrow_conn(site, ["admin:dashboard:runtime:page"]), false}
          ] do
        {:ok, view, _html} = open_builder(who, page)
        sections = :sys.get_state(view.pid).socket.assigns.inspector_sections

        assert Enum.any?(sections, &(to_string(&1.key) == "element")), "the core's are held"
        assert Enum.any?(sections, &(to_string(&1.key) == key)) == held?
      end
    end
  end

  describe "editing" do
    test "an attribute edit reaches the tree", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "headline"
      })

      edited = view |> editor() |> Map.fetch!(:tree) |> Tree.get(h1.id)
      assert {"class", {:string, "headline"}} in edited.attrs
    end

    test "delete removes the element and undo brings it back", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(view, "h1")

      undo!(view)
      assert node_with_tag(view, "h1")
    end

    test "redo re-applies the undone edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      undo!(view)
      redo!(view)

      refute node_with_tag(view, "h1")
    end

    test "a server-rejected drop leaves the document alone and flashes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      html =
        render_click(view, "op", %{
          "kind" => "insert",
          "template" => ~s(<div>nope</div>),
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "text and inline"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "locking an element refuses edits to it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "toggle_lock", %{"id" => h1.id})
      html = render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      assert html =~ "locked"
      assert node_with_tag(view, "h1")
    end
  end

  describe "publishing" do
    test "publish writes the page and reports the published stage", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "live-now"
      })

      # Two steps on purpose: the menu selects the stage, the button carries it out.
      view |> element("#pb-stage-published") |> render_click()
      html = view |> element("#pb-stage") |> render_click()

      assert html =~ "published"

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="live-now")
      refute editor(view).dirty?
    end

    test "the stage button publishes again after an edit, and has nothing to do without one", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      set_class =
        &render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => h1.id,
          "name" => "class",
          "value" => &1
        })

      set_class.("first-publish")
      view |> element("#pb-stage-published") |> render_click()
      view |> element("#pb-stage") |> render_click()

      view |> element("#pb-stage-published") |> render_click()
      assert view |> element("#pb-stage") |> render() =~ "Published"
      refute view |> element("#pb-stage") |> render() =~ ~s(phx-click="apply_stage")

      set_class.("second-publish")
      view |> element("#pb-stage-published") |> render_click()
      chip = view |> element("#pb-stage") |> render()
      refute chip =~ "Published"
      assert chip =~ "Publish"
      assert chip =~ ~s(phx-click="apply_stage")

      view |> element("#pb-stage") |> render_click()

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="second-publish")
    end

    test "an edit after a publish is draft work again, autosaved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      publish!(view)

      assert view |> element("#pb-stage") |> render() =~ "Save draft"

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "after-publish"
      })

      chip = view |> element("#pb-stage") |> render()
      assert chip =~ "Draft"
      refute chip =~ "Save draft"
      assert view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"
    end

    # THE ORDINARY PUBLISH IS A PUBLISH FROM A DRAFT — autosave mints one before the author ever
    # reaches the button — and its cleanup used to collect nothing at all: the spent draft is
    # discarded first, which moves its rows onto the live branch before the collect asks for them.
    # Every payload stayed, and the released rows read on the page's own timeline still offering a
    # Restore, under the summary row saying they are no longer restorable.
    test "and a publish from a draft drops the payloads behind it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert autosave!(view), "no draft was minted; this would prove nothing"
      assert snapshots() != [], "nothing was recorded; this would prove nothing"

      publish!(view)
      _collected = render_async(view)

      assert snapshots() == []
      assert Enum.all?(history_rows(page), &is_nil(&1.snapshot_id))
      assert Enum.any?(history_rows(page), &(&1.op == :publish))
    end
  end

  describe "the assistant rail" do
    test "sending a prompt reaches the backend and renders both turns", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      assert has_element?(view, "#pb-ai-form")
      assert render(view) =~ "Echo (no model configured)"

      html =
        view |> form("#pb-ai-form", %{"prompt" => "Make the header sticky"}) |> render_submit()

      assert html =~ "Make the header sticky"
      # The default backend must SAY it cannot act rather than fabricate an edit.
      assert html =~ "No AI backend is configured"
      assert html =~ "Nothing was changed"
    end

    test "the prompt is scoped to the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      view |> element("#pb-rail-assistant") |> render_click()

      # The composer names the scope the way the prototype does — the tag in angle brackets.
      assert render(view) =~ "&lt;h1&gt;"

      html = view |> form("#pb-ai-form", %{"prompt" => "shorter"}) |> render_submit()
      assert html =~ "h1"
    end

    test "an empty prompt does nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      view |> form("#pb-ai-form", %{"prompt" => "   "}) |> render_submit()
      assert render(view) =~ "Describe a change"
    end
  end

  describe "the assistant rail's chrome" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()
      %{view: view}
    end

    test "it names who is answering, how it is connected, and what it has done", %{view: view} do
      html = render(view)

      assert html =~ "AI Assistant"
      assert html =~ "Echo (no model configured)"
      assert html =~ "0 revisions"
      # Claiming "Connected" while Echo answers would make its honest reply read as a malfunction.
      assert html =~ "Not connected"
      assert html =~ "Advanced settings"
    end

    # THE EXPLANATION IS ON THE PAGE, FOLDED. Nothing behind the disclosure needs this process, so
    # the heading is a JS toggle of a body that shipped with the panel.
    test "Advanced settings explains the backend, behind a fold the browser opens", %{view: view} do
      assert render(view) =~ "No model is connected"
      assert has_element?(view, "#pb-ai-advanced-body.hidden")
      assert view |> element("#pb-ai-advanced") |> render() =~ "#pb-ai-advanced-body"
    end

    test "a chip fills the box rather than sending", %{view: view} do
      html = render_click(view, "ai_chip", %{"text" => "Make the header sticky"})

      assert html =~ "Make the header sticky"
      # Nothing was asked — the wording stays the author's to adjust.
      assert editor_messages(view) == []
    end

    test "both turns render with a sender and the scope", %{view: view} do
      view |> form("#pb-ai-form", %{"prompt" => "Tighten the spacing"}) |> render_submit()

      html = render(view)
      assert html =~ "Tighten the spacing"
      assert html =~ "boss"
      assert html =~ "AI Assistant"
    end

    # Echo changes nothing, so it offers no Restore. A rollback button that rolls nothing back is
    # worse than none — the prototype shows one on every turn because its transcript is a mock.
    test "a reply that changed nothing offers no Restore", %{view: view} do
      view |> form("#pb-ai-form", %{"prompt" => "Make it blue"}) |> render_submit()

      refute has_element?(view, "#pb-ai-restore-1")
      assert render(view) =~ "0 revisions"
    end
  end

  # THE SEAM THE RAIL HAS ALWAYS CLAIMED. Echo returns no ops, so every one of the tests above passes
  # against a transcript nothing applies; these run a backend that does return one.
  describe "an assistant that edits the document" do
    setup %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_ai_backend, MishkaCmsCore.Test.AiBackendStub)
      MishkaCmsCore.Test.AiBackendStub.answer([])

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :builder_ai_backend)
        Application.delete_env(:mishka_cms_core, :test_ai_answer)
      end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()
      %{view: view}
    end

    test "the ops it returns are applied, and the revision counts what landed", %{view: view} do
      insert_figure(view)

      assert node_with_tag(view, "figure"), "the reply's op reached the document"
      assert has_element?(view, "#pb-ai-restore-1")
      assert render(view) =~ "1 revision"
      assert render(view) =~ "1 change"
    end

    # One prompt is one undo step, however many ops it took — which is what a reader means by
    # "undo what it just did".
    test "undo takes the whole run back in one step", %{view: view} do
      insert_figure(view)
      assert node_with_tag(view, "figure")

      render_click(view, "undo", %{})

      refute node_with_tag(view, "figure")
    end

    # A run is all-or-nothing, so a refusal leaves the document alone — and the rail says so in the
    # transcript rather than stamping a revision whose Restore would write over the author's work.
    test "a refused op changes nothing, says so, and offers no Restore", %{view: view} do
      h1 = node_with_tag(view, "h1")
      before = editor(view).tree

      ask_ai(view, [%{kind: :insert, parent_id: h1.id, index: 0, template: "<section></section>"}])

      assert editor(view).tree == before
      refute has_element?(view, "#pb-ai-restore-1")
      assert render(view) =~ "0 revisions"

      # The headline is the loud line, and the model's claim is not allowed to stand in it with the
      # correction whispered underneath.
      assert %{
               text: "Nothing was changed. A `<h1>` can only hold text and inline elements.",
               plain: "Done: Add a figure"
             } = List.last(editor_messages(view))
    end

    # A model writes malformed ops, and a field-error list inspected into the bubble is a struct dump
    # for an admin to read.
    test "an op the editor cannot read is refused in words", %{view: view} do
      ask_ai(view, [%{kind: :rewrite, parent_id: "root", index: 0}])

      assert %{text: "Nothing was changed. That change could not be applied: unknown kind."} =
               List.last(editor_messages(view))
    end

    # Applied is not the same as changed. A run leaving the very same tree records nothing, so a
    # revision beside it would offer to roll back to the document already on screen — over whatever
    # the author did while waiting for the answer, which is what the canvas was still doing.
    test "an answer that changes nothing carries no revision", %{view: view} do
      section = node_with_tag(view, "section")

      ask_ai(
        view,
        [%{kind: :set_attr, node_id: section.id, name: "id", value: "hero", value_kind: :string}],
        [%{kind: :insert, parent_id: "root", index: 0, template: "<aside></aside>"}]
      )

      refute has_element?(view, "#pb-ai-restore-1")
      refute render(view) =~ "Nothing was changed"
      assert render(view) =~ "0 revisions"
      # The canvas's own insert, and no `:run` entry on top of it.
      assert [%{kind: :insert}] = editor(view).past
    end

    # THE DOCUMENT MOVES WHILE THE MODEL THINKS. The canvas is a separate process that keeps writing
    # for the whole round trip, so Restore has to put back the document as it was when the answer
    # landed — the rail's own copy of the tree is the one from before the question.
    test "Restore keeps an edit made while the answer was being written", %{view: view} do
      ask_ai(
        view,
        [%{kind: :insert, parent_id: "root", index: 0, template: "<figure></figure>"}],
        [%{kind: :insert, parent_id: "root", index: 0, template: "<aside></aside>"}]
      )

      assert node_with_tag(view, "figure")
      assert node_with_tag(view, "aside")

      render_click(view, "ai_restore", %{"index" => "1"})

      refute node_with_tag(view, "figure")
      assert node_with_tag(view, "aside"), "the edit made while the model was thinking survived"
    end

    # The history row is the assistant's, not the operator's, and carries what it was asked.
    test "the run is recorded as the assistant's, with the prompt behind it", %{view: view} do
      insert_figure(view)

      assert %{author_type: :ai, label: "1 change", prompt: "Add a figure", backend: backend} =
               hd(editor(view).past)

      assert backend == "Stub (test backend)"
    end

    # `opts` was a declared argument nothing ever filled, so a backend that would rather write its
    # own ops had no handle to write through.
    test "the backend is handed the session and the document it is editing", %{
      view: view,
      page: page
    } do
      ask_ai(view, [])

      assert_receive {:asked, "Add a figure", opts}
      assert opts[:token] == token(view)
      assert opts[:resource_id] == page.id
      assert opts[:site_id] == page.site_id
      assert opts[:section] == editor(view).section
    end

    defp insert_figure(view) do
      ask_ai(view, [%{kind: :insert, parent_id: "root", index: 0, template: "<figure></figure>"}])
    end

    # `meanwhile` is what the canvas writes while the model is answering — see the stub.
    defp ask_ai(view, ops, meanwhile \\ []) do
      MishkaCmsCore.Test.AiBackendStub.answer(ops, meanwhile)
      view |> form("#pb-ai-form", %{"prompt" => "Add a figure"}) |> render_submit()
    end
  end

  describe "the canvas's own event handlers" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      %{view: view, canvas: canvas}
    end

    # A real mouse drop lands on the CANVAS LiveView, not the chrome — a different handler.
    test "a drop on the canvas inserts", %{view: view, canvas: canvas} do
      section = node_with_tag(view, "section")

      render_click(canvas, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure")
    end

    test "a drop on the canvas moves", %{view: view, canvas: canvas} do
      h1 = node_with_tag(view, "h1")
      render_click(canvas, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})

      assert Tree.get(view |> editor() |> Map.fetch!(:tree), h1.id).parent_id == nil
    end

    test "an illegal drop on the canvas lands beside the target and says so", %{
      view: view,
      canvas: canvas
    } do
      h1 = node_with_tag(view, "h1")

      render_click(canvas, "drop", %{
        "template" => "<section></section>",
        "parent_id" => h1.id,
        "index" => "0"
      })

      assert_push_event(canvas, "pb:drop-moved", %{message: message})
      assert message =~ "Placed after"

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "section" and &1.children == []))

      assert inserted.parent_id == h1.parent_id
    end

    test "the canvas answers a dragstart with the tree's verdict", %{view: view, canvas: canvas} do
      h1 = node_with_tag(view, "h1")
      section = node_with_tag(view, "section")

      render_click(canvas, "drag_start", %{"template" => "<section></section>"})

      assert_push_event(canvas, "pb:drop-hints", %{accepts: accepts})
      assert accepts[h1.id] == false
      assert accepts[section.id] == true
    end

    test "inline text editing writes through the canvas", %{view: view, canvas: canvas} do
      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(canvas, "set_text", %{"id" => text.id, "text" => "Edited inline"})

      assert editor_html(view) =~ "Edited inline"
    end

    # Hover deliberately never reaches the server. Nothing reads it — the layers rail highlights the
    # SELECTION, as the prototype does — and pushing an event per mouseover meant a round trip and a
    # re-render of the whole document for every pixel the pointer travelled. The outline is a CSS rule
    # inside the frame instead.
    test "hovering costs no round trip: the canvas has no hover handler", %{canvas: canvas} do
      assert render(canvas) =~ ~s([data-node-id]:hover)

      # A stray push is ignored rather than mutating anything.
      assert render_click(canvas, "hover", %{"id" => "nabcdefgh"})
    end
  end

  describe "presence" do
    # You are always in the stack — that is what gives the bar the prototype's avatar chip without
    # inventing colleagues. What must NOT appear is a second one.
    test "a lone editor sees only their own avatar", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = view |> element("#pb-avatars") |> render()
      assert html =~ "Only you are editing this page"

      # Exactly one chip: you. A second would mean a second person, which is the case that matters.
      assert html |> String.split("rounded-full") |> length() == 2
    end

    # Two admins share a session by URL. This used to be impossible: `?session=` was ignored, so
    # each mount opened its own private tree and the avatars could never appear.
    test "a second admin joining by session token shares the document and shows up", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      shared = token(first)

      other = create_admin("colleague@example.com")

      second_conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
        |> log_in(other)

      {:ok, second, _html} =
        live(
          second_conn,
          "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{shared}"
        )

      # Same session, not a copy.
      assert token(second) == shared

      # An edit by one is seen by the other, over the session's PubSub topic.
      h1 = node_with_tag(first, "h1")
      render_click(second, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(first, "h1")

      # And each sees the other in the avatar row.
      assert render(first) =~ "pb-avatars"

      assert Enum.any?(
               MishkaCmsCore.Runtime.PageBuilder.Presence.editors(shared),
               &(&1.id == other.id)
             )
    end

    test "a site admin in a master's session sees the master as M, and the master sees them", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, first, _html} = open_builder(conn, page)
      shared = token(first)
      joiner = create_admin("tenant.joiner@example.com", site.id)

      {:ok, second, _html} =
        live(
          log_in(build_conn_for_host(), joiner),
          "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{shared}"
        )

      assert token(second) == shared
      assert avatars(second) == ["TJ", "M"]
      assert avatars(first) == ["B", "TJ"]
      refute MishkaCmsCore.Runtime.PageBuilder.Presence.editors(shared) |> inspect() =~ "@"
    end

    test "a stale or foreign session token falls back to a fresh session", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?session=nosuchtokenatall")

      assert token(view) =~ ~r/^[a-z0-9]{32}$/
      assert node_with_tag(view, "h1")
    end

    test "initials come from the email's local part" do
      alias MishkaCmsCore.Runtime.PageBuilder.Presence

      assert Presence.initials(%{email: "ada.lovelace@example.com"}) == "AL"
      assert Presence.initials(%{email: "boss@example.com"}) == "B"
      assert Presence.initials(%{email: "a_b_c@example.com"}) == "AB"
      assert Presence.initials(%{}) == "?"
    end
  end

  describe "autosave, history counter and revert" do
    # The prototype puts no counter chip in the bar — the position lives in the undo button's own
    # tooltip, where it explains what that click will do, and in the Record-history sheet.
    test "the undo button reports position and total", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert view |> element("#pb-undo") |> render() =~ "0/0"

      h1 = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      assert view |> element("#pb-undo") |> render() =~ "1/1"

      undo!(view)
      assert view |> element("#pb-undo") |> render() =~ "0/1"
    end

    test "revert restores the document to a history entry", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(view, "h1")

      _flushed = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "history"})
      render_async(view)

      # By the row's own id, not by its position: the sheet pages and filters, so an index would be
      # a different change on a different screen.
      render_click(view, "history_revert", %{"id" => newest_history_row(page).id})
      _recorded = render_async(view)

      assert node_with_tag(view, "h1")
    end

    # A CHANGE IS THE TRIGGER, not a clock. It writes a DRAFT and never the live row: a live write
    # enqueues a compile job and would push half-finished work to visitors as it was being made.
    test "a change writes a draft and leaves the live page alone", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "auto"
      })

      _written = render_async(view)

      {:ok, live_page} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      refute live_page.template =~ ~s(class="auto")

      {:ok, drafts} =
        MishkaCmsCore.Runtime.PageDraft
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read(page: [limit: 10])

      draft = Enum.find(drafts.results, &(&1.source_page_id == page.id))
      assert draft
      assert draft.template =~ ~s(class="auto")
      assert String.starts_with?(draft.label, "Draft · "), draft.label
    end

    test "an autosaved draft is reachable at its shareable preview URL", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      send(view.pid, :autosave)

      _saved = render_async(view)

      # The shareable link lives behind the Preview caret now, with the other ways of looking at the
      # page, instead of a lone tick in the top bar that said nothing about what it did.
      html = render(view)

      assert html =~ "/_preview/page/"
      assert has_element?(view, "#pb-preview-tab")
    end

    test "a clean session does not autosave", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      send(view.pid, :autosave)
      _rendered = render_async(view)

      refute has_element?(view, "#pb-preview-tab")
    end
  end

  # Selecting an element has been the slowest thing in this editor twice: once at 2.2s, when every
  # mouse move pushed a `hover` event, and again at ~0.5s, when the selection ring was a server-
  # rendered inline style so a click re-rendered all ~200 nodes. Both were found in a browser, not
  # here — so this is the guard: the ring is client-side now, and the server's share of a selection
  # is a small, bounded thing.
  describe "selection cost" do
    test "a selection round trip stays cheap on a large document", %{conn: conn, site: site} do
      sections =
        Enum.map_join(1..40, fn i ->
          ~s(<section id="s#{i}"><h2>Section #{i}</h2><p>Body #{i}</p></section>)
        end)

      page = create_page!(site_id: site.id, template: ~s(<div id="root">#{sections}</div>))
      {:ok, view, _html} = open_builder(conn, page)

      tree = editor(view).tree
      assert Tree.size(tree) > 150
      ids = tree |> Tree.walk() |> Enum.map(& &1.id) |> Enum.take(10)

      # The first click after a fresh compile pays for module loading, which is not what this
      # measures — warm up, then time.
      render_click(view, "select", %{"id" => hd(ids)})

      times =
        for id <- ids do
          {microseconds, _html} = :timer.tc(fn -> render_click(view, "select", %{"id" => id}) end)
          div(microseconds, 1000)
        end

      # THE MIDDLE SAMPLE, NOT THE WORST ONE. Measured at 5–24ms on an idle machine, and what this
      # has to catch is a change in KIND — re-rendering the document on every click, which is
      # seconds, and which moves EVERY sample. A single 415ms outlier among nine samples of 86–174ms
      # is a GC pause or a busy scheduler, and asserting on the max made the whole suite hostage to
      # one of them: it failed on a run sharing this machine with two other suites and a dev server.
      #
      # Raising the ceiling again would have been the wrong repair — it trades away the very
      # sensitivity the test exists for. The median keeps it.
      median = times |> Enum.sort() |> Enum.at(div(length(times), 2))

      assert median < 400,
             "a selection cost #{median}ms (median) on a #{Tree.size(tree)}-node page: #{inspect(times)}"
    end
  end

  # A FAILED READ IS NOT AN EMPTY SITE. The palette read used to end `_error -> collect_palette([])`,
  # so a dropped connection under load painted a rail with nothing in it — no flash, no log line,
  # nothing to act on — and that is indistinguishable from a site with no components installed. In
  # production it reads as "my components vanished"; in this suite it was an intermittent failure
  # that never reproduced in isolation, because it needed contention to provoke.
  #
  # `assign_async/3` already carried a failure state and the panel already rendered a `:failed` slot
  # for it. The error simply never got that far.
  # HIDING A TAB IS A COURTESY, NOT THE SECURITY. `Validations.CodeChange` refuses the write whatever
  # the editor draws — which is what makes it safe to hide anything here at all, and it is covered
  # where it belongs, against the resource, in `CodeAccessTest`.
  #
  # These drive the editor half through the DEPLOYMENT SWITCH rather than through a permission,
  # because the switch closes the surface for everybody including the `*` admin this suite signs in.
  # It is the same `code_allowed?` either way, and this keeps the assertions about the tabs rather
  # than about the login.
  describe "when this deployment does not allow author-written Elixir" do
    setup do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      :ok
    end

    test "the Code window keeps Template and Styles and loses the three that store Elixir", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      assert has_element?(view, "#pb-sourcetab-template"), "markup is what the editor is for"
      assert has_element?(view, "#pb-sourcetab-styles")

      refute has_element?(view, "#pb-sourcetab-events")
      refute has_element?(view, "#pb-sourcetab-infos")
      refute has_element?(view, "#pb-sourcetab-helpers")
    end

    # A TEMPLATE TYPED BY HAND IS CODE the server runs; what the builder generates is not.
    test "and a template typed by hand is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "apply_source", %{"source" => ~s(<div id="typed">typed</div>)})
      assert flashes(view) =~ CodeAccess.refusal()

      render_click(view, "apply_element_heex", %{"source" => ~s(<p>typed</p>)})
      refute Serializer.serialize(editor(view).tree) =~ "typed"
    end

    # A hidden tab is not a closed door: the event can be sent without one.
    test "and the events behind them are refused, not merely undrawn", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "add_code", %{"tab" => "events"})

      assert render(view) =~ "turned off on this deployment"
      refute has_element?(view, "#pb-code-entry-events-0")
      assert :sys.get_state(view.pid).socket.assigns.fragments[:events] in [nil, []]
    end

    # The block's source is markup, and markup is what the Template tab keeps for everybody.
    test "a block expression still opens its code", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><%= for post <- @posts do %><p>x</p><% end %></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      block = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex_block))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => block.id})
      view |> element("#pb-expr-block-open-code") |> render_click()

      assert has_element?(view, "#pb-sourcetab-template")
      refute has_element?(view, "#pb-sourcetab-helpers")
    end

    test "but the rest of the editor is untouched", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-root")

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => heading.id,
        "name" => "class",
        "value" => "headline"
      })

      assert Serializer.serialize(editor(view).tree) =~ "headline"
    end
  end

  test "an author who may write code sees all five tabs", %{conn: conn, page: page} do
    {:ok, view, _html} = open_builder(conn, page)
    view |> element("#pb-code") |> render_click()

    for tab <- ~w(template events infos helpers styles) do
      assert has_element?(view, "#pb-sourcetab-#{tab}")
    end
  end

  # ONE BADGE, BESIDE THE CODE IT IS ABOUT — and not a second page listing them, which is what this
  # replaced. A warning belongs where somebody would fix it.
  describe "the code flag badge" do
    test "appears on a helper that calls something worth reading twice", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "helpers",
          "entry" => %{
            "0" => %{"name" => "sweep", "args" => "path", "code" => ~s|System.cmd("rm", [path])|}
          }
        })

      assert has_element?(view, "#pb-code-flag-helpers-0")
      assert html =~ "runs a program"
    end

    test "and stays away from ordinary code", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "helpers",
        "entry" => %{"0" => %{"name" => "money", "args" => "c", "code" => "c / 100"}}
      })

      refute has_element?(view, "#pb-code-flag-helpers-0")
    end

    # ORDINARY ELIXIR TOOK THE BUILDER DOWN. The badge is rendered inline in the drawer, and reading
    # the alias chain of `__MODULE__.Helpers.run/1` raised — so the save crashed the LiveView, and
    # because the fragments are loaded from the record, so did every mount after it.
    test "and a call it cannot name leaves the window standing, now and on the next mount", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "helpers",
        "entry" => %{
          "0" => %{"name" => "sweep", "args" => "path", "code" => "__MODULE__.Helpers.run(path)"}
        }
      })

      refute has_element?(view, "#pb-code-flag-helpers-0")

      {:ok, reopened, _html} = open_builder(conn, page)
      reopened |> element("#pb-code") |> render_click()

      assert render_click(reopened, "source_tab", %{"tab" => "helpers"}) =~ "sweep"
      refute has_element?(reopened, "#pb-code-flag-helpers-0")
    end
  end

  # THE BOX IS FED FROM THE TREE, and the tree does not change when a parse fails — so the typed text
  # held out only for as long as nothing else re-rendered. One op from a collaborator, one autosave,
  # and LiveView patched the textarea back to the document, taking a page of hand-written markup with
  # it.
  describe "a refused source edit" do
    test "keeps what was typed, even after an unrelated edit re-renders the window", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      typed = "<div><p>half written"
      render_click(view, "apply_source", %{"source" => typed})

      assert has_element?(view, "#pb-source-error")
      assert render(view) =~ "half written"

      # The unrelated op: it changes the tree, which is what used to overwrite the box.
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "headline"
      })

      assert render(view) =~ "half written", "the draft outlived a tree change"
    end

    test "and lets it go once it applies", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "apply_source", %{"source" => "<div><p>half written"})
      render_click(view, "apply_source", %{"source" => "<div><p>mended</p></div>"})

      assert :sys.get_state(view.pid).socket.assigns.source_draft == nil
      assert Serializer.serialize(editor(view).tree) =~ "mended"
    end

    test "closing the window drops the draft rather than keeping it forever", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "apply_source", %{"source" => "<div><p>half written"})
      render_click(view, "close_source", %{})

      assert :sys.get_state(view.pid).socket.assigns.source_draft == nil
    end
  end

  # A STORED TEMPLATE THE BUILDER CANNOT TOKENIZE. The Ash gate checks that a template COMPILES, and
  # the builder's own tokenizer is a different parser with different rules — `<div><p>x</div>` is
  # valid enough for HEEx and unbalanced for the tree. A page from a seed, from a hand edit, or from
  # before the gate existed therefore reaches the editor unparseable, and `mount_section/4`
  # destructured the result, so the answer was a MatchError and a crash loop on a page nobody could
  # then open to fix.
  describe "opening a page the tokenizer refuses" do
    # STRAIGHT INTO THE COLUMN, on purpose. The Ash actions refuse a template that will not compile,
    # so this state cannot be created through the front door — which is the point: it is what a seed,
    # a hand edit, or a page saved before that validation existed leaves behind, and the editor still
    # has to open it.
    defp break_template!(page, template) do
      repo = Application.fetch_env!(:mishka_cms_core, :repo)
      {:ok, id} = Ecto.UUID.dump(page.id)
      repo.query!("UPDATE pages SET template = $1 WHERE id = $2", [template, id])
      page
    end

    test "shows what is wrong and offers the source, instead of crashing", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert html =~ "could not be opened"
      assert has_element?(view, "#pb-recover")
      assert has_element?(view, "#pb-recover-source"), "the stored template is still reachable"
      assert html =~ "unclosed", "and it is the author's own text, not a summary of it"
    end

    test "the message names the line and column the tokenizer stopped at", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div>\n  <p>one\n</div>")

      {:ok, _view, html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert html =~ "Line", "a position is the only thing that makes this actionable"
    end

    test "a page that parses is unaffected", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-recover")
      assert has_element?(view, "#pb-root")
    end

    # THE POINT OF THE SCREEN. Showing the problem without a way to fix it would leave the page just
    # as unopenable as the crash did.
    test "correcting the markup opens the editor on it", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#pb-recover-form")
               |> render_submit(%{"template" => "<div><p>mended</p></div>"})

      {:ok, opened, _html} = live(conn, to)
      _ = render_async(opened)

      refute has_element?(opened, "#pb-recover")
      assert has_element?(opened, "#pb-root")

      # The document itself lives in the canvas iframe, not in this LiveView's markup, so the tree is
      # what says the correction is the thing that opened.
      assert Serializer.serialize(editor(opened).tree) =~ "mended"
    end

    # A correction that is still broken must not throw away what was typed — a minute of somebody's
    # work — and must not pretend it worked.
    test "a correction that still does not parse keeps the text and says why", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      html =
        view
        |> element("#pb-recover-form")
        |> render_submit(%{"template" => "<section><p>still wrong</section>"})

      assert has_element?(view, "#pb-recover-error")
      assert html =~ "still wrong", "what was typed is still in the box"
    end

    # THE CORRECTION IS CODE AT THE WRITE: a deployment that turns code off while the screen is open
    # stops it, whoever holds what.
    test "a correction typed after the deployment turned code off is not stored", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
      assert has_element?(view, "#pb-recover-form")

      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)

      view
      |> element("#pb-recover-form")
      |> render_submit(%{"template" => "<div><p>mended</p></div>"})

      assert has_element?(view, "#pb-recover-error")

      assert Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: site.id).template ==
               "<div><p>unclosed</div>"
    end
  end

  # A CSS BODY IS AUTHORED TEXT, AND THE CANVAS PUTS IT IN A `<style>` TAG. `</style>` ends that tag
  # wherever it appears, so the browser stops reading CSS and starts reading markup: the rest of the
  # body becomes elements in the canvas document. Every body the canvas styles with is authored —
  # an element's own box, a site's stylesheet row — so the sequence can arrive.
  describe "a CSS body that tries to close the style tag" do
    setup %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><p>hello</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      %{view: view, conn: conn, node: node}
    end

    defp canvas_html(conn, view) do
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      html
    end

    test "cannot close it", %{conn: conn, view: view, node: node} do
      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => ~s|color: red;\n/* </style><span id="escaped">out</span> */|
      })

      html = canvas_html(conn, view)

      refute html =~ ~s(</style><span id="escaped")
      assert html =~ "<\\/style"
    end

    test "and neither can a shouted one", %{conn: conn, view: view, node: node} do
      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => ~s|color: red;\n/* </STYLE><span id="shouted">out</span> */|
      })

      refute canvas_html(conn, view) =~ ~s(</STYLE><span id="shouted")
    end

    # The escape belongs at the boundary, not in storage: the same body is served as a real
    # stylesheet, where the sequence is unremarkable and has to survive untouched.
    test "while what is stored is exactly what was written", %{view: view, node: node} do
      body = ~s|color: red;\n/* </style> */|

      render_click(view, "save_element_css", %{"node_id" => node.id, "css" => body})

      stored = :sys.get_state(view.pid).socket.assigns.element_css_rules

      assert stored |> Map.values() |> Enum.join() =~ "</style>"
    end
  end

  # The advice was computed only when Apply was pressed, so a bad selector saved yesterday was silent
  # when the panel was opened on it today — the case where an author is most likely to be wondering
  # why their CSS does nothing.
  describe "advice about a stored body" do
    test "shows when the panel is opened on CSS that was already saved", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<div id="root"><p>hello</p></div>))

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => "main { color: red }"
      })

      render_click(view, "select", %{"id" => node.id})

      assert :sys.get_state(view.pid).socket.assigns.element_css_advice =~ "INSIDE this element"
    end

    test "and says nothing about a body that is only declarations", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<div id="root"><p>hello</p></div>))

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      render_click(view, "save_element_css", %{"node_id" => node.id, "css" => "color: red;"})
      render_click(view, "select", %{"id" => node.id})

      assert :sys.get_state(view.pid).socket.assigns.element_css_advice == nil
    end
  end

  describe "hidden from visitors" do
    test "the right-click menu hides an element; the layers chip and the Inspector say so and show it",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute has_element?(canvas, "#pb-eltb-visibility"), "the element toolbar has no second eye"

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => h1.id})

      assert Visibility.hidden?(node_with_tag(view, "h1"))
      assert has_element?(canvas, ~s([data-node-id="#{h1.id}"][data-pb-hidden]))

      view |> element("#pb-layer-hidden-#{h1.id}") |> render_click()
      refute Visibility.hidden?(node_with_tag(view, "h1"))
      refute has_element?(view, "#pb-layer-hidden-#{h1.id}")

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => h1.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      assert has_element?(view, "#pb-insp-hidden")

      view |> element("#pb-insp-show") |> render_click()

      refute Visibility.hidden?(node_with_tag(view, "h1"))
      refute has_element?(view, "#pb-insp-hidden")
      refute has_element?(canvas, "[data-pb-hidden]")
    end

    test "an element inside a hidden one points at it, and is not shown on its own",
         %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section data-pb-hidden><h1>Contact Us</h1></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      assert has_element?(view, "#pb-layer-hidden-#{section.id}")
      refute has_element?(view, "#pb-layer-hidden-#{h1.id}"), "the chip marks the one hidden"

      view |> element("#pb-lefttab-inspector") |> render_click()
      assert has_element?(view, "#pb-insp-hidden")
      refute has_element?(view, "#pb-insp-show")

      render_click(view, "toggle_visibility", %{})
      assert flashes(view) =~ "It is hidden with the element around it."
      assert Visibility.hidden_by(editor(view).tree, h1.id).id == section.id

      view |> element("#pb-insp-select-hider") |> render_click()
      assert editor(view).selection == section.id
      assert has_element?(view, "#pb-insp-show")
    end

    test "the right-click menu, the keyboard and the palette each toggle it as one undoable step",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")

      render_click(view, "shortcut", %{"key" => "visibility"})
      assert flashes(view) =~ "Select an element on the page first."

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => p.id})
      assert Visibility.hidden?(node_with_tag(view, "p"))
      assert %{label: "Hidden from visitors"} = hd(editor(view).past)

      render_click(view, "select", %{"id" => p.id})
      render_click(view, "shortcut", %{"key" => "visibility"})
      refute Visibility.hidden?(node_with_tag(view, "p"))
      assert %{label: "Shown to visitors"} = hd(editor(view).past)

      render_click(view, "shortcut", %{"key" => "command"})
      view |> element("#pb-cmd-toggle_visibility") |> render_click()
      assert Visibility.hidden?(node_with_tag(view, "p"))

      undo!(view)
      refute Visibility.hidden?(node_with_tag(view, "p"))
    end

    test "preview draws nothing of a hidden element, editing draws it dimmed",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "h1").id
      })

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us"
      assert canvas |> element("#pb-canvas-chrome") |> render() =~ "[data-pb-hidden]"

      view |> element("#pb-preview") |> render_click()

      refute render(canvas) =~ "Contact Us"
      assert render(canvas) =~ "Reach out any time."
    end

    test "publishing keeps it in the page, leaves it out of what visitors get, and says so",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "h1").id
      })

      publish!(view)

      assert flashes(view) =~ "Page published. 1 hidden element was left out."

      stored =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert stored.template =~ "<h1 data-pb-hidden>Contact Us</h1>"

      html = LiveViewCompiler.render_template(stored.template, %{})
      refute html =~ "Contact Us"
      assert html =~ "Reach out any time."
    end
  end
end
