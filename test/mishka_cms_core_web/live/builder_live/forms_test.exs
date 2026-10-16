# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.FormsTest do
  @moduledoc """
  A page's forms: the Form and Validation sections, their handlers, joining fields and the Form panel.
  """
  use MishkaCmsCore.BuilderLiveCase

  # THE ENGINE WAS FINISHED AND NOTHING DREW IT. Every function under here had unit tests and no
  # caller: clicking a bound field showed State, Layout, Appearance and Behavior, and the two
  # sections that make a form a working form were not in the panel at all.
  describe "the Form and Validation sections" do
    defp node_again(view, id), do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id)

    defp inspecting(view, node) do
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
    end

    defp chelekom_button!(site), do: kit_rows!(site, chelekom_rows(~w(chelekom-button)))

    defp pill(view), do: view |> element("#pb-form-part") |> render()

    defp kit_buttons(view),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.filter(&(Node.component_name(&1) == "chelekom-button"))

    @kit_page ~s(<div id="root"><section id="hero">) <>
                ~s(<.component component_name="chelekom-button" site="localhost">Start free</.component>) <>
                ~s(</section><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit">) <>
                ~s(<input name={f[:email].name} /><div class="card"><div class="grid"><div class="col">) <>
                ~s(<.component component_name="chelekom-button" site="localhost">Send</.component>) <>
                ~s(<.component component_name="chelekom-button" site="localhost" type="button">Preview</.component>) <>
                ~s(</div></div></div></.form></div>)

    test "the header says a kit button deep in a form is its Submit button", %{
      conn: conn,
      site: site
    } do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [_hero, send, _preview] = kit_buttons(view)

      inspecting(view, send)

      assert has_element?(view, ~s(#pb-form-part[data-part="submit"]))
      assert pill(view) =~ "Submit button"
    end

    test "and one that says type=button does not send the form", %{conn: conn, site: site} do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [_hero, _send, preview] = kit_buttons(view)

      inspecting(view, preview)

      assert pill(view) =~ "Button · does not send the form"
      refute pill(view) =~ "Submit button"
    end

    test "and one outside every form is just a Button", %{conn: conn, site: site} do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [hero, _send, _preview] = kit_buttons(view)

      inspecting(view, hero)

      assert has_element?(view, ~s(#pb-form-part[data-part="button"]))
      refute pill(view) =~ "Submit"
      refute pill(view) =~ "does not send"
    end

    test "the form is a Form, its field a Field, and a plain box says nothing", %{
      conn: conn,
      site: site
    } do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)

      inspecting(view, node_with_tag(view, ".form"))
      assert pill(view) =~ "Form"

      inspecting(view, node_with_tag(view, "input"))
      assert pill(view) =~ "Field"

      inspecting(view, node_with_tag(view, "section"))
      refute has_element?(view, "#pb-form-part")
    end

    test "no developer words ride along in a tooltip", %{conn: conn, site: site} do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [_hero, send, _preview] = kit_buttons(view)

      inspecting(view, send)

      assert has_element?(view, "#pb-form-part")
      refute has_element?(view, "#pb-form-part[title]")
      refute has_element?(view, "#pb-form-part [title]")
    end

    # Two forms, each with its fields in a column of a grid in a card: Phoenix's own, and Chelekom's
    # Simple Form installed under another name and holding `for={%{}}` as the palette seeds it, so
    # only its markup marks it as a form.
    @deep_forms ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit">) <>
                  ~s(<div class="card"><div class="grid"><div id="contact-col"><input name={f[:email].name} /></div></div></div></.form>) <>
                  ~s(<.component component_name="acme-simple" site="localhost" :let={w} id="signup-form" for={%{}}>) <>
                  ~s(<div class="card"><div class="grid"><div id="signup-col"><input name={w[:email].name} /></div></div></div></.component></div>)

    defp renamed_forms!(site),
      do:
        kit_rows!(
          site,
          renamed_form_pair(chelekom_rows(~w(chelekom-form-wrapper chelekom-simple-form)))
        )

    defp with_dom_id(view, id),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "id") == id))

    defp drop_into(view, id, template),
      do:
        render_click(view, "drop", %{
          "template" => template,
          "parent_id" => with_dom_id(view, id).id,
          "index" => "0"
        })

    test "a form dropped into a column of another form's card is refused", %{
      conn: conn,
      site: site
    } do
      renamed_forms!(site)
      page = create_page!(site_id: site.id, template: @deep_forms)
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)

      for column <- ~w(contact-col signup-col),
          template <- [
            ~s(<.component component_name="acme-simple" site="localhost" for={%{}}></.component>),
            Elements.get("el-form").template
          ] do
        drop_into(view, column, template)

        assert flashes(view) =~ "inside another form", "#{template} into #{column}"
        clear_flashes(view)
      end

      assert node_count(view) == before
    end

    test "a field dropped into either form's column joins that form", %{conn: conn, site: site} do
      renamed_forms!(site)
      page = create_page!(site_id: site.id, template: @deep_forms)
      {:ok, view, _html} = open_builder(conn, page)

      drop_into(view, "signup-col", ~s(<input name="phone" />))
      drop_into(view, "contact-col", ~s(<input name="phone" />))

      document = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()

      assert document =~ ~s(name={w[:phone].name})
      assert document =~ ~s(name={f[:phone].name})
      assert length(tagged(view, ".form")) == 1, "no second form was made around either field"
    end

    # Another kit's contact form: its one outer element is that kit's form component and its `for`
    # is optional, so only the palette says it owns a form.
    defp acme_forms!(site) do
      create_component!(
        site_id: site.id,
        name: "acme-form",
        attrs: [%{"name" => "for", "type" => "any", "opts" => %{"required" => true}}],
        slots: [%{"name" => "inner_block"}],
        template: ~S|<.form :let={f} for={@for}>{render_slot(@inner_block, f)}</.form>|
      )

      create_component!(
        site_id: site.id,
        name: "acme-contact",
        attrs: [
          %{"name" => "for", "type" => "any", "opts" => %{}},
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "plain", "values" => ["plain", "boxed"]}
          }
        ],
        slots: [%{"name" => "inner_block"}],
        template:
          ~S|<.component component_name="acme-form" site="localhost" :let={f} for={@for} class={@variant}>{render_slot(@inner_block, f)}</.component>|
      )
    end

    defp contact_in(tree),
      do: tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "acme-contact"))

    defp placed_contact(view), do: view |> editor() |> Map.fetch!(:tree) |> contact_in()

    test "a form calling another kit's form is carded with an empty map, and placed working", %{
      conn: conn,
      page: page,
      site: site
    } do
      acme_forms!(site)
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s(#pb-comp-acme-contact[data-template*="for={%{}}"]))

      view |> element("#pb-comp-acme-contact") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      # On a Page it then arrives working (spec 4.4): its own page assign, `:let` and names.
      assert Node.attr(placed_contact(view), "for") == {:expr, "assigns[:form_form]"}
      assert Node.attr(placed_contact(view), ":let") == {:expr, "f"}
    end

    test "and inserted from its wizard the same way", %{conn: conn, page: page, site: site} do
      acme_forms!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "acme-contact")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "boxed"})

      assert has_element?(view, "#pb-example-code-body", "for={%{}}")

      render_click(view, "insert_wizard", %{})

      assert Node.attr(placed_contact(view), "for") == {:expr, "assigns[:form_form]"}
      assert Node.attr_text(placed_contact(view), "variant") == "boxed"
    end

    test "and previewed from its wizard the same way", %{conn: conn, page: page, site: site} do
      acme_forms!(site)
      define_component!("acme-contact", site, "<div>contact form</div>")
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}/wizard/acme-contact")

      previewed = fn -> contact_in(:sys.get_state(canvas.pid).socket.assigns.tree) end

      assert Node.attr(previewed.(), "for") == {:expr, "%{}"}

      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "boxed"})

      assert Node.attr_text(previewed.(), "variant") == "boxed"
      assert Node.attr(previewed.(), "for") == {:expr, "%{}"}
    end

    test "Validation shows on a field bound to one of its form's keys", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")

      inspecting(view, bound)

      assert has_element?(view, "#pb-section-validation")
      assert has_element?(view, "#pb-rule-required")
      assert has_element?(view, "#pb-rule-minlength")
      assert has_element?(view, "#pb-rule-pattern")
      refute has_element?(view, "#pb-section-form")
    end

    test "the form itself gets Form, and no rules of its own", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)

      inspecting(view, node_with_tag(view, ".form"))

      assert has_element?(view, "#pb-section-form")
      assert has_element?(view, "#pb-rule-seed")
      assert has_element?(view, "#pb-rule-success")
      refute has_element?(view, "#pb-section-validation")
    end

    # THE PALETTE CARD PROMISES THIS IN WORDS — "A working form with one field. Rename it in the
    # Inspector." — so the card and the panel are asserted together: a form that arrives from the
    # Forms palette is one the rename control opens on.
    test "a form dropped from the palette is one the Inspector can rename", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "section").id})
      render_click(view, "pick_block", %{"block" => "el-form"})

      inspecting(view, node_with_tag(view, ".form"))

      assert has_element?(view, "#pb-rule-seed")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      assert [%{as: "enquiry"}] = declared_forms(view)
    end

    # ABOVE THE BREAKPOINT STRIP, where the component properties are. Drawn inside it these sat under
    # "Recorded against 560px and below", and every control in them writes a plain attribute — one
    # value for the whole page. An author would have read the panel as offering a mobile-only
    # `required`, and set one that does not exist.
    test "neither section is drawn inside the breakpoint body", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")

      assert before?(inspecting(view, bound), ~s(id="pb-section-validation"), @strip)

      assert before?(
               inspecting(view, node_with_tag(view, ".form")),
               ~s(id="pb-section-form"),
               @strip
             )
    end

    defp before?(html, first, second) do
      {at, _length} = :binary.match(html, first)
      {then_at, _length} = :binary.match(html, second)

      at < then_at
    end

    # A LOOSE `<input name="loose">` IS A FIELD AND NOT A BOUND ONE, so it has no key for a rule to
    # hang off — offering rules on it would write constraints the changeset never reads.
    test "and a loose control inside the form gets neither", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [_bound, loose] = tagged(view, "input")

      inspecting(view, loose)

      refute has_element?(view, "#pb-section-validation")
      refute has_element?(view, "#pb-section-form")
    end

    test "Required writes the attribute, and turning it off takes it away", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")
      inspecting(view, bound)

      view |> element("#pb-rule-required") |> render_click()

      assert Node.attr(node_again(view, bound.id), "required") == :boolean

      # `required=""` is still required to a browser, so a rule turned off has to be deleted.
      view |> element("#pb-rule-required") |> render_click()

      assert is_nil(Node.attr(node_again(view, bound.id), "required"))
    end

    test "Min length writes minlength, and clearing it removes the rule", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")
      inspecting(view, bound)

      view |> element("#pb-rule-form-minlength") |> render_change(%{"value" => "5"})

      assert Node.attr_text(node_again(view, bound.id), "minlength") == "5"

      view |> element("#pb-rule-form-minlength") |> render_change(%{"value" => ""})

      assert is_nil(Node.attr(node_again(view, bound.id), "minlength"))
    end

    test "the success message is written on the form", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      view
      |> element("#pb-rule-form-success")
      |> render_change(%{"value" => "Thanks — we got it."})

      assert Node.attr_text(node_again(view, form.id), "data-success") == "Thanks — we got it."
    end

    # ONE UNDO STEP, ALL FIVE NAMES. Five ops would be five steps, and four of them would leave the
    # form's id, param name, page assign and two event names disagreeing about what this form is.
    test "renaming a form moves all five derived names together", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Sales Enquiry"})

      renamed = node_again(view, form.id)
      assert Node.attr_text(renamed, "id") == "sales_enquiry-form"
      assert Node.attr(renamed, "as") == {:expr, ":sales_enquiry"}
      assert Node.attr(renamed, "for") == {:expr, "assigns[:sales_enquiry_form]"}

      # NOTHING ANSWERS THE OLD NAMES, so the rename tags the form.
      assert Node.attr_text(renamed, "phx-change") =~ ~r/^sales_enquiry-[a-z2-7]{5}-validate$/
      assert Node.attr_text(renamed, "phx-submit") =~ ~r/^sales_enquiry-[a-z2-7]{5}-submit$/

      undo!(view)

      back = node_again(view, form.id)
      assert Node.attr_text(back, "id") == "contact-form"
      assert Node.attr(back, "as") == {:expr, ":contact"}
      assert Node.attr(back, "for") == {:expr, "assigns[:contact_form]"}
      assert Node.attr_text(back, "phx-change") == "contact_validate"
      assert Node.attr_text(back, "phx-submit") == "contact_submit"
    end

    test "a seed another form holds is refused and writes nothing", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @two_forms)
      {:ok, view, _html} = open_builder(conn, page)
      [_first, second] = tagged(view, ".form")
      inspecting(view, second)

      html = view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Contact"})

      assert html =~ "already called"

      untouched = node_again(view, second.id)
      assert Node.attr(untouched, "as") == {:expr, ":signup"}
      assert Node.attr_text(untouched, "id") == "signup-form"
      assert Node.attr_text(untouched, "phx-submit") == "signup_submit"
    end

    # A PRE-TOKEN FORM'S HANDLER MOVES WITH IT for a code author (spec 0.8): the rename tags the
    # form, and leaving it stores the handler under the tagged name, so the custom code still runs.
    test "a code author's rename of a pre-token form carries its stored handler along", %{
      conn: conn,
      site: site
    } do
      body = "{:noreply, Phoenix.Component.assign(socket, :custom_ran, true)}"
      page = legacy_page!(site, [%{name: "contact_submit", code: body}])
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      refute has_element?(view, "#pb-rule-warning")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enq"})
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})
      render(view)

      submit = Node.attr_text(node_again(view, form.id), "phx-submit")
      assert submit =~ ~r/^enquiry-[a-z2-7]{5}-submit$/
      assert stored_names(page) == [submit]

      module = :"Elixir.RenamedPreTokenPage#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Contact",
          page_module: module,
          template: Serializer.serialize(editor(view).tree),
          events: Enum.map(stored_events(page), &%{name: &1.name, code: &1.code})
        })

      {:ok, ^module, _diagnostics} =
        MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

      assert {:noreply, %{assigns: %{custom_ran: true}}} =
               module.handle_event(submit, %{"enquiry" => %{}}, %Phoenix.LiveView.Socket{
                 assigns: %{__changed__: %{}}
               })
    end

    # THE NAME BOX COMMITS AS IT IS TYPED, and the warning is read off the form as it was before the
    # first commit, so it does not vanish with the old seed.
    test "the warning about code that mentions the form stays after the name box commits", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "save", code: "socket.assigns[:contact_form]"}])
      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, node_with_tag(view, ".form"))

      assert has_element?(view, "#pb-rule-warning")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "c"})

      assert view |> element("#pb-rule-warning") |> render() =~
               "Code someone wrote for this form stops running if you rename it."
    end

    test "a tagged form keeps its token through a rename, and raises no warning", %{
      conn: conn,
      site: site
    } do
      tagged =
        @bound_form
        |> String.replace("contact_validate", "contact-k7m2q-validate")
        |> String.replace("contact_submit", "contact-k7m2q-submit")

      page =
        create_page!(
          site_id: site.id,
          template: tagged,
          events: [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}]
        )

      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      refute has_element?(view, "#pb-rule-warning")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      renamed = node_again(view, form.id)
      assert Node.attr_text(renamed, "phx-change") == "enquiry-k7m2q-validate"
      assert Node.attr_text(renamed, "phx-submit") == "enquiry-k7m2q-submit"
    end

    test "a rename is announced on builder:form:after_rename", %{conn: conn, site: site} do
      Process.register(self(), FormRenamedProbe.waiter())
      register_plugin(FormRenamedProbe, "builder:form:after_rename")

      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      assert_receive {FormRenamedProbe, summary}
      assert summary.node_id == form.id
      assert summary.from == "contact"
      assert summary.to == "enquiry"
      assert summary.token =~ ~r/^[a-z2-7]{5}$/
      assert summary.submit == "enquiry-#{summary.token}-submit"
      assert summary.change == "enquiry-#{summary.token}-validate"
      assert summary.resource_id == page.id

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      refute_receive {FormRenamedProbe, _unchanged}, 200
    end

    # THE STORED NAME FOLLOWS THE FORM, for whoever may write code (spec 0.8): when they leave a
    # renamed form, and at their next code Save.
    defp tagged_page!(site, events) do
      template =
        @bound_form
        |> String.replace("contact_validate", "contact-k7m2q-validate")
        |> String.replace("contact_submit", "contact-k7m2q-submit")
        |> String.replace(~s(<div id="root">), ~s(<div id="root"><h2>Hi</h2>))

      create_page!(site_id: site.id, template: template, events: events)
    end

    defp legacy_page!(site, events) do
      template = String.replace(@bound_form, ~s(<div id="root">), ~s(<div id="root"><h2>Hi</h2>))

      create_page!(site_id: site.id, template: template, events: events)
    end

    defp stored_events(page) do
      MishkaCmsCore.Runtime.Page
      |> Ash.get!(page.id, authorize?: false, tenant: page.site_id)
      |> Map.fetch!(:events)
    end

    defp stored_names(page), do: page |> stored_events() |> Enum.map(& &1.name)

    defp rename_then_leave(view, name) do
      form = node_with_tag(view, ".form")
      inspecting(view, form)
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => name})
      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})

      # The selection arrives as the session's broadcast; this render is handled after it.
      render(view)
    end

    test "a code author's stored handler takes the form's new event name on leaving it", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)

      rename_then_leave(view, "Enquiry")

      assert stored_names(page) == ["enquiry-k7m2q-submit"]
      assert [%{"name" => "enquiry-k7m2q-submit"}] = fragments(view).events
    end

    test "the stored code is read again first, so an older copy is never written back", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)

      # Another tab saves a handler after this one loaded the page.
      elsewhere = create_admin("elsewhere#{System.unique_integer([:positive])}@example.com")

      MishkaCmsCore.Runtime.Page
      |> Ash.get!(page.id, action: :master_get, actor: elsewhere)
      |> Ash.Changeset.for_update(
        :master_update,
        %{
          events: [
            %{name: "contact-k7m2q-submit", code: "{:noreply, socket}"},
            %{name: "save", code: "{:noreply, socket}"}
          ]
        },
        actor: elsewhere
      )
      |> Ash.update!(actor: elsewhere)

      rename_then_leave(view, "Enquiry")

      assert stored_names(page) == ["enquiry-k7m2q-submit", "save"]
    end

    test "staying on the form writes nothing yet", %{conn: conn, site: site} do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, node_with_tag(view, ".form"))

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      render(view)

      assert Node.attr_text(node_with_tag(view, ".form"), "phx-submit") == "enquiry-k7m2q-submit"
      assert stored_names(page) == ["contact-k7m2q-submit"]
    end

    test "a code Save stores a handler under the form's current event name", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [])
      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, node_with_tag(view, ".form"))
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      render_click(view, "add_code", %{"tab" => "events"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "entry" => %{"0" => %{"name" => "contact-k7m2q-submit", "code" => "{:noreply, socket}"}}
      })

      assert stored_names(page) == ["enquiry-k7m2q-submit"]
    end

    test "a code Save moves a pre-token form's handler to the name its rename tagged", %{
      conn: conn,
      site: site
    } do
      page = legacy_page!(site, [%{name: "contact_submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "entry" => %{"0" => %{"name" => "contact_submit", "code" => "{:noreply, socket}"}}
      })

      submit = Node.attr_text(node_again(view, form.id), "phx-submit")
      assert submit =~ ~r/^enquiry-[a-z2-7]{5}-submit$/
      assert stored_names(page) == [submit]
    end

    # THE CODE WINDOW HOLDS EDITS NOT SAVED YET. A tab switch keeps them, and leaving the form from
    # the Styles index follows them rather than replacing them with the row.
    test "unsaved code in the Code window survives leaving a renamed form", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)

      heading = node_with_tag(view, "h2")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})
      scope = Tree.scope(editor(view).tree, heading.id)

      inspecting(view, node_with_tag(view, ".form"))
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      edited = "{:noreply, Phoenix.Component.assign(socket, :edited, true)}"

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "go" => "styles",
        "entry" => %{"0" => %{"name" => "contact-k7m2q-submit", "code" => edited}}
      })

      view |> element("#pb-style-rule-go-#{scope}") |> render_click()
      render(view)

      assert stored_names(page) == ["enquiry-k7m2q-submit"]
      assert [%{"name" => "enquiry-k7m2q-submit", "code" => ^edited}] = fragments(view).events
    end

    # A READ THAT FAILS WRITES NOTHING: the tab's own copy may be older than the row. A site admin
    # reads through the archive filter, so an archived row is hidden from the editor's re-read, and
    # it is brought back for anything after it.
    #
    # THE RENAME'S OWN WRITES ARE AWAITED FIRST. It starts a draft autosave and a history flush, and
    # both read the page from their own processes; one still running when the row is archived
    # missed it before the editor did, brought it back, and the editor then wrote.
    test "a row that cannot be read again is not written from the tab's older copy", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])

      tenant =
        create_admin("tenant-left#{System.unique_integer([:positive])}@example.com", site.id)

      {:ok, view, _html} = conn |> log_in(tenant) |> open_builder(page)

      elsewhere = create_admin("elsewhere#{System.unique_integer([:positive])}@example.com")

      MishkaCmsCore.Runtime.Page
      |> Ash.get!(page.id, action: :master_get, actor: elsewhere)
      |> Ash.Changeset.for_update(
        :master_update,
        %{
          events: [
            %{name: "contact-k7m2q-submit", code: "{:noreply, socket}"},
            %{name: "save", code: "{:noreply, socket}"}
          ]
        },
        actor: elsewhere
      )
      |> Ash.update!(actor: elsewhere)

      inspecting(view, node_with_tag(view, ".form"))
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      _written = render_async(view)

      set_archived!(page.id, true)
      handler = "unreadable-page-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:mishka_cms_core, :repo, :query],
        &__MODULE__.restore_after_miss/4,
        %{handler: handler, page_id: page.id, editor: view.pid}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})
      render(view)

      assert :telemetry.list_handlers([:mishka_cms_core, :repo, :query])
             |> Enum.all?(&(&1.id != handler)),
             "the editor read the row again, and missed it"

      assert stored_names(page) == ["contact-k7m2q-submit", "save"]
    end
  end

  # Brings the page back after the editor's own read missed it. A telemetry handler is global and
  # runs in whichever process made the query, so a miss from any other process is left alone.
  def restore_after_miss(
        _event,
        _measurements,
        %{source: "pages", result: {:ok, %{num_rows: 0}}},
        %{editor: editor} = config
      )
      when editor == self() do
    :telemetry.detach(config.handler)
    set_archived!(config.page_id, false)
  end

  def restore_after_miss(_event, _measurements, _metadata, _config), do: :ok

  # Without code permission the stored name stays; the handler still runs, followed by its token.
  describe "leaving a renamed form without code permission" do
    setup do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      :ok
    end

    test "writes no stored handler", %{conn: conn, site: site} do
      template =
        @bound_form
        |> String.replace("contact_validate", "contact-k7m2q-validate")
        |> String.replace("contact_submit", "contact-k7m2q-submit")
        |> String.replace(~s(<div id="root">), ~s(<div id="root"><h2>Hi</h2>))

      page =
        create_page!(
          site_id: site.id,
          template: template,
          events: [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}]
        )

      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      render_click(view, "select", %{"id" => form.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})
      render(view)

      assert Node.attr_text(Tree.get(editor(view).tree, form.id), "phx-submit") ==
               "enquiry-k7m2q-submit"

      reloaded =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert Enum.map(reloaded.events, & &1.name) == ["contact-k7m2q-submit"]

      refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.flash, "error"),
             "leaving the form must not try a code write this deployment refuses"
    end

    # A PRE-TOKEN FORM'S HANDLER CANNOT MOVE without code permission, so every keystroke of the
    # rename keeps the untagged names, the section says what stops, and the old name reattaches it.
    test "a pre-token form a stored handler answers keeps its untagged names", %{
      conn: conn,
      site: site
    } do
      page = legacy_page!(site, [%{name: "contact_submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      stops = "contact_submit on the Handlers tab will stop being called."
      assert view |> element("#pb-rule-warning") |> render() =~ stops

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry Form"})

      renamed = node_again(view, form.id)
      assert Node.attr_text(renamed, "phx-submit") == "enquiry_form_submit"
      assert Node.attr_text(renamed, "phx-change") == "enquiry_form_validate"
      assert view |> element("#pb-rule-warning") |> render() =~ stops

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Contact"})

      assert Node.attr_text(node_again(view, form.id), "phx-submit") == "contact_submit"
    end
  end

  describe "a page's starting state on the Code tab" do
    defp stored_state(page) do
      MishkaCmsCore.Runtime.Page
      |> Ash.get!(page.id, authorize?: false, tenant: page.site_id)
      |> Map.fetch!(:state)
      |> Enum.map(&{&1.name, &1.code})
    end

    defp state_tab(view) do
      view |> element("#pb-code") |> render_click()
      view |> element("#pb-sourcetab-state") |> render_click()
    end

    test "is a tab of its own, and saving it writes the assigns the page starts with", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~S|<p>{@count}</p>|,
          state: [%{name: "count", code: "0"}]
        )

      {:ok, view, _html} = open_builder(conn, page)
      state_tab(view)

      assert has_element?(view, "#pb-code-entry-state-0")
      assert render(view) =~ "@count ="

      render_click(view, "save_code", %{
        "tab" => "state",
        "entry" => %{
          "0" => %{"name" => "count", "code" => "10"},
          "1" => %{"name" => "step", "code" => "5"}
        }
      })

      assert stored_state(page) == [{"count", "10"}, {"step", "5"}]
    end

    test "a name the runtime already sets is refused, and the page keeps its state", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<p>x</p>", state: [%{name: "count", code: "0"}])

      {:ok, view, _html} = open_builder(conn, page)
      state_tab(view)

      render_click(view, "save_code", %{
        "tab" => "state",
        "entry" => %{"0" => %{"name" => "flash", "code" => "%{}"}}
      })

      assert stored_state(page) == [{"count", "0"}]
    end

    test "a layout has no state to declare, so it is offered no tab", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: ~s(<main>{@inner_content}</main>))

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      view |> element("#pb-code") |> render_click()

      refute has_element?(view, "#pb-sourcetab-state")
    end
  end

  describe "a page's forms on the Handlers tab" do
    test "lists both deep forms, each with its On change and On submit, Automatic", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      handlers_tab(view)

      contact = with_dom_id(view, "contact-form")
      news = with_dom_id(view, "news-form")

      assert has_element?(view, "#pb-form-handlers #pb-form-handlers-#{contact.id}", "Contact")
      assert has_element?(view, "#pb-form-handlers #pb-form-handlers-#{news.id}", "News")

      for event <- @deep_events do
        assert has_element?(view, ~s(#pb-form-handler-#{event}[data-custom="false"]), "Automatic")
        assert has_element?(view, "#pb-form-customize-#{event}")
      end

      assert has_element?(
               view,
               "#pb-code-form p",
               "No custom handlers. The forms above run on their own."
             )
    end

    test "a stored handler marks its own form's event Custom, even under an older name", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["enquiry-p3xa6-submit"]))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      assert has_element?(
               view,
               ~s(#pb-form-handler-news-p3xa6-submit[data-custom="true"]),
               "Custom"
             )

      refute has_element?(view, "#pb-form-customize-news-p3xa6-submit")
      assert has_element?(view, ~s(#pb-form-handler-contact-k7m2q-submit[data-custom="false"]))
      refute has_element?(view, "#pb-code-form p", "No custom handlers")
    end

    test "a page with no form shows no forms and the usual empty note", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      refute has_element?(view, "#pb-form-handlers")
      assert has_element?(view, "#pb-code-form p", "No handlers yet.")
    end

    test "Customize keeps what was typed and adds the default code, focused, storing nothing", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["save"]))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      typed = "{:noreply, Phoenix.Component.assign(socket, :typed, true)}"
      customize!(view, "news-p3xa6-submit", %{"entry" => %{"0" => %{"code" => typed}}})

      assert [
               %{"name" => "save", "code" => ^typed},
               %{"name" => "news-p3xa6-submit", "code" => code}
             ] = fragments(view).events

      assert code ==
               ~s|IO.inspect(params, label: "news-p3xa6-submit")\n| <>
                 ~s|MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), "news-p3xa6-submit", params)|

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")
      refute has_element?(view, "#pb-code-entry-events-0[data-focus]")

      assert has_element?(
               view,
               ~s(#pb-form-handler-news-p3xa6-submit[data-custom="true"]),
               "Custom"
             )

      refute has_element?(view, "#pb-form-customize-news-p3xa6-submit")
      assert has_element?(view, "#pb-form-customize-contact-k7m2q-submit")

      assert stored_names(page) == ["save"]
    end

    test "Customize on change writes the checking default for that form alone", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      handlers_tab(view)

      customize!(view, "contact-k7m2q-validate")

      assert [%{"name" => "contact-k7m2q-validate", "code" => code}] = fragments(view).events

      assert code ==
               LiveViewCompiler.form_handler_sample(:validate, "contact-k7m2q-validate")

      assert code =~
               ~s|{:noreply, MishkaCmsCore.Runtime.PageForm.validate(socket, __page_forms__(), "contact-k7m2q-validate", params)}|

      assert has_element?(view, ~s(#pb-form-handler-news-p3xa6-validate[data-custom="false"]))
    end

    test "a second Customize of the same event adds nothing and focuses the entry", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site, written(["save"])))
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")
      [save, news] = fragments(view).events

      render_click(view, "save_code", %{
        "tab" => "events",
        "customize" => "news-p3xa6-submit",
        "entry" => %{"0" => news, "1" => save}
      })

      assert fragments(view).events == [news, save]
      assert has_element?(view, "#pb-code-entry-events-0[data-focus]")
    end

    test "Customize for an event no form names any more keeps the typing and adds nothing", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["save"]))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      render_click(view, "save_code", %{
        "tab" => "events",
        "customize" => "gone-aaaaa-submit",
        "entry" => %{"0" => %{"name" => "save", "code" => ":kept"}}
      })

      assert fragments(view).events == [%{"name" => "save", "code" => ":kept"}]
      assert [%{name: "save", code: "{:noreply, socket}"}] = stored_events(page)
    end

    test "leaving Handlers by a tab button forgets the focus, so no Messages entry takes it", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["a", "b"]), infos: messages(3))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      customize!(view, "contact-k7m2q-submit")
      assert has_element?(view, "#pb-code-entry-events-2[data-focus]")

      view
      |> form("#pb-code-form", %{})
      |> put_submitter("#pb-sourcetab-infos")
      |> render_submit()

      assert has_element?(view, "#pb-code-entry-infos-2")
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "removing an entry forgets the focus, so the entry moving into its place does not take it",
         %{conn: conn, site: site} do
      page = deep_forms_page!(site, written(["a", "news-p3xa6-submit", "c"]))
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_source", %{
        "tab" => "events",
        "form" => with_dom_id(view, "news-form").id
      })

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")

      view |> element("#pb-code-remove-events-0") |> render_click()

      assert has_element?(view, "#pb-code-entry-events-1")
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "a refused Save forgets the focus", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site, written(["a"])))
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")
      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")

      view
      |> form("#pb-code-form", %{"entry" => %{"0" => %{"code" => "{:noreply,"}}})
      |> render_submit()

      assert flashes(view) =~ "a:"
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "leaving the window for an element forgets the focus it opened with", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["a", "news-p3xa6-submit"]))
      {:ok, view, _html} = open_builder(conn, page)
      news = with_dom_id(view, "news-form")

      render_click(view, "open_source", %{"tab" => "events", "form" => news.id})
      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")

      render_click(view, "select_from_code", %{"id" => news.id})
      refute has_element?(view, "#pb-source-modal")

      view |> element("#pb-code") |> render_click()

      assert has_element?(view, "#pb-code-entry-events-1")
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "Save stores the customized default, which still does not count as receiving it", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")
      view |> form("#pb-code-form") |> render_submit()

      assert [%{name: "news-p3xa6-submit", code: code}] = stored_events(page)
      assert code == LiveViewCompiler.form_handler_sample(:submit, "news-p3xa6-submit")

      view |> element("#pb-source-close") |> render_click()
      open_audit(view)

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-destination-#{with_dom_id(view, "news-form").id}"
             )
    end

    test "announces builder:form:after_customize", %{conn: conn, site: site} do
      Process.register(self(), FormCustomizedProbe.waiter())
      register_plugin(FormCustomizedProbe, "builder:form:after_customize")

      page = deep_forms_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")

      assert_receive {FormCustomizedProbe, summary}
      assert summary.event == "news-p3xa6-submit"
      assert summary.kind == :submit
      assert summary.node_id == with_dom_id(view, "news-form").id
      assert summary.resource_id == page.id
    end
  end

  # A RENAME MOVES A PRE-TOKEN FORM'S OWN HANDLER AT SAVE. Until then the editor counts it under the
  # name it moves to, so nothing offers the form a second handler that would stop it moving.
  describe "a pre-token form a code author renamed, before the rename is saved" do
    test "its own handler reads Custom, and Customize and the note's Fix focus it", %{
      conn: conn,
      site: site
    } do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      stores =
        &~s|MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), "#{&1}", params, fn values -> {:ok, values} end)|

      page =
        create_page!(
          site_id: site.id,
          template: @legacy_deep_forms,
          events: [
            %{name: "contact_submit", code: stores.("contact_submit")},
            %{name: "news_submit", code: stores.("news_submit")}
          ]
        )

      {:ok, view, _html} = open_builder(conn, page)
      forms = Enum.map(~w(contact-form news-form), &with_dom_id(view, &1))

      for {form, name, index} <- Enum.zip([forms, ~w(Letters Digest), [0, 1]]) do
        inspecting(view, form)
        view |> element("#pb-rule-form-seed") |> render_change(%{"value" => name})

        submit = Node.attr_text(node_again(view, form.id), "phx-submit")
        assert submit =~ ~r/-[a-z2-7]{5}-submit$/
        assert has_element?(view, ~s(#pb-form-card-submit[data-custom="true"]), "Custom")

        view |> element("#pb-form-edit-in-code") |> render_click()

        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")
        refute has_element?(view, "#pb-form-handlers-#{form.id}[data-focus]")
        assert has_element?(view, ~s(#pb-form-handler-#{submit}[data-custom="true"]))
        refute has_element?(view, "#pb-form-customize-#{submit}")

        render_click(view, "save_code", %{
          "tab" => "events",
          "customize" => submit,
          "entry" => view |> fragments() |> Map.fetch!(:events) |> indexed()
        })

        assert length(fragments(view).events) == 2
        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")

        view |> element("#pb-source-close") |> render_click()
        open_audit(view)
        note_fix(view, form)

        assert length(fragments(view).events) == 2
        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")

        view |> form("#pb-code-form") |> render_submit()

        assert stored_names(page) ==
                 Enum.map(forms, &Node.attr_text(node_again(view, &1.id), "phx-submit"))

        assert Enum.find(stored_events(page), &(&1.name == submit)).code == stores.(submit)
        view |> element("#pb-source-close") |> render_click()
      end
    end
  end

  # A form the Handlers tab cannot list yet, because it has no name or no source: each Fix of the
  # note finishes one thing, and then the form's On submit opens in code.
  describe "the note's Fix on a form that is not finished" do
    @unfinished ~s(<div id="root"><h1>Hi</h1>) <>
                  ~s(<form id="search-form" phx-submit="search_go"><div class="card"><div class="grid"><div class="col"><input type="search" name="q" /></div><div class="col"><button type="submit">Go</button></div></div></div></form>) <>
                  ~s(<.form :let={f} id="q-form" for={assigns[:q_form]} phx-submit="q_submit"><div class="card"><div class="grid"><div class="col"><input name={f[:q].name} /></div><div class="col"><button type="submit">Ask</button></div></div></div></.form>) <>
                  ~s(<.component component_name="chelekom-form-wrapper" site="localhost" id="join-form"><div class="card"><div class="grid"><div class="col"><input name="email" /></div><div class="col"><button type="submit">Join</button></div></div></div></.component>) <>
                  ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div class="col"><input name={f[:email].name} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>) <>
                  ~s(<form id="find-form" action="/search" method="get"><div class="card"><div class="grid"><div class="col"><input type="search" name="q" /></div><div class="col"><button type="submit">Find</button></div></div></div></form></div>)

    defp unfinished_page!(site) do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))
      create_page!(site_id: site.id, template: @unfinished)
    end

    # Presses the note's Fix on the form with this DOM id until it opens the Code window, and
    # answers how many presses edited the form first.
    defp fix_until_code(view, dom_id) do
      Enum.reduce_while(0..4, nil, fn edits, _none ->
        note_fix(view, with_dom_id(view, dom_id))
        render(view)

        case has_element?(view, "#pb-source-modal") do
          true -> {:halt, edits}
          false -> {:cont, nil}
        end
      end)
    end

    test "gives each form its name, source and submit event, then opens its On submit", %{
      conn: conn,
      site: site
    } do
      page = unfinished_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      for {dom_id, clicks, event} <- [
            {"search-form", 2, "search_go"},
            {"q-form", 1, "q_submit"},
            {"join-form", 3, "join_submit"}
          ] do
        assert fix_until_code(view, dom_id) == clicks

        form = with_dom_id(view, dom_id)
        assert Node.attr_text(form, "phx-submit") == event
        assert has_element?(view, "#pb-form-handlers-#{form.id}")

        index =
          view |> fragments() |> Map.fetch!(:events) |> Enum.find_index(&(&1["name"] == event))

        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")

        view |> element("#pb-source-close") |> render_click()
        open_audit(view)
      end

      assert stored_events(page) == []
    end

    test "a form that posts to its own address raises no note", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, unfinished_page!(site))
      open_audit(view)

      find = with_dom_id(view, "find-form")
      refute has_element?(view, "#pb-audit-fix-form-no-destination-#{find.id}")

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-destination-#{with_dom_id(view, "q-form").id}"
             )
    end

    test "the card of a form with no name offers no Edit in Code, and says why", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, unfinished_page!(site))
      inspecting(view, with_dom_id(view, "q-form"))

      assert has_element?(
               view,
               "#pb-form-handlers-card #pb-form-card-unnamed",
               "Give this form a name above to write code for it."
             )

      refute has_element?(view, "#pb-form-edit-in-code")

      inspecting(view, with_dom_id(view, "contact-form"))

      assert has_element?(view, "#pb-form-edit-in-code")
      refute has_element?(view, "#pb-form-card-unnamed")
    end
  end

  describe "the note that nothing receives a form" do
    test "is counted against nothing: the score and summary match a page whose forms have code",
         %{
           conn: conn,
           site: site
         } do
      {:ok, noted, _html} = open_builder(conn, deep_forms_page!(site))
      open_audit(noted)

      received =
        create_page!(site_id: site.id, template: @two_deep_forms, events: written(@deep_events))

      {:ok, handled, _html} = open_builder(conn, received)
      open_audit(handled)

      assert has_element?(noted, "#pb-audit-badge-forms", "2 notes")
      assert has_element?(handled, "#pb-audit-badge-forms", "healthy")

      for id <- ~w(#pb-audit-score #pb-audit-summary) do
        assert noted |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() ==
                 handled |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      end
    end

    test "its Fix opens each deep form's own On submit, customized once, stored never", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      news = with_dom_id(view, "news-form")
      contact = with_dom_id(view, "contact-form")

      note_fix(view, news)

      assert has_element?(view, "#pb-source-modal #pb-form-handlers")
      assert [%{"name" => "news-p3xa6-submit"}] = fragments(view).events
      assert has_element?(view, "#pb-code-entry-events-0[data-focus]")

      note_fix(view, news)
      assert length(fragments(view).events) == 1

      note_fix(view, contact)

      assert [%{"name" => "news-p3xa6-submit"}, %{"name" => "contact-k7m2q-submit"}] =
               fragments(view).events

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")
      assert stored_events(page) == []
    end
  end

  describe "the Form section's handlers card, for a code author" do
    test "folds away with the Form section", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for dom_id <- ~w(contact-form news-form) do
        inspecting(view, with_dom_id(view, dom_id))
        assert has_element?(view, "#pb-form-handlers-card #pb-form-edit-in-code")

        view |> element("#pb-section-form") |> render_click()

        refute has_element?(view, "#pb-form-handlers-card")
        refute has_element?(view, "#pb-form-edit-in-code")

        view |> element("#pb-section-form") |> render_click()
        assert has_element?(view, "#pb-form-handlers-card")
      end
    end

    test "shows each deep form's two events, and Edit in Code opens its row", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)

      assert has_element?(
               view,
               ~s(#pb-form-handlers-card #pb-form-card-validate[data-custom="false"]),
               "contact-k7m2q-validate"
             )

      assert has_element?(view, ~s(#pb-form-card-submit[data-custom="false"]), "Automatic")
      refute has_element?(view, "#pb-form-card-sending")

      view |> element("#pb-form-edit-in-code") |> render_click()

      assert has_element?(view, "#pb-source-modal #pb-form-handlers-#{contact.id}[data-focus]")
      assert fragments(view).events == []
    end

    test "a form with code shows it Custom, and Edit in Code focuses that entry", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["save", "news-p3xa6-submit"]))
      {:ok, view, _html} = open_builder(conn, page)
      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      assert has_element?(view, ~s(#pb-form-card-submit[data-custom="true"]), "Custom")
      assert has_element?(view, ~s(#pb-form-card-validate[data-custom="false"]), "Automatic")

      view |> element("#pb-form-edit-in-code") |> render_click()

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")
      refute has_element?(view, "#pb-form-handlers-#{news.id}[data-focus]")
    end
  end

  describe "a page's forms for someone without code permission" do
    setup do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      :ok
    end

    test "the handlers card reads two sentences and no event name", %{conn: conn, site: site} do
      {:ok, view, _html} =
        open_builder(conn, deep_forms_page!(site, written(["news-p3xa6-submit"])))

      for {id, sending} <- [
            {"contact-form",
             "When they press Send: nothing stores or sends what visitors type yet."},
            {"news-form", "When they press Send: your own code receives it."}
          ] do
        inspecting(view, with_dom_id(view, id))

        assert has_element?(
                 view,
                 "#pb-form-card-typing",
                 "While a visitor types: the fields are checked."
               )

        assert has_element?(view, "#pb-form-card-sending", sending)
        refute has_element?(view, "#pb-form-edit-in-code")
        refute has_element?(view, "#pb-form-card-submit")

        card = view |> element("#pb-form-handlers-card") |> render()
        refute card =~ ~r/k7m2q|p3xa6|validate|submit/
      end
    end

    test "a form that works as they type says where what they type goes, not when they press Send",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for dom_id <- ~w(contact-form news-form) do
        inspecting(view, with_dom_id(view, dom_id))
        view |> element("#pb-rule-how-typing") |> render_click()

        assert has_element?(
                 view,
                 "#pb-form-card-sending",
                 "What they type: nothing stores or sends what visitors type yet."
               )

        refute has_element?(view, "#pb-form-card-sending", "press Send")

        view |> element("#pb-rule-how-send") |> render_click()
        inspecting(view, with_dom_id(view, dom_id))
        assert has_element?(view, "#pb-form-card-sending", "When they press Send:")
      end
    end

    test "the sentences fold away with the Form section", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for dom_id <- ~w(contact-form news-form) do
        inspecting(view, with_dom_id(view, dom_id))
        assert has_element?(view, "#pb-form-card-sending")

        view |> element("#pb-section-form") |> render_click()
        refute has_element?(view, "#pb-form-card-sending")

        view |> element("#pb-section-form") |> render_click()
        assert has_element?(view, "#pb-form-card-sending")
      end
    end

    test "cannot open the Handlers tab, from the card's route or from the Code window", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")

      render_click(view, "open_source", %{"tab" => "events", "form" => contact.id})

      refute has_element?(view, "#pb-source-modal")
      assert flashes(view) =~ CodeAccess.refusal()
      clear_flashes(view)

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})

      assert flashes(view) =~ CodeAccess.refusal()
      assert has_element?(view, "#pb-source-form")
      refute has_element?(view, "#pb-code-form")
      refute has_element?(view, "#pb-form-handlers")

      render_click(view, "save_code", %{"tab" => "events", "customize" => "contact-k7m2q-submit"})

      assert fragments(view).events == []
    end

    test "a Code window left on a code tab still draws no code", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site, written(["save"])))
      view |> element("#pb-code") |> render_click()

      :sys.replace_state(view.pid, fn state ->
        %{state | socket: Phoenix.Component.assign(state.socket, :source_tab, :events)}
      end)

      render_click(view, "zoom_reset", %{})

      refute has_element?(view, "#pb-code-form")
      refute has_element?(view, "#pb-form-handlers")
    end

    test "the note's Fix reads a plain sentence and opens nothing", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      open_audit(view)

      note_fix(view, with_dom_id(view, "news-form"))

      refute has_element?(view, "#pb-source-modal")
      assert flashes(view) =~ "Ask whoever writes code for this site"
      refute flashes(view) =~ ~r/p3xa6|submit|handler/
      assert fragments(view).events == []
    end
  end

  # THE FORM MACHINERY IS THE PAGE'S. Every control in the Form section writes `phx-change`,
  # `phx-submit` or the `for=` they are bound through, and two of the Validation controls write
  # `data-format` / `data-confirms`, which nothing checks but the page's own form runtime. The other
  # six validation controls are HTML attributes a browser enforces on its own, everywhere.
  describe "the form controls a section can use" do
    # A field only counts as validated when it is BOUND through the form's `:let` — a bare
    # `<input name="email">` is markup, not a form field, so this is the shape the form blocks ship.
    @bound_form ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><.input field={f[:email]} type="email" required /></.form>)

    defp bound_field(view) do
      node = Enum.find(Tree.walk(editor(view).tree), &(&1.tag == ".input"))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})
      render(view)
    end

    test "a page gets the Form section and every validation rule", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: "<div>#{@bound_form}</div>")
      {:ok, view, _html} = open_builder(conn, page)

      html = bound_field(view)

      assert html =~ "Pattern", "an HTML rule the browser enforces"
      assert html =~ "Confirms", "and one only the page's own form runtime checks"
    end

    test "a layout keeps the browser's rules and loses the other two", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "formish-shell",
          site_id: site.id,
          template: ~s(<div id="shell">#{@bound_form}{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _loaded = render_async(view)

      html = bound_field(view)

      assert html =~ "Pattern", "the browser-enforced rules belong everywhere"
      refute html =~ "Confirms", "nothing on a layout reads data-confirms"
      refute html =~ "Format", "nor data-format"
    end

    # Asked of the resource, so the answer follows the columns rather than a list kept in the panel.
    test "and the question asked is which resource holds handlers" do
      assert Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Page, :events)

      for resource <- [
            MishkaCmsCore.Runtime.Layout,
            MishkaCmsCore.Runtime.Component,
            MishkaCmsCore.Runtime.ErrorPage
          ] do
        refute Ash.Resource.Info.attribute(resource, :events),
               "#{inspect(resource)} holds no handlers, so it gets no form controls"
      end
    end
  end

  # A FIELD JOINS A FORM, spec 4.4. Two forms on a page, fields three levels down (card > grid >
  # column): Phoenix's own with its Send in the card footer, and a raw `<form>` that does not work.
  describe "a field joining a form" do
    @joining ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit">) <>
               ~s(<div id="c-card" class="card"><div id="c-grid" class="grid"><div id="c-col"><input id="name-box" name={f[:name].name} /></div>) <>
               ~s(<div id="c-col-2"><label id="agree-label"><input type="hidden" name={f[:agree].name} value="false" /><input id="agree-box" type="checkbox" name={f[:agree].name} value="true" />I agree</label></div></div>) <>
               ~s(<footer id="c-foot"><button id="c-send" type="submit">Send</button></footer></div></.form>) <>
               ~s(<.form :let={g} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">) <>
               ~s(<div class="card"><div class="grid"><div id="n-col"><input id="news-email" name={g[:email].name} /></div></div></div><button id="n-send" type="submit">Join</button></.form>) <>
               ~s(<form id="raw-form"><input name="q" /></form><section id="band"><div id="loose"></div></section></div>)

    defp joining(conn, site) do
      page = create_page!(site_id: site.id, template: @joining)
      {:ok, view, _html} = open_builder(conn, page)
      view
    end

    defp dom(view, id),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "id") == id))

    test "the canvas marks each form with its people name and where a field at its end lands", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(
               canvas,
               ~s([data-node-id="#{dom(view, "contact-form").id}"][data-pb-form="Contact"])
             )

      assert has_element?(
               canvas,
               ~s([data-node-id="#{dom(view, "news-form").id}"][data-pb-form="News"])
             )

      assert has_element?(
               canvas,
               ~s([data-node-id="#{dom(view, "raw-form").id}"][data-pb-form=""])
             )

      assert has_element?(canvas, ~s([data-node-id="#{dom(view, "c-send").id}"][data-pb-send]))
      assert has_element?(canvas, ~s([data-node-id="#{dom(view, "n-send").id}"][data-pb-send]))
      refute has_element?(canvas, ~s([data-node-id="#{dom(view, "c-col").id}"][data-pb-form]))
      assert render(canvas) =~ "html[data-pb-field-drag] [data-pb-form]"
    end

    # A kit form declares `for` with no default, like Chelekom's Form Wrapper: wired, it names a page
    # assign the canvas does not have, and the canvas still has to draw it.
    test "a kit form that arrived working is drawn on the canvas", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "acme-lends",
        attrs: [
          %{"name" => "for", "type" => "any", "opts" => %{}},
          %{"name" => "as", "type" => "any", "opts" => %{}},
          %{"name" => "id", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ],
        slots: [%{"name" => "inner_block"}],
        template:
          ~S|<.form :let={f} for={@for} as={@as} id={@id} {@rest}>{render_slot(@inner_block, f)}</.form>|
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="acme-lends" site="localhost" :let={f} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><input id="news-email" name={f[:email].name} /></.component></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute render(canvas) =~ "could not render"
      refute render(canvas) =~ "failed to render"
      assert has_element?(canvas, ~s([data-pb-form="News"] form input#news-email))
    end

    test "a drag start says whether a field is being dragged, from either surface", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      for surface <- [view, canvas] do
        render_click(surface, "drag_start", %{"template" => ~s(<input name="phone" />)})
        assert_push_event(surface, "pb:drop-hints", %{field: true, accepts: %{}})

        render_click(surface, "drag_start", %{"node_id" => dom(view, "agree-box").id})
        assert_push_event(surface, "pb:drop-hints", %{field: true})

        render_click(surface, "drag_start", %{"template" => "<section></section>"})
        assert_push_event(surface, "pb:drop-hints", %{field: false})
      end
    end

    test "a field dropped on a form's bottom edge joins it before the Send in its card footer", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      form = dom(view, "contact-form")

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="phone" />),
        "parent_id" => dom(view, "root").id,
        "index" => "1",
        "anchor_id" => form.id,
        "anchor_before" => false
      })

      assert flashes(view) =~ "Added it to the Contact form."
      footer = dom(view, "c-foot")
      [phone, send] = view |> editor() |> Map.fetch!(:tree) |> Tree.children(footer.id)
      assert Node.attr_text(phone, "name") == "f[:phone].name"
      assert Node.attr_text(send, "id") == "c-send"
    end

    test "a field dropped outside every form starts one with a Send button", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="phone" />),
        "parent_id" => dom(view, "loose").id,
        "index" => "0"
      })

      assert flashes(view) =~ "Started a new form with a Send button."
      assert flashes(view) =~ "choose it under In form in the Inspector"

      specs =
        view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() |> PageForms.declared()

      assert Enum.map(specs, & &1.as) == ~w(contact news form)
    end

    test "a form made by a drop is announced on builder:form:after_create", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      view = joining(conn, site)

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="phone" />),
        "parent_id" => dom(view, "loose").id,
        "index" => "0"
      })

      assert_receive {FormCreatedProbe, summary}
      assert summary.how == :started
      assert summary.seed == "form"
      assert summary.token =~ ~r/^[a-z2-7]{5}$/
      assert PageForms.form?(view |> editor() |> Map.fetch!(:tree) |> Tree.get(summary.node_id))

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="fax" />),
        "parent_id" => dom(view, "n-col").id,
        "index" => "0"
      })

      refute_receive {FormCreatedProbe, _joined}, 200
    end

    test "a form made by a drop placed beside a locked column is announced too", %{
      conn: conn,
      site: site
    } do
      renamed_forms!(site)
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<section id="band">),
              ~s(<div class="card"><div class="grid"><div id="l-col"><p>Here</p></div></div></div><section id="band">)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _locked} = EditorSession.toggle_lock(token(view), dom(view, "l-col").id)

      for {template, how} <- [
            {~s(<input type="tel" name="phone" />), :started},
            {~s(<.component component_name="acme-wrapper" site="localhost" for={%{}}><input type="email" name="email" /></.component>),
             :wired}
          ] do
        render_click(view, "drop", %{
          "template" => template,
          "parent_id" => dom(view, "l-col").id,
          "index" => "0"
        })

        assert flashes(view) =~ "That element is locked."
        assert_receive {FormCreatedProbe, %{how: ^how, node_id: id}}

        assert Tree.get(view |> editor() |> Map.fetch!(:tree), id).parent_id !=
                 dom(view, "l-col").id
      end
    end

    test "a form the audit's Fix puts around a field deep in a card is announced as fixed", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<div id="loose"></div>),
              ~s(<div class="card"><div class="grid"><div id="l-col"><input id="stray" name="phone" /></div></div></div>)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()
      view |> element(~s([data-rule="field-no-form"])) |> render_click()

      assert_receive {FormCreatedProbe, %{how: :fixed, seed: "form", node_id: id}}
      tree = view |> editor() |> Map.fetch!(:tree)
      assert PageForms.form?(Tree.get(tree, id))
      assert Tree.get(tree, id).parent_id == dom(view, "l-col").id

      assert tree
             |> Tree.descendant_ids(id)
             |> Enum.any?(&(Node.attr_text(Tree.get(tree, &1), "name") == "f[:phone].name"))

      refute_receive {FormCreatedProbe, _another}, 200
    end

    test "a form the audit's Fix makes work is announced as fixed, a renamed one is not", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<div id="loose"></div>),
              ~s(<div class="card"><div class="grid"><div id="l-col">) <>
                ~s(<.form :let={h} id="bare-form" as={:bare} phx-change="bare-q2w3e-validate" phx-submit="bare-q2w3e-submit"><input name={h[:note].name} /><button type="submit">Send</button></.form>) <>
                ~s(<.form :let={k} id="twin-form" as={:news} for={assigns[:twin_form]} phx-change="news-r4t5y-validate" phx-submit="news-r4t5y-submit"><input name={k[:code].name} /><button type="submit">Send</button></.form>) <>
                ~s(</div></div></div>)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      view
      |> element(~s([data-rule="form-no-source"][phx-value-id="#{dom(view, "bare-form").id}"]))
      |> render_click()

      assert_receive {FormCreatedProbe, %{how: :fixed, seed: "bare", node_id: id}}
      assert id == dom(view, "bare-form").id

      view
      |> element(~s([data-rule="form-duplicate-seed"]))
      |> render_click()

      assert view |> declared_forms() |> Enum.map(& &1.as) |> Enum.sort() ==
               ~w(bare contact news news_2)

      refute_receive {FormCreatedProbe, _renamed}, 200
    end

    test "the Validation note names each form the way Layers does", %{conn: conn, site: site} do
      renamed_forms!(site)

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<div id="loose"></div>),
              ~s(<div id="loose"></div><.component component_name="acme-wrapper" site="localhost" :let={w} id="kit-form" as={:contact_us} for={assigns[:contact_us_form]} phx-change="contact_us-z2x3c-validate" phx-submit="contact_us-z2x3c-submit">) <>
                ~s(<div class="card"><div class="grid"><div id="k-col"><input id="kit-email" name={w[:email].name} /></div></div></div></.component>)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)

      for {name, parent} <- [{"phone", "loose"}, {"fax", "band"}] do
        render_click(view, "drop", %{
          "template" => ~s(<input type="text" name="#{name}" />),
          "parent_id" => dom(view, parent).id,
          "index" => "0"
        })
      end

      bound = fn key ->
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "name") == "f[:#{key}].name"))
      end

      for {node, sentence} <- [
            {bound.("phone"), "phone in Form 1."},
            {bound.("fax"), "fax in Form 2."},
            {dom(view, "name-box"), "name in the Contact form."},
            {dom(view, "kit-email"), "email in the Contact us form."}
          ] do
        render_click(view, "select", %{"id" => node.id})
        view |> element("#pb-lefttab-inspector") |> render_click()

        assert has_element?(view, "#pb-rule-note", sentence), sentence
        refute render(element(view, "#pb-rule-note")) =~ ~r/form form|form_2|contact_us/
      end
    end

    test "a field moved into a new form from In form is announced as moved", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      view = joining(conn, site)
      field_in(view, "agree-box")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => dom(view, "news-form").id})

      refute_receive {FormCreatedProbe, _joined}, 200

      field_in(view, "agree-box")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => FormPlacement.new_target()})

      assert_receive {FormCreatedProbe, %{how: :moved, seed: "form", node_id: id}}
      tree = view |> editor() |> Map.fetch!(:tree)
      assert Tree.descendant?(tree, id, dom(view, "agree-label").id)

      render_click(view, "drop", %{
        "node_id" => dom(view, "name-box").id,
        "parent_id" => dom(view, "loose").id,
        "index" => "0"
      })

      assert_receive {FormCreatedProbe, %{how: :moved, seed: "form_2", node_id: dragged}}
      tree = view |> editor() |> Map.fetch!(:tree)
      assert Tree.descendant?(tree, dragged, dom(view, "name-box").id)
    end

    defp field_in(view, id) do
      render_click(view, "select", %{"id" => dom(view, id).id})
      view |> element("#pb-lefttab-inspector") |> render_click()
    end

    test "a field's Inspector says which form sends it, by people name", %{conn: conn, site: site} do
      view = joining(conn, site)
      field_in(view, "agree-box")

      assert has_element?(view, "#pb-section-in-form", "In form")

      assert has_element?(
               view,
               ~s(#pb-field-form option[value="#{dom(view, "contact-form").id}"][selected]),
               "Contact"
             )

      assert has_element?(
               view,
               ~s(#pb-field-form option[value="#{dom(view, "news-form").id}"]),
               "News"
             )

      assert has_element?(
               view,
               ~s(#pb-field-form option[value="#{FormPlacement.new_target()}"]),
               "A new form"
             )

      refute has_element?(view, ~s(#pb-field-form option[value="#{dom(view, "raw-form").id}"]))

      field_in(view, "c-grid")
      refute has_element?(view, "#pb-field-form")
    end

    test "choosing another form moves the checkbox unit there, as one undo step", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      before = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()
      label = dom(view, "agree-label")
      field_in(view, "agree-box")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => dom(view, "news-form").id})

      assert flashes(view) =~ "Moved it to the News form."
      moved = view |> editor() |> Map.fetch!(:tree)
      assert Tree.get(moved, label.id).parent_id == dom(view, "c-col-2").id
      assert Tree.get(moved, dom(view, "c-col-2").id).parent_id == dom(view, "news-form").id

      assert Serializer.serialize(moved) =~
               ~s(<input type="hidden" name={g[:agree].name} value="false")

      assert Serializer.serialize(moved) =~ ~s(name={g[:agree].name} value="true")

      {:ok, undone} = EditorSession.undo(token(view))
      assert Serializer.serialize(undone.tree) == before
    end

    test "a form's last field moved away takes the empty form with it", %{conn: conn, site: site} do
      view = joining(conn, site)
      field_in(view, "news-email")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => dom(view, "contact-form").id})

      assert flashes(view) =~ "Moved it to the Contact form. The empty form was removed."
      assert dom(view, "news-form") == nil
    end

    test "a selected form offers Move its fields into, as one step", %{conn: conn, site: site} do
      view = joining(conn, site)
      field_in(view, "contact-form")

      assert has_element?(
               view,
               ~s(#pb-form-merge option[value="#{dom(view, "news-form").id}"]),
               "News"
             )

      refute has_element?(
               view,
               ~s(#pb-form-merge option[value="#{dom(view, "contact-form").id}"])
             )

      view
      |> element("#pb-form-merge-form")
      |> render_change(%{"form" => dom(view, "news-form").id})

      assert flashes(view) =~ "Moved its fields to the News form. The empty form was removed."

      specs =
        view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() |> PageForms.declared()

      assert [%{as: "news", fields: fields}] = specs
      assert Enum.map(fields, & &1.key) == [:email, :name, :agree]
    end

    test "Layers and the crumb bar call a form by its people name", %{conn: conn, site: site} do
      view = joining(conn, site)

      assert has_element?(view, "#pb-layer-form-#{dom(view, "contact-form").id}", "Contact")
      assert has_element?(view, "#pb-layer-form-#{dom(view, "news-form").id}", "News")
      refute has_element?(view, "#pb-layer-form-#{dom(view, "raw-form").id}")

      render_click(view, "select", %{"id" => dom(view, "name-box").id})
      assert has_element?(view, ~s([data-role="pb-crumbs"] button), "Contact")
    end
  end

  # The Inspector's Form panel, on the two deep forms: Phoenix's `<.form>` and Chelekom's Form
  # Wrapper wired as a page form, each field and Send button in a column of a grid in a card.
  describe "the Form panel" do
    defp nodes_in(view, form_id, pick),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> then(fn tree ->
          tree |> Tree.descendant_ids(form_id) |> Enum.map(&Tree.get(tree, &1))
        end)
        |> Enum.filter(pick)

    defp buttons_in(view, form_id), do: nodes_in(view, form_id, &(&1.tag == "button"))

    defp html_of(view), do: view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()

    test "How it works: as they type takes out the Send button and keeps phx-submit; Send puts it back",
         %{conn: conn, site: site} do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_setting")
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for {dom_id, seed} <- [{"contact-form", "contact"}, {"news-form", "news"}] do
        form = with_dom_id(view, dom_id)
        before = html_of(view)
        inspecting(view, form)

        assert has_element?(
                 view,
                 ~s(#pb-section-form ~ div #pb-form-how #pb-rule-how-send[aria-pressed="true"])
               )

        view |> element("#pb-rule-how-typing") |> render_click()

        typed = node_again(view, form.id)
        assert PageForms.as_typed?(typed)
        assert Node.attr_text(typed, "phx-submit") == Node.attr_text(form, "phx-submit")
        assert buttons_in(view, form.id) == []
        assert has_element?(view, ~s(#pb-form-how #pb-rule-how-typing[aria-pressed="true"]))
        assert has_element?(view, "#pb-form-how", "in a form with a single box it still sends")
        refute has_element?(view, "#pb-form-how", "Enter sends nothing")
        assert_receive {FormCreatedProbe, %{setting: :how, value: :typing, seed: ^seed}}

        view |> element("#pb-rule-how-send") |> render_click()

        [send] = buttons_in(view, form.id)
        refute view |> node_again(form.id) |> PageForms.as_typed?()
        assert editor(view).selection == form.id
        assert has_element?(view, ~s(#pb-form-how #pb-rule-how-send[aria-pressed="true"]))
        assert send.parent_id == form.id
        assert Node.attr_text(send, "phx-disable-with") == "Sending…"
        assert_receive {FormCreatedProbe, %{setting: :how, value: :send, seed: ^seed}}

        undo!(view)
        assert view |> node_again(form.id) |> PageForms.as_typed?()
        undo!(view)
        assert html_of(view) == before
      end
    end

    test "a form whose Send was deleted offers both fixes, and As they type clears the finding",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      form = with_dom_id(view, "news-form")
      [send] = buttons_in(view, form.id)

      render_click(view, "op", %{"kind" => "delete", "node_id" => send.id})
      open_audit(view)

      assert has_element?(view, "#pb-audit-fix-form-no-submit-#{form.id}", "Add a Send button")

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-submit-#{form.id}-typing",
               "Make it work as they type"
             )

      view |> element("#pb-audit-fix-form-no-submit-#{form.id}-typing") |> render_click()

      assert view |> node_again(form.id) |> PageForms.as_typed?()
      refute has_element?(view, "#pb-audit-fix-form-no-submit-#{form.id}")

      refute has_element?(
               view,
               "#pb-audit-fix-form-no-submit-#{with_dom_id(view, "contact-form").id}"
             )

      undo!(view)
      refute view |> node_again(form.id) |> PageForms.as_typed?()

      view |> element("#pb-audit-fix-form-no-submit-#{form.id}") |> render_click()
      assert [_send] = buttons_in(view, form.id)
    end

    test "a working kit form that cannot carry As they type is offered only the Send button",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper chelekom-simple-form)))

      template =
        ~s(<div id="root">) <>
          ~s(<.component component_name="chelekom-simple-form" site="localhost" :let={s} id="lead-form" as={:lead} for={assigns[:lead_form]} phx-change="lead-m4r2q-validate" phx-submit="lead-m4r2q-submit"><div class="card"><div class="grid"><div id="lead-col"><input name={s[:email].name} /></div></div></div></.component>) <>
          ~s(<.component component_name="chelekom-form-wrapper" site="localhost" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div id="news-col"><input name={w[:email].name} /></div></div></div></.component></div>)

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))
      lead = with_dom_id(view, "lead-form")
      news = with_dom_id(view, "news-form")
      open_audit(view)

      assert has_element?(view, "#pb-audit-fix-form-no-submit-#{lead.id}", "Add a Send button")
      refute has_element?(view, "#pb-audit-fix-form-no-submit-#{lead.id}-typing")
      assert has_element?(view, "#pb-audit-fix-form-no-submit-#{news.id}-typing")

      render_click(view, "audit_fix", %{
        "rule" => "form-no-submit",
        "id" => lead.id,
        "fix" => "typing"
      })

      refute view |> node_again(lead.id) |> PageForms.as_typed?()

      inspecting(view, lead)
      refute has_element?(view, "#pb-form-how")
      inspecting(view, news)
      assert has_element?(view, "#pb-form-how")
    end

    test "the Form name and Success message speak plainly", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      inspecting(view, with_dom_id(view, "news-form"))

      assert has_element?(view, "#pb-rule-control-seed", "What this form is called.")
      assert has_element?(view, ~s(#pb-rule-success[placeholder="Sent. Thank you."]))

      for id <- ~w(#pb-rule-control-seed #pb-rule-control-success #pb-form-how) do
        text = view |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
        refute text =~ ~r/params|assign|event|phx-/, id
      end
    end

    defp phoenix_open(view) do
      view |> element("#pb-section-form-phoenix") |> render_click()
    end

    test "Form · Phoenix starts folded, then shows the names read-only and each option the form forwards",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)

      assert has_element?(view, "#pb-form-phoenix")
      refute has_element?(view, "#pb-form-names")

      phoenix_open(view)

      assert has_element?(
               view,
               ~s(#pb-form-names [data-name="phx-submit"]),
               "contact-k7m2q-submit"
             )

      assert has_element?(view, ~s(#pb-form-names [data-name=":let"]), "f")
      refute has_element?(view, "#pb-form-names input")

      for key <- ~w(novalidate autocomplete auto_recover target) do
        assert has_element?(view, "#pb-form-phoenix #pb-rule-control-#{key}"), key
      end

      assert has_element?(view, ~s(#pb-form-files[data-on="false"]))
      assert has_element?(view, "#pb-form-address")

      view |> element("#pb-rule-autocomplete-off") |> render_click()
      assert Node.attr_text(node_again(view, contact.id), "autocomplete") == "off"

      inspecting(view, field_at(view, "contact-col"))
      assert has_element?(view, ~s(#pb-rule-field_autocomplete[placeholder="Default: off"]))
      inspecting(view, contact)

      view |> element("#pb-rule-autocomplete-on") |> render_click()
      assert Node.attr(node_again(view, contact.id), "autocomplete") == nil

      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      assert has_element?(view, "#pb-form-phoenix #pb-rule-control-auto_recover")

      for key <- ~w(novalidate autocomplete target) do
        refute has_element?(view, "#pb-rule-control-#{key}"), key
      end

      refute has_element?(view, "#pb-form-address")
      refute has_element?(view, "#pb-form-files")

      view |> element("#pb-rule-auto_recover") |> render_click()
      assert Node.attr_text(node_again(view, news.id), "phx-auto-recover") == "ignore"
      view |> element("#pb-rule-auto_recover") |> render_click()
      assert Node.attr(node_again(view, news.id), "phx-auto-recover") == nil
    end

    test "a file field put in a form turns on Can send files, in the same step, wherever it comes from",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      news = with_dom_id(view, "news-form")
      before = html_of(view)

      render_click(view, "drop", %{
        "template" => ~s(<input type="file" name="cv" />),
        "parent_id" => with_dom_id(view, "contact-col").id,
        "index" => "0"
      })

      assert Node.attr(node_again(view, contact.id), "multipart") == {:expr, "true"}

      inspecting(view, contact)
      phoenix_open(view)

      assert has_element?(
               view,
               ~s(#pb-form-files[data-on="true"]),
               "On, because a file field is inside this form."
             )

      undo!(view)
      assert html_of(view) == before

      render_click(view, "drop", %{
        "template" => ~s(<input type="file" name="cv" />),
        "parent_id" => with_dom_id(view, "news-col").id,
        "index" => "0"
      })

      assert Node.attr(node_again(view, news.id), "multipart") == nil

      file =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "type") == "file"))

      inspecting(view, file)

      view |> element("#pb-field-form-form") |> render_change(%{"form" => contact.id})

      assert Node.attr(node_again(view, contact.id), "multipart") == {:expr, "true"}
    end

    test "a form that already held a file field says Off until an address turns it on",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      template =
        String.replace(
          @two_deep_forms,
          ~s(<div id="contact-col">),
          ~s(<div id="contact-col"><input type="file" name="cv" />)
        )

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)
      phoenix_open(view)

      assert has_element?(view, ~s(#pb-form-files[data-on="false"]), "Off.")

      view
      |> element("#pb-form-address-form")
      |> render_change(%{"value" => "https://jobs.example.com/apply"})

      assert Node.attr(node_again(view, contact.id), "multipart") == {:expr, "true"}
      assert has_element?(view, ~s(#pb-form-files[data-on="true"]))
    end

    test "Send to another address writes the four together, a rename carries them, and empty removes them",
         %{conn: conn, site: site} do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_setting")
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)
      phoenix_open(view)

      view |> element("#pb-rule-target-_blank") |> render_click()
      assert Node.attr_text(node_again(view, contact.id), "target") == "_blank"

      view
      |> element("#pb-form-address-form")
      |> render_change(%{"value" => "https://pay.example.com/checkout"})

      sent = node_again(view, contact.id)
      assert Node.attr(sent, "target") == nil
      refute has_element?(view, "#pb-form-phoenix #pb-rule-control-target")
      assert has_element?(view, "#pb-form-address", "opens in this same tab")
      assert PageForms.address(sent) == "https://pay.example.com/checkout"
      assert Node.attr_text(sent, "method") == "post"
      assert Node.attr(sent, "csrf_token") == {:expr, "false"}
      assert Node.attr(sent, "phx-trigger-action") == {:expr, "assigns[:contact_send]"}
      assert Node.attr_text(sent, "phx-submit") == "contact-k7m2q-submit"

      assert_receive {FormCreatedProbe,
                      %{
                        setting: :address,
                        value: "https://pay.example.com/checkout",
                        seed: "contact"
                      }}

      open_audit(view)
      refute has_element?(view, "#pb-audit-fix-form-no-destination-#{contact.id}")

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-destination-#{with_dom_id(view, "news-form").id}"
             )

      inspecting(view, contact)
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Payment"})

      renamed = node_again(view, contact.id)
      assert PageForms.param_name(renamed) == "payment"
      assert Node.attr(renamed, "phx-trigger-action") == {:expr, "assigns[:payment_send]"}
      assert PageForms.address(renamed) == "https://pay.example.com/checkout"

      view
      |> element("#pb-form-address-form")
      |> render_change(%{"value" => "http://pay.example.com"})

      assert flashes(view) =~ "starts with https://"
      assert PageForms.address(node_again(view, contact.id)) == "https://pay.example.com/checkout"

      view |> element("#pb-form-address-form") |> render_change(%{"value" => ""})
      cleared = node_again(view, contact.id)

      for name <- ~w(action method csrf_token phx-trigger-action) do
        assert Node.attr(cleared, name) == nil, name
      end

      assert Node.attr_text(cleared, "phx-submit") == "payment-k7m2q-submit"
    end

    test "Props and Advanced leave a working kit form's names to the Form panel", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      assert has_element?(view, "#pb-attr-#{news.id}-color")

      for name <- ~w(for as id) do
        refute has_element?(view, "#pb-attr-#{news.id}-#{name}"), name
      end

      for name <- ~w(phx-change phx-submit :let) do
        refute has_element?(view, ~s([id="pb-extra-row-#{name}"])), name
      end
    end

    test "on a layout, where there is no Form panel, Props and Advanced still show a form's names",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      layout =
        create_layout!(
          name: "shell",
          site_id: site.id,
          template:
            ~s(<div id="shell"><div class="card"><div class="grid"><div class="col">) <>
              ~s(<.component component_name="chelekom-form-wrapper" site="localhost" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div id="news-col"><input name={w[:email].name} /></div></div></div></.component>) <>
              ~s(</div></div></div>{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _settled = render_async(view)
      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      refute has_element?(view, "#pb-section-form")

      for name <- ~w(for as id) do
        assert has_element?(view, "#pb-attr-#{news.id}-#{name}"), name
      end

      for name <- ~w(phx-change phx-submit :let) do
        assert has_element?(view, ~s([id="pb-extra-row-#{name}"])), name
      end
    end

    defp field_at(view, col), do: node_again(view, hd(with_dom_id(view, col).children))

    defp selection(view), do: view |> editor() |> Map.fetch!(:selection)

    @plain_fields ~w(debounce throttle field_autocomplete placeholder readonly disabled autofocus)

    test "Field options deep in both forms: Check while typing, and Form settings leads to the form",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for {col, form_id} <- [{"contact-col", "contact-form"}, {"news-col", "news-form"}] do
        input = field_at(view, col)
        inspecting(view, input)

        assert has_element?(
                 view,
                 ~s(#pb-field-debounce button[aria-pressed="true"]),
                 "As they type"
               )

        view |> element("#pb-rule-debounce-blur") |> render_click()
        assert Node.attr_text(node_again(view, input.id), "phx-debounce") == "blur"

        view |> element("#pb-rule-form-debounce") |> render_change(%{"value" => "500"})
        assert Node.attr_text(node_again(view, input.id), "phx-debounce") == "500"
        assert has_element?(view, ~s(#pb-rule-debounce-number[value="500"]))

        view |> element("#pb-rule-readonly") |> render_click()
        assert Node.attr(node_again(view, input.id), "readonly") == :boolean

        view
        |> element("#pb-rule-form-placeholder")
        |> render_change(%{"value" => "you@example.com"})

        assert Node.attr_text(node_again(view, input.id), "placeholder") == "you@example.com"

        view |> element("#pb-rule-note ~ #pb-form-settings-link") |> render_click()

        assert selection(view) == with_dom_id(view, form_id).id
        assert has_element?(view, "#pb-form-how")
      end
    end

    test "the Send button deep in both forms: text while sending, and a type that stops it sending",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for form_id <- ~w(contact-form news-form) do
        form = with_dom_id(view, form_id)
        [send] = buttons_in(view, form.id)
        inspecting(view, send)

        assert has_element?(view, "#pb-send-disable-with #pb-rule-disable_with")
        refute has_element?(view, "#pb-send-disable-with #pb-rule-disable_with[placeholder]")
        assert has_element?(view, "#pb-send-disable-with", "Empty keeps its own words.")

        refute has_element?(view, "#pb-send-type-warning")

        view |> element("#pb-rule-form-disable_with") |> render_change(%{"value" => "Paying…"})
        assert Node.attr_text(node_again(view, send.id), "phx-disable-with") == "Paying…"

        view |> element("#pb-rule-button_type-button") |> render_click()

        assert Node.attr_text(node_again(view, send.id), "type") == "button"
        assert has_element?(view, "#pb-send-type-warning", "does not send the form")
        refute has_element?(view, "#pb-send-disable-with")

        view |> element("#pb-rule-button_type-submit") |> render_click()
        assert Node.attr_text(node_again(view, send.id), "type") == "submit"

        view |> element("#pb-form-settings-link") |> render_click()
        assert selection(view) == form.id
      end
    end

    test "a link and a helper button deep in both forms: no Send options for the link, a plain warning for the helper",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      extra =
        ~s(<.button id="back-link" navigate="/back">Back</.button><button type="button" phx-click="toggle">More</button>)

      template =
        @two_deep_forms
        |> String.replace(~s(<div id="contact-col">), ~s(<div id="contact-col">) <> extra)
        |> String.replace(
          ~s(<div id="news-col">),
          ~s(<div id="news-col">) <> String.replace(extra, "back-link", "news-back")
        )

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))

      for {form_id, link_id} <- [{"contact-form", "back-link"}, {"news-form", "news-back"}] do
        inspecting(view, with_dom_id(view, link_id))

        refute has_element?(view, "#pb-rule-control-button_type"), form_id
        refute has_element?(view, "#pb-send-type-warning"), form_id

        helper =
          view
          |> buttons_in(with_dom_id(view, form_id).id)
          |> Enum.find(&(Node.attr_text(&1, "type") == "button"))

        inspecting(view, helper)

        assert has_element?(view, "#pb-send-type-warning", "does not send the form"), form_id
        refute has_element?(view, "#pb-send-type-warning", "any more"), form_id
      end
    end

    test "a code author gets the three event bindings and the way to Code", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      input = field_at(view, "news-col")
      inspecting(view, input)

      for key <- ~w(on_focus on_blur on_keyup) do
        assert has_element?(view, "#pb-rule-control-#{key}"), key
      end

      assert has_element?(view, "#pb-field-code-link")

      view |> element("#pb-rule-form-on_blur") |> render_change(%{"value" => "email_left"})
      assert Node.attr_text(node_again(view, input.id), "phx-blur") == "email_left"
    end

    test "where this deployment takes no code, a field reads plain words and gets no code rows",
         %{
           conn: conn,
           site: site
         } do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)

      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      input = field_at(view, "contact-col")
      inspecting(view, input)

      for key <- @plain_fields do
        id = (key == "debounce" && "#pb-field-debounce") || "#pb-rule-control-#{key}"

        text =
          view
          |> element(id)
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.text()

        refute text =~ ~r/params|assign|event|handler|phx-/, key
      end

      for key <- ~w(on_focus on_blur on_keyup) do
        refute has_element?(view, "#pb-rule-control-#{key}"), key
      end

      refute has_element?(view, "#pb-field-code-link")

      render_click(view, "set_rule", %{
        "key" => "on_focus",
        "node_id" => input.id,
        "value" => "sneaky"
      })

      assert Node.attr(node_again(view, input.id), "phx-focus") == nil

      [send] = buttons_in(view, with_dom_id(view, "contact-form").id)
      inspecting(view, send)

      for id <- ~w(#pb-rule-control-button_type #pb-send-disable-with) do
        text = view |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
        refute text =~ ~r/params|assign|event|phx-/, id
      end
    end

    # A form that does not work yet, deep in a card on a page with a working one.
    @idle_forms ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div class="col"><input name={f[:email].name} /></div></div></div><button type="submit">Send</button></.form>) <>
                  ~s(<div class="card"><div class="grid"><div class="col">) <>
                  ~s(<.component component_name="chelekom-form-wrapper" site="localhost" id="idle-form" for={%{}}><div class="card"><div class="grid"><div id="idle-col"><input name="nick" /></div></div></div><button type="submit">Join</button></.component>) <>
                  ~s(<form id="raw-form" class="stack gap-2"><div class="card"><div class="grid"><div id="raw-col"><input name="q" /></div></div></div></form>) <>
                  ~s(<form id="post-form" action="https://search.example.com"><input name="q" /></form>) <>
                  ~s(<.form for={%{}} id="search-form" action="https://search.example.com" method="get"><div class="card"><div class="grid"><div id="search-col"><input name="q" /></div></div></div></.form>) <>
                  ~s(<.component component_name="chelekom-form-wrapper" site="localhost" id="away-form" for={%{}} action="https://away.example.com"><div class="card"><div class="grid"><div id="away-col"><input name="nick" /></div></div></div></.component>) <>
                  ~s(</div></div></div></div>)

    defp idle_page!(site) do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))
      create_page!(site_id: site.id, template: @idle_forms)
    end

    test "Make it a working form wires a kit form deep in a card, as one undo step", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      {:ok, view, _html} = open_builder(conn, idle_page!(site))
      before = html_of(view)
      idle = with_dom_id(view, "idle-form")
      inspecting(view, idle)

      assert has_element?(
               view,
               "#pb-form-idle",
               "This is a form, but it does not work yet. Fields in it are not checked or sent."
             )

      refute has_element?(view, "#pb-form-how")

      view |> element("#pb-form-wire") |> render_click()

      wired = node_again(view, idle.id)
      assert PageForms.form?(wired)
      assert PageForms.let_var(wired) == :f
      assert Node.attr_text(field_at(view, "idle-col"), "name") == "f[:nick].name"
      assert_receive {FormCreatedProbe, %{how: :wired, node_id: id}}
      assert id == idle.id
      refute has_element?(view, "#pb-form-idle")
      assert has_element?(view, "#pb-form-how")

      undo!(view)
      assert html_of(view) == before
    end

    test "a plain HTML form becomes a working form, keeping its look and fields; one that posts away stays",
         %{conn: conn, site: site} do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      {:ok, view, _html} = open_builder(conn, idle_page!(site))
      before = html_of(view)
      inspecting(view, with_dom_id(view, "raw-form"))

      view |> element("#pb-form-wire") |> render_click()

      [replaced] =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.filter(&(&1.tag == ".form" and Node.attr_text(&1, "class") == "stack gap-2"))

      assert PageForms.form?(replaced)
      assert with_dom_id(view, "raw-form").id == replaced.id
      assert PageForms.param_name(replaced) == "raw"
      assert Node.attr_text(field_at(view, "raw-col"), "name") == "f[:q].name"
      assert_receive {FormCreatedProbe, %{how: :wired, node_id: id}}
      assert id == replaced.id

      undo!(view)
      assert html_of(view) == before

      for id <- ~w(post-form search-form away-form) do
        form = with_dom_id(view, id)
        inspecting(view, form)
        assert has_element?(view, "#pb-form-idle"), id
        assert has_element?(view, "#pb-form-idle-why"), id
        assert has_element?(view, "#pb-form-idle-state", "to its own web address"), id
        refute has_element?(view, "#pb-form-idle", "does not work yet"), id
        refute has_element?(view, "#pb-form-wire"), id

        render_click(view, "wire_form", %{"node_id" => form.id})
        assert Node.attr(node_again(view, form.id), "phx-submit") == nil, id
        refute PageForms.form?(node_again(view, form.id)), id
      end
    end

    test "a plain HTML form made a working one keeps its own id, so what points at it still does",
         %{
           conn: conn,
           site: site
         } do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      template =
        String.replace(
          @idle_forms,
          ~s(<form id="post-form"),
          ~s(<a href="#signup">Sign up</a><form id="signup"><div class="card"><div class="grid"><div id="signup-col"><input name="email" /></div></div></div></form>) <>
            ~s(<form id="newsletter-signup-form"><div class="card"><div class="grid"><div id="letter-col"><input name="email" /></div></div></div></form><form id="post-form")
        )

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))

      for id <- ~w(signup newsletter-signup-form) do
        inspecting(view, with_dom_id(view, id))
        view |> element("#pb-form-wire") |> render_click()

        kept = with_dom_id(view, id)
        assert kept.tag == ".form", id
        assert PageForms.form?(kept), id
      end
    end

    test "a plain form the page's own code answers says so, and keeps the names its fields send",
         %{conn: conn, site: site} do
      handled =
        String.replace(
          @idle_forms,
          ~s(<form id="post-form"),
          ~s(<form id="lead-form" phx-submit="save"><div class="card"><div class="grid"><div id="lead-col"><input type="email" name="email" /></div></div></div><button type="submit">Go</button></form><form id="post-form")
        )

      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      page =
        create_page!(
          site_id: site.id,
          template: handled,
          events: [%{name: "save", code: "{:noreply, socket}"}]
        )

      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, with_dom_id(view, "lead-form"))

      assert has_element?(
               view,
               ~s(#pb-form-idle-state[data-handled="true"]),
               "Your own code handles this form"
             )

      refute has_element?(view, "#pb-form-idle", "does not work yet")

      view |> element("#pb-form-wire") |> render_click()

      assert Enum.any?(
               view |> editor() |> Map.fetch!(:tree) |> Tree.walk(),
               &(&1.tag == ".form" and PageForms.form?(&1) and
                   Node.attr_text(&1, "phx-submit") == "save")
             )

      assert Node.attr_text(field_at(view, "lead-col"), "name") == "email"

      inspecting(view, with_dom_id(view, "raw-form"))
      assert has_element?(view, ~s(#pb-form-idle-state[data-handled="false"]))
    end

    test "the canvas toolbar's Form reaches the form from anything deep inside it", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      for {col, form_id} <- [{"contact-col", "contact-form"}, {"news-col", "news-form"}] do
        form = with_dom_id(view, form_id)
        [send] = buttons_in(view, form.id)

        for inside <- [field_at(view, col), send, with_dom_id(view, col)] do
          render_click(canvas, "select", %{"id" => inside.id})
          assert has_element?(canvas, "#pb-toolbar-form"), form_id

          canvas |> element("#pb-toolbar-form") |> render_click()
          assert selection(view) == form.id
        end
      end

      render_click(canvas, "select", %{"id" => node_with_tag(view, "h1").id})
      refute has_element?(canvas, "#pb-toolbar-form")
    end

    test "a drop refused on a form is placed after it, and the toast calls it by its people name",
         %{
           conn: conn,
           site: site
         } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      render_click(canvas, "drop", %{
        "template" => Elements.get("el-form").template,
        "parent_id" => with_dom_id(view, "news-form").id,
        "index" => "0"
      })

      assert_push_event(canvas, "pb:drop-moved", %{message: message})
      assert message =~ "Placed after the News form instead."
      refute message =~ "chelekom"
    end
  end
end
