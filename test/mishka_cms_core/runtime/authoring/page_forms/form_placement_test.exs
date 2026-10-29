# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacementTest do
  @moduledoc """
  Dropping a field is the gesture that has to come out right, because the two ways it can go wrong
  are both invisible on the canvas: a field with no form around it renders perfectly and submits
  nothing, and a second field reusing the first one's key renders perfectly and overwrites it.

  Both are decided here, at the moment of the drop, so the tests read the markup that comes back out.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Elements
  alias MishkaCmsCore.Runtime.Authoring.Fields
  alias MishkaCmsCore.Runtime.Authoring.Op
  alias MishkaCmsCore.Runtime.Authoring.PageForms
  alias MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.Authoring.PageForms.Naming
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node
  alias MishkaCmsCore.Runtime.Authoring.Tree.Serializer
  alias MishkaCmsCore.Test.Factory

  @moduletag :unit

  # The real Chelekom rows a form page is built from, and a renamed pair only their markup marks as
  # forms.
  setup_all do
    rows =
      Factory.chelekom_rows(
        ~w(chelekom-card chelekom-text-field chelekom-form-wrapper chelekom-simple-form chelekom-button) ++
          ~w(chelekom-checkbox-field chelekom-radio-field chelekom-toggle-field chelekom-file-field)
      )

    {:ok, chelekom: rows ++ Factory.renamed_form_pair(rows)}
  end

  @kit %{
    name: "kit-text-field",
    attrs: [
      %{"name" => "bind", "type" => "struct", "struct_name" => "Phoenix.HTML.FormField"},
      %{"name" => "caption", "type" => "string"}
    ],
    slots: [],
    template: "",
    form: %{"role" => "field", "field" => "bind"}
  }

  @pair %{
    name: "kit-pair-field",
    attrs: [
      %{"name" => "input_name", "type" => "string"},
      %{"name" => "input_value", "type" => "string"},
      %{"name" => "caption", "type" => "string"}
    ],
    slots: [],
    template: ~s(<input name={@input_name} value={@input_value} />),
    form: %{
      "role" => "field",
      "name" => "input_name",
      "value" => "input_value",
      "label" => "caption"
    }
  }

  # A kit that declared EXACTLY what it was told to declare — the role and its binding — and named
  # neither of the two attributes it derives from the form field. There is nothing wrong with it, and
  # its own markup says which two they are.
  @declaring %{
    name: "kit-bind-field",
    attrs: [
      %{"name" => "bind", "type" => "struct", "struct_name" => "Phoenix.HTML.FormField"},
      %{"name" => "input_name", "type" => "string"},
      %{"name" => "input_value", "type" => "string"}
    ],
    slots: [],
    template: ~s(<input name={@input_name} value={@input_value} />),
    form: %{"role" => "field", "field" => "bind"}
  }

  # A PAGE, because the wrap is a page's. Only `LiveViewCompiler.build_page_forms/1` emits the
  # `__page_forms__/0` and the two handlers the wrapper names, so `wrap/3` asks the session which
  # section it is on — a fixture with no section is not a document any of this could run in.
  defp session(source, section \\ "page") do
    {:ok, tree} = Tree.parse(source)
    %{tree: tree, section: section, components: [@kit, @pair, @declaring]}
  end

  defp node_id(session, tag) do
    session.tree |> Tree.walk() |> Enum.find(&(&1.tag == tag)) |> Map.get(:id)
  end

  defp page do
    session(~s(<section id="band"><div id="hole"></div></section>))
  end

  defp page_with_form do
    session(
      ~s(<.form :let={g} id="q-form" as={:q} for={assigns[:q_form]}><input name={g[:email].name} /></.form>)
    )
  end

  # A FORM IS A PAGE'S. The wrapper names `assigns[:form_form]`, `form-<token>-validate` and `form-<token>-submit`,
  # and only `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` emits any of them — the layout,
  # error-page and component compilers emit none. Wrapping there handed the author markup bound to
  # an assign nothing supplies and events nothing handles, and announced it as help.
  describe "a section that compiles no form handlers" do
    for section <- ~w(layout error_page component) do
      test "leaves a bare field alone on a #{section}" do
        {template, wrapped?} =
          FormPlacement.wrap(
            ~s(<input name="email" />),
            session(~s(<section id="band"><div id="hole"></div></section>), unquote(section)),
            nil
          )

        refute wrapped?
        assert template == ~s(<input name="email" />)
      end
    end
  end

  describe "a field with no form around it" do
    test "is wrapped in one, and the wrapper carries all five derived names" do
      {template, wrapped?} = FormPlacement.wrap(~s(<input name="email" />), page(), nil)

      assert wrapped?
      assert [spec] = PageForms.declared(template)
      assert spec.as == "form"
      assert spec.assign == :form_form
      assert spec.id == "form"
      assert spec.change =~ ~r/^form-[a-z2-7]{5}-validate$/
      assert spec.submit =~ ~r/^form-[a-z2-7]{5}-submit$/

      assert MishkaCmsCore.Runtime.Authoring.PageForms.Naming.same_form?(
               spec.change,
               spec.submit
             )
    end

    test "is bound to the form it was just given" do
      {template, true} = FormPlacement.wrap(~s(<input name="email" />), page(), nil)

      assert template =~ ~s(:let={f})
      assert template =~ ~s(name={f[:email].name})
      assert template =~ ~s(value={f[:email].value})
      assert [%{fields: [%{key: :email}]}] = PageForms.declared(template)
    end

    test "takes the kit's own binding attribute when the kit declares one" do
      {template, true} =
        FormPlacement.wrap(
          ~s(<.component component_name="kit-text-field" site="Global" />),
          page(),
          nil
        )

      assert template =~ ~s(bind={f[:kit_text_field]})
      assert [%{fields: [%{key: :kit_text_field}]}] = PageForms.declared(template)
    end

    test "takes the name and value pair when the kit takes no form field struct" do
      {template, true} =
        FormPlacement.wrap(
          ~s(<.component component_name="kit-pair-field" site="Global" caption="Email" />),
          page(),
          nil
        )

      assert template =~ ~s(input_name={f[:email].name})
      assert template =~ ~s(input_value={f[:email].value})
    end

    # THE KEY IS MINED FROM THE KIT'S OWN ATTRIBUTES, not from Phoenix's spelling of them. Reading
    # the literal `name` and `label` meant a kit calling them `input_name` and `caption` contributed
    # nothing the author had typed, and the key fell through to the component's own name — a fallback
    # presented as a choice.
    test "reads the author's word out of the kit's own name attribute" do
      {template, true} =
        FormPlacement.wrap(
          ~s(<.component component_name="kit-pair-field" site="Global" input_name="Phone number" />),
          page(),
          nil
        )

      assert template =~ ~s(input_name={f[:phone_number].name})
      assert [%{fields: [%{key: :phone_number}]}] = PageForms.declared(template)
    end

    test "and out of the attribute the kit declares as its caption" do
      {template, true} =
        FormPlacement.wrap(
          ~s(<.component component_name="kit-pair-field" site="Global" caption="Postal code" />),
          page(),
          nil
        )

      assert template =~ ~s(input_name={f[:postal_code].name})
    end

    # A blank is not a word, whatever it is spelled — the palette seeds the card with one so it
    # renders standing alone.
    test "and falls back to the component's name when neither carries a word" do
      {template, true} =
        FormPlacement.wrap(
          ~s(<.component component_name="kit-pair-field" site="Global" input_name="" caption="  " />),
          page(),
          nil
        )

      assert template =~ ~s(input_name={f[:kit_pair_field].name})
    end

    # THE BLANKS THE CARD IS SEEDED WITH ARE THE WHOLE POINT of the drop list. A kit derives them
    # from the form field with `assign_new/3`, which fills only an ABSENT key — so `input_name=""`
    # left beside the binding WINS, the input renders `name=""` and submits nothing, while the page
    # validates a key no input carries. The old fallback dropped the literal `name` and `value`,
    # which this component does not have, and left both real blanks standing.
    test "supersedes the kit's own pair even when the kit declared only its binding" do
      {template, true} =
        FormPlacement.wrap(
          ~s(<.component component_name="kit-bind-field" site="Global" input_name="" input_value="" />),
          page(),
          nil
        )

      assert template =~ ~s(bind={f[:kit_bind_field]})
      refute template =~ ~s(input_name=)
      refute template =~ ~s(input_value=)
    end

    test "gets a seed no form on the page is already using" do
      {template, true} =
        FormPlacement.wrap(
          ~s(<input name="email" />),
          session(~s(<.form :let={f} as={:form} for={assigns[:form_form]}></.form>)),
          nil
        )

      assert [%{as: "form_2", assign: :form_2_form, id: "form_2"}] =
               PageForms.declared(template)
    end
  end

  describe "a field landing inside a form" do
    test "is bound to that form's own variable and left where it is" do
      session = page_with_form()

      {template, wrapped?} =
        FormPlacement.wrap(~s(<input name="phone" />), session, node_id(session, ".form"))

      refute wrapped?
      assert template =~ ~s(name={g[:phone].name})
      refute template =~ "<.form"
    end

    test "takes a key the form is not already using" do
      session = page_with_form()

      {template, false} =
        FormPlacement.wrap(~s(<input name="email" />), session, node_id(session, ".form"))

      assert template =~ ~s(name={g[:email_2].name})
    end

    test "is bound when the drop lands deeper than the form itself" do
      session =
        session(~s(<.form :let={g} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      {template, false} =
        FormPlacement.wrap(~s(<input name="phone" />), session, node_id(session, "div"))

      assert template =~ ~s(name={g[:phone].name})
    end

    test "is left alone when the form it lands in binds no variable" do
      session = session(~s(<.form as={:q} for={assigns[:q_form]}></.form>))
      target = node_id(session, ".form")

      assert FormPlacement.wrap(~s(<input name="phone" />), session, target) ==
               {~s(<input name="phone" />), false}
    end
  end

  # CARD > GRID > COLUMN, three levels under the form's edge, which is where a real page puts its
  # fields. A kit form here holds `for={%{}}` as the palette seeds it, so no page assign marks it: it
  # is found by what its markup does, and a kit form under another name counts.
  describe "a field landing in a card deep inside a form" do
    defp card(column, inner),
      do:
        ~s(<.component component_name="chelekom-card" site="Global" padding="large">) <>
          ~s(<div class="grid grid-cols-2 gap-4"><div id="#{column}" class="col-span-1">) <>
          inner <> "</div></div></.component>"

    defp kit_form(name, var, seed, inner),
      do:
        ~s(<.component component_name="#{name}" site="Global" #{let(var)}id="#{seed}-form" ) <>
          ~s(for={%{}}>) <> inner <> "</.component>"

    defp let(nil), do: ""
    defp let(var), do: ~s(:let={#{var}} )

    defp deep_session(source, chelekom) do
      {:ok, tree} = Tree.parse(source)
      %{tree: tree, section: "page", components: chelekom}
    end

    defp column(session, id),
      do:
        session.tree
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "id") == id))
        |> Map.get(:id)

    @text_field ~s(<.component component_name="chelekom-text-field" site="Global" label="Email" />)

    test "joins every kit form it lands in, whatever the form is called", %{chelekom: chelekom} do
      for name <- ~w(chelekom-form-wrapper chelekom-simple-form acme-wrapper acme-simple) do
        session =
          deep_session(kit_form(name, "w", "signup", card("col", "<p>Tell us</p>")), chelekom)

        {raw, wrapped?} =
          FormPlacement.wrap(~s(<input name="phone" />), session, column(session, "col"))

        {kit, kit_wrapped?} = FormPlacement.wrap(@text_field, session, column(session, "col"))

        refute wrapped? or kit_wrapped?,
               "#{name} is a form, so nothing is wrapped in a second one"

        assert raw =~ ~s(name={w[:phone].name}), name
        assert kit =~ ~s(field={w[:email]}), name
      end
    end

    test "is not wrapped in a second form inside a kit form that binds no variable yet", %{
      chelekom: chelekom
    } do
      for name <- ~w(chelekom-form-wrapper chelekom-simple-form acme-wrapper acme-simple) do
        session = deep_session(kit_form(name, nil, "signup", card("col", "")), chelekom)

        assert FormPlacement.wrap(~s(<input name="phone" />), session, column(session, "col")) ==
                 {~s(<input name="phone" />), false},
               name
      end
    end

    test "on a page with two forms, each field joins the form it lands in", %{chelekom: chelekom} do
      source =
        ~s(<div id="page">) <>
          ~s(<.form :let={g} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit">) <>
          card("contact-col", ~s(<input name={g[:email].name} /><input name={g[:name].name} />)) <>
          "</.form>" <>
          kit_form(
            "acme-simple",
            "w",
            "signup",
            card("signup-col", ~s(<input name={w[:email].name} />))
          ) <>
          "</div>"

      session = deep_session(source, chelekom)

      assert {contact, false} =
               FormPlacement.wrap(@text_field, session, column(session, "contact-col"))

      assert {signup, false} =
               FormPlacement.wrap(@text_field, session, column(session, "signup-col"))

      assert {named, false} =
               FormPlacement.wrap(
                 ~s(<input name="name" />),
                 session,
                 column(session, "signup-col")
               )

      assert contact =~ ~s(field={g[:email_2]})
      assert signup =~ ~s(field={w[:email_2]})

      assert named =~ ~s(name={w[:name].name}),
             "a key taken in the other form is free in this one"
    end
  end

  # THE CMS'S OWN FIELD IS NOT IN THE KIT CATALOG. `<.input>` is what every shipped Forms block and
  # every Forms element is built out of, and looking it up in the palette alone answered "not a
  # field" — so a drop never bound one and a paste never rebound one.
  describe "a CMS-local component" do
    test "is bound on the attribute its own declaration names" do
      session = page_with_form()

      {template, false} =
        FormPlacement.wrap(
          ~s(<.input type="text" label="Phone" />),
          session,
          node_id(session, ".form")
        )

      assert template =~ ~s(field={g[:phone]})
    end

    test "is wrapped in a form when it lands with none" do
      {template, true} = FormPlacement.wrap(~s(<.input type="text" label="Email" />), page(), nil)

      assert [%{as: "form", fields: [%{key: :email}]}] = PageForms.declared(template)
    end

    test "the form component itself is not a field, so it is left where it is" do
      source = Elements.get("el-form").template

      assert FormPlacement.wrap(source, page(), nil) == {source, false}
    end
  end

  # A TEMPLATE IS ONE FIELD, NOT ONE NODE. `el-checkbox`'s head is a `<label>` and
  # `el-radio-group`'s a `<fieldset>`; binding only the head left every control under it carrying its
  # literal name, so the browser posted `agree` at the event's top level and `PageForm.scoped/2`
  # never saw it.
  describe "a group of controls under one name" do
    test "binds every control in a checkbox, and keeps the values that tell them apart" do
      session = page_with_form()

      {template, false} =
        FormPlacement.wrap(
          Elements.get("el-checkbox").template,
          session,
          node_id(session, ".form")
        )

      assert template =~ ~s(<input type="hidden" name={g[:agree].name} value="false")
      assert template =~ ~s(<input type="checkbox" name={g[:agree].name} value="true")
      refute template =~ ~s(name="agree")
    end

    test "binds every option in a radio group under one key" do
      session = page_with_form()

      {template, false} =
        FormPlacement.wrap(
          Elements.get("el-radio-group").template,
          session,
          node_id(session, ".form")
        )

      assert template =~ ~s(name={g[:choice].name} value="one")
      assert template =~ ~s(name={g[:choice].name} value="two")
      refute template =~ ~s(name="choice")
    end

    test "wraps the whole group in one form when it lands with none" do
      {template, true} = FormPlacement.wrap(Elements.get("el-checkbox").template, page(), nil)

      assert [%{as: "form", fields: [%{key: :agree, type: :boolean}]}] =
               PageForms.declared(template)

      assert template =~ ~s(<.form :let={f})
      assert template =~ ~s(<label)
      assert template =~ ~s(value="false")
    end

    test "controls answering to different names are several fields, so none is chosen" do
      source = ~s(<div><input name="first" /><input name="second" /></div>)
      session = page_with_form()

      assert FormPlacement.wrap(source, session, node_id(session, ".form")) == {source, false}
    end
  end

  describe "what is left exactly as it arrived" do
    test "anything that is not a field" do
      assert FormPlacement.wrap(~s(<div class="x">hello</div>), page(), nil) ==
               {~s(<div class="x">hello</div>), false}
    end

    test "a button, which submits rather than carries a value" do
      source = ~s(<input type="submit" name="go" />)

      assert FormPlacement.wrap(source, page(), nil) == {source, false}
    end

    test "a button whose type is written in capitals or as a literal expression" do
      session = page_with_form()

      for source <- [
            ~s(<input type="Submit" value="Send" />),
            ~s(<input type={"submit"} value="Send" />)
          ] do
        assert FormPlacement.bind(source, session, node_id(session, ".form")) == source, source
        assert FormPlacement.wrap(source, page(), nil) == {source, false}, source
      end
    end

    test "a field that already binds a key" do
      session = page_with_form()
      source = ~s(<input name={g[:phone].name} value={g[:phone].value} />)

      assert FormPlacement.wrap(source, session, node_id(session, ".form")) == {source, false}
    end

    test "a block that brings its own form" do
      source =
        ~s(<section><.form :let={f} as={:x} for={assigns[:x_form]}><input name="e" /></.form></section>)

      assert FormPlacement.wrap(source, page(), nil) == {source, false}
    end

    test "markup that cannot be parsed" do
      assert FormPlacement.wrap(~s(<input name="a), page(), nil) == {~s(<input name="a), false}
    end
  end

  describe "told(:started)" do
    test "says a new form with a Send button was started, and where to choose another" do
      assert FormPlacement.told(:started) =~ "Started a new form with a Send button."
      assert FormPlacement.told(:started) =~ "under In form in the Inspector"
      assert String.ends_with?(FormPlacement.told(:started), ".")
    end
  end

  describe "send_button/0" do
    test "is Elements' styled Submit, the same one the Form element carries" do
      assert FormPlacement.send_button() == Elements.get("el-submit").template
      assert Elements.get("el-form").template =~ FormPlacement.send_button()

      tree = Tree.parse!(FormPlacement.send_button())
      [button] = Enum.map(tree.roots, &Tree.get(tree, &1))

      assert button.tag == "button"
      assert Node.attr_text(button, "type") == "submit"
    end
  end

  # TWO FORMS ON ONE PAGE, fields three levels down (card > grid > column). The core form's Send sits
  # in the card's footer; the Chelekom wrapper's Send sits in its own `<:actions>` slot.
  @core_deep ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit">) <>
               ~s(<.component component_name="chelekom-card" site="Global" id="c-card"><div id="c-grid" class="grid grid-cols-2">) <>
               ~s(<div id="c-col-1"><input type="text" name={f[:name].name} value={f[:name].value} /></div>) <>
               ~s(<div id="c-col-2"><input type="email" name={f[:email].name} value={f[:email].value} /></div>) <>
               ~s(</div><footer id="c-foot" class="flex"><p>We reply within a day.</p><button type="submit">Send</button></footer></.component></.form>)

  @kit_deep ~s(<.component component_name="chelekom-form-wrapper" site="Global" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">) <>
              ~s(<.component component_name="chelekom-card" site="Global" id="n-card"><div id="n-grid" class="grid">) <>
              ~s(<div id="n-col"><input type="email" name={w[:email].name} value={w[:email].value} /></div>) <>
              ~s(</div></.component><:actions><.component component_name="chelekom-button" site="Global" type="submit">Join</.component></:actions></.component>)

  @two_forms ~s(<div id="page">#{@core_deep}#{@kit_deep}<section id="band"><div id="loose"></div></section></div>)

  defp two_forms(chelekom, section \\ "page") do
    {:ok, tree} = Tree.parse(@two_forms)
    %{tree: tree, section: section, components: chelekom}
  end

  defp with_id(session, id),
    do: session.tree |> Tree.walk() |> Enum.find(&(Node.attr_text(&1, "id") == id))

  defp at(session, id), do: Tree.index_of(session.tree, with_id(session, id).id)

  # The ops a caller would send down the funnel, applied the way the funnel applies them.
  defp run(session, ops) do
    tree =
      Enum.reduce(ops, session.tree, fn params, tree ->
        {:ok, op} = Op.build(params)

        case Op.apply_to(op, tree) do
          {:ok, tree} -> tree
          {:ok, tree, _focus} -> tree
        end
      end)

    %{session | tree: tree}
  end

  defp html(session), do: Serializer.serialize(session.tree)

  defp classes(node), do: node |> Tree.classes() |> MapSet.new()

  defp specs(session), do: session |> html() |> PageForms.declared() |> Map.new(&{&1.as, &1})

  defp keys(spec), do: Enum.map(spec.fields, & &1.key)

  describe "place/3, a field on a page with two forms" do
    test "aimed between two fields deep in a card keeps its spot and joins that form", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      params = %{"parent_id" => with_id(session, "c-grid").id, "index" => 1}

      assert {template, ^params, {:joined, "Contact"}} =
               FormPlacement.place(~s(<input name="phone" />), session, params)

      assert template =~ ~s(name={f[:phone].name})
    end

    test "dropped on the form's own bottom edge joins it before a Send in the card footer", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      form = with_id(session, "contact-form")

      {template, spot, outcome} =
        FormPlacement.place(~s(<input name="phone" />), session, %{
          "parent_id" => form.parent_id,
          "index" => at(session, "contact-form") + 1,
          "anchor_id" => form.id,
          "anchor_before" => false
        })

      assert outcome == {:joined, "Contact"}
      assert spot["parent_id"] == with_id(session, "c-foot").id
      assert spot["index"] == 1
      assert template =~ ~s(name={f[:phone].name})
    end

    test "dropped on the form's own top edge joins it at the top", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      form = with_id(session, "contact-form")

      {_template, spot, {:joined, "Contact"}} =
        FormPlacement.place(~s(<input name="phone" />), session, %{
          "parent_id" => form.parent_id,
          "index" => at(session, "contact-form"),
          "anchor_id" => form.id,
          "anchor_before" => true
        })

      assert spot == %{
               "parent_id" => form.id,
               "index" => 0,
               "anchor_id" => form.id,
               "anchor_before" => true
             }
    end

    test "a spot past the Send button lands in front of it", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      footer = with_id(session, "c-foot").id

      for params <- [
            %{"parent_id" => footer, "index" => 2},
            %{"parent_id" => with_id(session, "contact-form").id, "index" => "9999"}
          ] do
        {_template, spot, {:joined, "Contact"}} =
          FormPlacement.place(~s(<input name="phone" />), session, params)

        assert {spot["parent_id"], spot["index"]} == {footer, 1}, inspect(params)
      end
    end

    test "dropped into a Chelekom wrapper's content joins it on the wrapper's variable", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      params = %{"parent_id" => with_id(session, "n-col").id, "index" => 1}

      assert {template, ^params, {:joined, "News"}} =
               FormPlacement.place(~s(<input name="phone" />), session, params)

      assert template =~ ~s(name={w[:phone].name})
    end

    test "the end of a Chelekom wrapper is after its content, whatever its slot's place", %{
      chelekom: chelekom
    } do
      first_actions =
        String.replace(
          @two_forms,
          ~s(</div></.component><:actions><.component component_name="chelekom-button" site="Global" type="submit">Join</.component></:actions></.component>),
          ~s(</div></.component></.component>)
        )
        |> String.replace(
          ~s(phx-submit="news-p3xa6-submit">),
          ~s(phx-submit="news-p3xa6-submit"><:actions><.component component_name="chelekom-button" site="Global" type="submit">Join</.component></:actions>)
        )

      for source <- [@two_forms, first_actions] do
        {:ok, tree} = Tree.parse(source)
        session = %{tree: tree, section: "page", components: chelekom}
        wrapper = with_id(session, "news-form")
        card = with_id(session, "n-card")

        assert FormPlacement.landing(tree, wrapper, chelekom) ==
                 {wrapper.id, Tree.index_of(tree, card.id) + 1}

        # Its content comes before its actions however the children are ordered: a spot in the
        # content is kept, one inside the actions moves out of them.
        between = %{"parent_id" => with_id(session, "n-col").id, "index" => 0}

        assert {_bound, ^between, {:joined, "News"}} =
                 FormPlacement.place(~s(<input name="phone" />), session, between)

        send = Enum.find(Tree.walk(tree), &(Node.component_name(&1) == "chelekom-button"))

        {_template, moved, {:joined, "News"}} =
          FormPlacement.place(~s(<input name="phone" />), session, %{
            "parent_id" => send.parent_id,
            "index" => 1
          })

        assert {moved["parent_id"], moved["index"]} ==
                 {wrapper.id, Tree.index_of(tree, card.id) + 1}
      end
    end

    test "each drop joins the form it lands in, with a key free in that form", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      for {col, var, name} <- [{"c-col-2", "f", "Contact"}, {"n-col", "w", "News"}] do
        {template, _spot, {:joined, ^name}} =
          FormPlacement.place(~s(<input type="email" name="email" />), session, %{
            "parent_id" => with_id(session, col).id,
            "index" => 1
          })

        assert template =~ ~s(name={#{var}[:email_2].name}), col
      end
    end

    test "anywhere else it starts a new form that comes with the styled Send", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      {template, _spot, :started} =
        FormPlacement.place(~s(<input name="phone" />), session, %{
          "parent_id" => with_id(session, "loose").id,
          "index" => 0
        })

      assert [%{as: "form", fields: [%{key: :phone}]}] = PageForms.declared(template)

      tree = Tree.parse!(template)
      [form] = Enum.map(tree.roots, &Tree.get(tree, &1))
      assert Node.attr_text(form, "class") == "space-y-4"
      assert [styled] = Enum.filter(Tree.walk(tree), &(&1.tag == "button"))

      assert classes(styled) ==
               classes(Tree.parse!(FormPlacement.send_button()) |> Tree.walk() |> hd())
    end

    test "a template that is not a field is left as it came", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      params = %{"parent_id" => with_id(session, "c-col-1").id, "index" => 0}

      assert FormPlacement.place("<p>Hello</p>", session, params) ==
               {"<p>Hello</p>", params, :none}
    end

    test "on a layout a field is only bound to a form the author wrote", %{chelekom: chelekom} do
      session = two_forms(chelekom, "layout")
      loose = %{"parent_id" => with_id(session, "loose").id, "index" => 0}
      inside = %{"parent_id" => with_id(session, "c-col-1").id, "index" => 0}

      assert FormPlacement.place(~s(<input name="phone" />), session, loose) ==
               {~s(<input name="phone" />), loose, :none}

      {bound, ^inside, :none} = FormPlacement.place(~s(<input name="phone" />), session, inside)
      assert bound =~ ~s(name={f[:phone].name})
    end
  end

  describe "place/3, a kit form that lends its form to its content" do
    @wrapper_card ~s(<.component component_name="chelekom-form-wrapper" site="Global" id="form-contact-us" for={%{}}>) <>
                    ~s(<.component component_name="chelekom-card" site="Global"><div class="grid"><div>) <>
                    ~s(<.component component_name="chelekom-text-field" site="Global" id="contact-full-name" name="full_name" value="" label="Full name" />) <>
                    ~s(</div><div><input type="email" name="email" /></div></div></.component>) <>
                    ~s(<:actions><.component component_name="chelekom-button" site="Global" type="submit">Send</.component></:actions></.component>)

    test "arrives wired on a Page, its sample fields bound, whatever the kit calls it", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      params = %{"parent_id" => with_id(session, "loose").id, "index" => 0}

      for name <- ~w(chelekom-form-wrapper chelekom-simple-form acme-wrapper acme-simple) do
        source = String.replace(@wrapper_card, "chelekom-form-wrapper", name, global: false)

        {template, ^params, :wired} = FormPlacement.place(source, session, params)

        assert [spec] = PageForms.declared(template), name
        assert spec.as == "form"
        assert spec.submit =~ ~r/^form-[a-z2-7]{5}-submit$/
        assert Enum.map(spec.fields, & &1.key) == [:full_name, :email], name
        assert template =~ ~s(:let={f})
        assert template =~ ~s(field={f[:full_name]})
        assert template =~ ~s(name={f[:email].name})
        refute template =~ ~s(name="full_name")
      end
    end

    test "one that names its own phx-submit arrives as it came, deep in a two-form page", %{
      chelekom: chelekom
    } do
      {:ok, tree} =
        @two_forms
        |> String.replace(
          ~s(<div id="loose"></div>),
          ~s(<div class="card"><div class="grid"><div id="deep-col"></div></div></div>)
        )
        |> Tree.parse()

      session = %{tree: tree, section: "page", components: chelekom}
      params = %{"parent_id" => with_id(session, "deep-col").id, "index" => 0}

      for extra <- [
            ~s(for={%{}} phx-submit="save_lead"),
            ~s(for={%{}} :let={f} as={:signup} phx-submit="subscribe")
          ] do
        source = String.replace(@wrapper_card, ~s(for={%{}}), extra)

        assert FormPlacement.place(source, session, params) == {source, params, :none}
      end
    end

    test "one that posts to its own address arrives as it came", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      params = %{"parent_id" => with_id(session, "loose").id, "index" => 0}

      source =
        String.replace(
          @wrapper_card,
          ~s(for={%{}}),
          ~s(for={%{}} action="https://away.example.com")
        )

      assert FormPlacement.place(source, session, params) == {source, params, :none}
    end

    test "is left unwired on a layout, a component or an error page", %{chelekom: chelekom} do
      for section <- ~w(layout component error_page) do
        session = two_forms(chelekom, section)
        params = %{"parent_id" => with_id(session, "loose").id, "index" => 0}

        assert FormPlacement.place(@wrapper_card, session, params) ==
                 {@wrapper_card, params, :none}
      end
    end
  end

  describe "wiring/4" do
    defp idle(source) do
      tree = Tree.parse!(source)
      {tree, tree |> Tree.walk() |> hd()}
    end

    test "writes :let, the five names and a binding for every field inside", %{chelekom: chelekom} do
      {tree, node} = idle(@wrapper_card)

      assert {:ok, ops} = FormPlacement.wiring(tree, node, chelekom)
      names = for %{kind: :set_attr, node_id: id, name: name} <- ops, id == node.id, do: name

      assert names == ~w(:let id as for phx-change phx-submit)
      assert Enum.any?(ops, &(&1[:value] == "f[:full_name]"))
    end

    test "seeds from the as the author already set", %{chelekom: chelekom} do
      {tree, node} =
        idle(String.replace(@wrapper_card, ~s(for={%{}}), ~s(for={%{}} as={:signup})))

      {:ok, ops} = FormPlacement.wiring(tree, node, chelekom)

      assert Enum.find(ops, &(&1[:name] == "as")).value == ":signup"
      assert Enum.find(ops, &(&1[:name] == "phx-submit")).value =~ ~r/^signup-[a-z2-7]{5}-submit$/
    end

    test "keeps a developer's own phx-submit that the page's code answers", %{chelekom: chelekom} do
      {tree, node} =
        idle(String.replace(@wrapper_card, ~s(for={%{}}), ~s(for={%{}} phx-submit="save_lead")))

      {:ok, ops} = FormPlacement.wiring(tree, node, chelekom, events: [%{name: "save_lead"}])
      names = for %{node_id: id, name: name} <- ops, id == node.id, do: name

      assert names == ~w(:let as for)
      assert Enum.all?(ops, &(&1.node_id == node.id))

      {:ok, unanswered} = FormPlacement.wiring(tree, node, chelekom, events: [])
      assert "phx-submit" in Enum.map(unanswered, & &1[:name])
    end

    test "a plain form the page's code answers keeps its field names when it is replaced", %{
      chelekom: chelekom
    } do
      raw =
        ~s(<div class="card"><div class="grid"><div id="raw-col">) <>
          ~s(<form id="lead-form" phx-submit="save"><div class="card"><div class="grid"><div id="lead-col">) <>
          ~s(<input type="email" name="email" /></div></div></div></form></div></div></div>)

      {:ok, tree} = @two_forms |> String.replace(~s(<div id="loose"></div>), raw) |> Tree.parse()
      session = %{tree: tree, section: "page", components: chelekom}
      form = with_id(session, "lead-form")

      {:ok, [%{kind: :delete}, %{kind: :insert, template: kept}]} =
        FormPlacement.replace_ops(session, form.id, events: [%{name: "save"}])

      assert kept =~ ~s(phx-submit="save")
      assert kept =~ ~s(:let={f})
      assert kept =~ ~s(name="email")
      refute kept =~ "f[:email]"

      {:ok, [%{kind: :delete}, %{kind: :insert, template: bound}]} =
        FormPlacement.replace_ops(session, form.id, events: [])

      assert bound =~ ~s(name={f[:email].name})
      refute bound =~ ~s(name="email")
    end

    test "a plain form keeps its own id when it is replaced, and one with none gets its name's",
         %{
           chelekom: chelekom
         } do
      raw = fn attrs ->
        ~s(<div class="card"><div class="grid"><div class="col">) <>
          ~s(<form#{attrs}><div class="card"><div class="grid"><div class="col">) <>
          ~s(<input name="q" /></div></div></div></form></div></div></div>)
      end

      for {attrs, id} <- [
            {~s( id="signup"), "signup"},
            {~s( id="newsletter-signup-form"), "newsletter-signup-form"},
            {~s( id="contact"), "contact"},
            {"", "form"}
          ] do
        {:ok, tree} =
          @two_forms |> String.replace(~s(<div id="loose"></div>), raw.(attrs)) |> Tree.parse()

        session = %{tree: tree, section: "page", components: chelekom}
        form = session.tree |> Tree.walk() |> Enum.find(&(&1.tag == "form"))

        {:ok, ops} = FormPlacement.replace_ops(session, form.id)
        replaced = run(session, ops)

        assert [working] =
                 replaced.tree |> Tree.walk() |> Enum.filter(&(Node.attr_text(&1, "id") == id)),
               attrs

        assert working.tag == ".form"
        assert PageForms.form?(working)
      end
    end

    test "refuses a core form or a kit form that posts to its own address, deep fields and all",
         %{
           chelekom: chelekom
         } do
      inner =
        ~s(<div class="card"><div class="grid"><div class="col"><input name="q" /></div></div></div>)

      for source <- [
            ~s(<.form for={%{}} action="https://search.example.com" method="get">#{inner}</.form>),
            String.replace(
              @wrapper_card,
              ~s(for={%{}}),
              ~s(for={%{}} action="https://away.example.com")
            )
          ] do
        {tree, node} = idle(source)

        assert {:error, "It sends to its own web address, so it stays as it is."} =
                 FormPlacement.wiring(tree, node, chelekom)

        refute FormPlacement.wirable?(node, chelekom)
      end

      {tree, lending} = idle(@wrapper_card)
      assert FormPlacement.wirable?(lending, chelekom)
      assert {:ok, _ops} = FormPlacement.wiring(tree, lending, chelekom)
    end

    test "refuses a raw form and a form that already works", %{chelekom: chelekom} do
      {tree, raw} = idle(~s(<form><input name="q" /></form>))
      {working_tree, working} = idle(~s(<.form :let={f} as={:q} for={assigns[:q_form]}></.form>))

      assert {:error, "Replace it with Form from Blocks › Forms."} =
               FormPlacement.wiring(tree, raw, chelekom)

      assert {:error, "It is already a working form."} =
               FormPlacement.wiring(working_tree, working, chelekom)
    end
  end

  describe "how_ops/3, how a working form sends" do
    defp sends(session, form) do
      nodes =
        session.tree |> Tree.descendant_ids(form.id) |> Enum.map(&Tree.get(session.tree, &1))

      roles = Fields.roles(nodes, session.components)
      rules = Fields.submit_rules(roles, session.components)

      Enum.filter(nodes, &Fields.submit_node?(&1, roles, rules))
    end

    test "as they type takes out each deep form's Send, records it and keeps phx-submit", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      for {id, other} <- [{"contact-form", "news-form"}, {"news-form", "contact-form"}] do
        form = with_id(session, id)

        assert {:ok, ops, "It now works as they type, with no Send button."} =
                 FormPlacement.how_ops(session, form.id, :typing)

        typed = run(session, ops)
        kept = Tree.get(typed.tree, form.id)

        assert PageForms.as_typed?(kept), id
        assert Node.attr_text(kept, "phx-submit") == Node.attr_text(form, "phx-submit")
        assert sends(typed, kept) == [], id
        assert [_send] = sends(typed, with_id(typed, other))
        assert Map.keys(specs(typed)) == ~w(contact news)
      end
    end

    test "when they press Send puts the styled Send at the end of the content, not in a slot", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      for {id, after_send} <- [{"contact-form", []}, {"news-form", [:slot]}] do
        form = with_id(session, id)
        {:ok, ops, _told} = FormPlacement.how_ops(session, form.id, :typing)
        typed = run(session, ops)

        assert {:ok, ops, "It now sends when they press Send."} =
                 FormPlacement.how_ops(typed, form.id, :send)

        sent = run(typed, ops)
        back = Tree.get(sent.tree, form.id)
        [send] = sends(sent, back)

        refute PageForms.as_typed?(back)
        assert send.parent_id == form.id
        assert Node.attr_text(send, "phx-disable-with") == "Sending…"
        assert Node.attr_text(send, "class") =~ "bg-slate-900"

        assert back.children
               |> Enum.drop_while(&(&1 != send.id))
               |> tl()
               |> Enum.map(&Tree.get(sent.tree, &1).kind) == after_send
      end
    end

    test "a form that already has its Send is only told so, and an idle one is refused", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      form = with_id(session, "contact-form")

      assert {:ok, [%{kind: :delete_attr}], _told} =
               FormPlacement.how_ops(session, form.id, :send)

      {tree, idle} = idle(@wrapper_card)

      assert {:error, "This form does not work yet."} =
               FormPlacement.how_ops(%{session | tree: tree}, idle.id, :typing)

      assert {:error, "That form is no longer on the page."} =
               FormPlacement.how_ops(session, "gone", :typing)
    end
  end

  describe "a field the editor binds checks what is typed after 300 ms" do
    test "a joined field, a wrapped one and a wired kit form's fields, deep in cards", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      {joined, _params, {:joined, "Contact"}} =
        FormPlacement.place(
          ~s(<input type="text" name="phone" />),
          session,
          %{"parent_id" => with_id(session, "c-col-1").id, "index" => 1}
        )

      {started, _params, :started} =
        FormPlacement.place(
          ~s(<.component component_name="chelekom-text-field" site="Global" label="Nick" />),
          session,
          %{"parent_id" => with_id(session, "loose").id, "index" => 0}
        )

      {wired, _params, :wired} =
        FormPlacement.place(@wrapper_card, session, %{
          "parent_id" => with_id(session, "loose").id,
          "index" => 0
        })

      assert joined =~ ~s(phx-debounce="300")
      assert started =~ ~s(phx-debounce="300")
      assert length(Regex.scan(~r/phx-debounce="300"/, wired)) == 2
    end

    test "a box, a hidden value and a field that names its own timing are left as they are", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      spot = %{"parent_id" => with_id(session, "c-col-1").id, "index" => 1}

      for field <- [
            ~s(<input type="checkbox" name="agree" />),
            ~s(<input type="hidden" name="source" value="ad" />),
            ~s(<input type="file" name="cv" />)
          ] do
        {template, _params, _outcome} = FormPlacement.place(field, session, spot)
        refute template =~ "phx-debounce", field
      end

      for col <- ~w(c-col-1 n-col),
          field <- [
            ~s(<.component component_name="chelekom-checkbox-field" site="Global" label="Agree" />),
            ~s(<.component component_name="chelekom-radio-field" site="Global" label="Yes" />),
            ~s(<.component component_name="chelekom-toggle-field" site="Global" label="News" />),
            ~s(<.component component_name="chelekom-file-field" site="Global" label="CV" />),
            ~s(<.input type="checkbox" name="agree" label="Agree" />),
            ~s(<.input type="hidden" name="source" />)
          ] do
        {template, _params, {:joined, _name}} =
          FormPlacement.place(field, session, %{
            "parent_id" => with_id(session, col).id,
            "index" => 0
          })

        assert template =~ ~r/\b[fw]\[:[a-z_]+\]/, field
        refute template =~ "phx-debounce", "#{col}: #{field}"
      end

      {text, _params, {:joined, _name}} =
        FormPlacement.place(
          ~s(<.component component_name="chelekom-text-field" site="Global" label="Nick" />),
          session,
          %{"parent_id" => with_id(session, "n-col").id, "index" => 0}
        )

      assert text =~ ~s(phx-debounce="300")

      {input, _params, {:joined, _name}} =
        FormPlacement.place(~s(<.input type="text" name="nick" label="Nick" />), session, spot)

      assert input =~ ~s(phx-debounce="300")

      {kept, _params, _outcome} =
        FormPlacement.place(~s(<input name="q" phx-debounce="blur" />), session, spot)

      assert kept =~ ~s(phx-debounce="blur")
      refute kept =~ ~s(phx-debounce="300")
    end
  end

  describe "a form a file field is put in sends files" do
    test "filed/3 turns multipart on for the core form a deep file field lands in, not the kit's",
         %{chelekom: chelekom} do
      session = two_forms(chelekom)

      for {col, form_id, on?} <- [
            {"c-col-1", "contact-form", true},
            {"n-col", "news-form", false}
          ] do
        {:ok, tree} =
          Tree.insert(
            session.tree,
            Tree.parse!(~s(<input type="file" name="cv" />)),
            with_id(session, col).id,
            0
          )

        file = tree |> Tree.walk() |> Enum.find(&(Node.attr_text(&1, "type") == "file"))
        filed = FormPlacement.filed(tree, file.id, chelekom)
        form = Tree.get(filed, with_id(session, form_id).id)

        assert Node.attr(form, "multipart") == {:expr, "true"} == on?, form_id
        refute session.tree |> Tree.get(form.id) |> Node.attr("multipart")
      end

      loose = with_id(session, "loose")
      assert FormPlacement.filed(session.tree, loose.id, chelekom) == session.tree
    end

    test "wiring/4 turns multipart on for a core form holding a deep file field", %{
      chelekom: chelekom
    } do
      idle_core = fn inner ->
        ~s(<.form for={%{}} id="idle-form"><div class="card"><div class="grid"><div class="col">) <>
          inner <> ~s(</div></div></div></.form>)
      end

      {tree, filed} = idle(idle_core.(~s(<input type="file" name="cv" />)))
      {:ok, ops} = FormPlacement.wiring(tree, filed, chelekom)

      assert [%{node_id: id, value: "true", value_kind: :expr}] =
               Enum.filter(ops, &(&1[:name] == "multipart"))

      assert id == filed.id

      {plain_tree, plain} = idle(idle_core.(~s(<input type="text" name="cv" />)))
      {:ok, plain_ops} = FormPlacement.wiring(plain_tree, plain, chelekom)
      refute Enum.any?(plain_ops, &(&1[:name] == "multipart"))
    end
  end

  describe "a Send button the editor puts in a form says Sending… while it sends" do
    test "dropped deep in a core form or a kit wrapper, a raw, core or kit Send button", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)

      for col <- ~w(c-col-1 n-col),
          send <- [
            ~s(<button type="submit">Go</button>),
            ~s(<.button>Go</.button>),
            ~s(<.component component_name="chelekom-button" site="Global" type="submit">Go</.component>)
          ] do
        {template, _params, :none} =
          FormPlacement.place(send, session, %{
            "parent_id" => with_id(session, col).id,
            "index" => 0
          })

        assert template =~ ~s(phx-disable-with="Sending…"), "#{col}: #{send}"
      end

      for {spot, button} <- [
            {"c-col-1", ~s(<button type="submit" phx-disable-with="Paying…">Pay</button>)},
            {"c-col-1", ~s(<button type="button">Help</button>)},
            {"loose", ~s(<button type="submit">Go</button>)}
          ] do
        {template, _params, :none} =
          FormPlacement.place(button, session, %{
            "parent_id" => with_id(session, spot).id,
            "index" => 0
          })

        refute template =~ "Sending…", "#{spot}: #{button}"
      end
    end

    test "a kit form wired around its Send button gives it the words, unless it is a developer's",
         %{
           chelekom: chelekom
         } do
      {tree, node} = idle(@wrapper_card)
      {:ok, ops} = FormPlacement.wiring(tree, node, chelekom)

      assert [%{value: "Sending…"}] = Enum.filter(ops, &(&1[:name] == "phx-disable-with"))

      {tree, own} =
        idle(String.replace(@wrapper_card, ~s(for={%{}}), ~s(for={%{}} phx-submit="save_lead")))

      {:ok, kept} = FormPlacement.wiring(tree, own, chelekom, events: [%{name: "save_lead"}])
      refute Enum.any?(kept, &(&1[:name] == "phx-disable-with"))
    end
  end

  describe "landing/4 and marks/3" do
    test "the end of a form is in front of its first Send, wherever it sits", %{
      chelekom: chelekom
    } do
      session = two_forms(chelekom)
      news = with_id(session, "news-form")

      assert FormPlacement.landing(session.tree, with_id(session, "contact-form"), chelekom) ==
               {with_id(session, "c-foot").id, 1}

      assert {id, index} = FormPlacement.landing(session.tree, news, chelekom)
      assert id == news.id
      assert index == Tree.index_of(session.tree, with_id(session, "n-card").id) + 1
    end

    test "a form with no Send ends at its last child" do
      session =
        session(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><p>a</p><p>b</p></.form>))

      form = session.tree |> Tree.walk() |> hd()

      assert FormPlacement.landing(session.tree, form, []) == {form.id, 2}
    end

    test "marks every form with its people name and the node an end drop lands before", %{
      chelekom: chelekom
    } do
      {:ok, tree} = Tree.parse(~s(<div>#{@core_deep}#{@kit_deep}<form id="raw"></form></div>))
      session = %{tree: tree, section: "page", components: chelekom}

      {marks, memo} = FormPlacement.marks(tree, chelekom)

      assert marks.forms == %{
               with_id(session, "contact-form").id => "Contact",
               with_id(session, "news-form").id => "News",
               with_id(session, "raw").id => ""
             }

      send = tree |> Tree.walk() |> Enum.find(&(&1.tag == "button"))
      join = tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "chelekom-button"))
      assert marks.landings == MapSet.new([send.id, join.id])
      assert memo.roles["chelekom-form-wrapper"] == :wrapper
      assert FormPlacement.marks(tree, chelekom, memo) == {marks, memo}
    end
  end

  describe "people names" do
    test "a numbered default reads Form N, anything else in words with a capital" do
      assert Naming.people_name("form") == "Form 1"
      assert Naming.people_name("form_3") == "Form 3"
      assert Naming.people_name("contact") == "Contact"
      assert Naming.people_name("contact_us") == "Contact us"
      assert Naming.people_name("contact_2") == "Contact 2"
      assert Naming.people_name(nil) == nil
    end

    test "a sentence names a numbered form bare and any other as the X form" do
      assert FormPlacement.phrase("Form 2") == "Form 2"
      assert FormPlacement.phrase("Contact") == "the Contact form"
      assert FormPlacement.phrase(nil) == "the form"
      assert FormPlacement.told({:joined, "Contact"}) == "Added it to the Contact form."
      assert FormPlacement.told(:wired) == nil
    end

    test "only a working form has one", %{chelekom: chelekom} do
      session = two_forms(chelekom)

      assert FormPlacement.form_name(with_id(session, "contact-form")) == "Contact"
      assert FormPlacement.form_name(with_id(session, "c-col-1")) == nil

      assert FormPlacement.forms(session.tree) == [
               {with_id(session, "contact-form").id, "Contact"},
               {with_id(session, "news-form").id, "News"}
             ]
    end
  end

  describe "unit/3 and moving a field between forms" do
    @checkbox ~s(<div id="c-col-3"><label id="agree-label" class="flex"><input type="hidden" name={f[:agree].name} value="false" /><input id="agree-box" type="checkbox" name={f[:agree].name} value="true" />I agree</label></div>)

    @radios ~s(<div id="c-col-4"><fieldset id="plan-set"><legend>Plan</legend><label><input id="plan-one" type="radio" name={f[:plan].name} value="one" />One</label><label><input type="radio" name={f[:plan].name} value="two" />Two</label></fieldset></div>)

    defp grouped(chelekom) do
      source =
        String.replace(
          @two_forms,
          ~s(<div id="c-col-2">),
          @checkbox <> @radios <> ~s(<div id="c-col-2">)
        )

      {:ok, tree} = Tree.parse(source)
      %{tree: tree, section: "page", components: chelekom}
    end

    test "a field's unit is the highest box below its form that holds only it", %{
      chelekom: chelekom
    } do
      session = grouped(chelekom)

      assert FormPlacement.unit(session.tree, with_id(session, "agree-box"), chelekom).id ==
               with_id(session, "c-col-3").id

      assert FormPlacement.unit(session.tree, with_id(session, "plan-one"), chelekom).id ==
               with_id(session, "c-col-4").id

      email = session.tree |> Tree.walk() |> Enum.find(&(Node.attr_text(&1, "type") == "email"))

      assert FormPlacement.unit(session.tree, email, chelekom).id ==
               with_id(session, "c-col-2").id

      assert FormPlacement.unit(session.tree, with_id(session, "n-col"), chelekom).id ==
               with_id(session, "n-card").id

      assert FormPlacement.unit(session.tree, with_id(session, "c-grid"), chelekom) == nil
      assert FormPlacement.unit(session.tree, with_id(session, "contact-form"), chelekom) == nil
    end

    test "a lone control inside its label moves with the label and its column", %{
      chelekom: chelekom
    } do
      source =
        String.replace(
          @two_forms,
          ~s(<div id="c-col-2">),
          ~s(<div id="c-col-9"><label id="phone-label">Phone <input id="phone-box" name={f[:phone].name} /></label></div><div id="c-col-2">)
        )

      {:ok, tree} = Tree.parse(source)
      session = %{tree: tree, section: "page", components: chelekom}

      assert FormPlacement.unit(tree, with_id(session, "phone-box"), chelekom).id ==
               with_id(session, "c-col-9").id
    end

    test "options sharing a key in a plain box are one unit, unless the box holds another field",
         %{
           chelekom: chelekom
         } do
      options =
        ~s(<input id="size-s" type="radio" name={f[:size].name} value="s" />) <>
          ~s(<input type="radio" name={f[:size].name} value="m" />)

      for {extra, unit} <- [{"", "size-row"}, {~s(<input name={f[:note].name} />), "size-s"}] do
        source =
          String.replace(
            @two_forms,
            ~s(<div id="c-col-2">),
            ~s(<div id="size-row">#{options}#{extra}</div><div id="c-col-2">)
          )

        {:ok, tree} = Tree.parse(source)
        session = %{tree: tree, section: "page", components: chelekom}

        assert FormPlacement.unit(tree, with_id(session, "size-s"), chelekom).id ==
                 with_id(session, unit).id,
               unit
      end
    end

    # A Label element beside a raw Text input in one grid column, in the core form and in the
    # Chelekom wrapper: the label names nothing the form binds, and still goes with its field.
    defp labelled(chelekom) do
      source =
        @two_forms
        |> String.replace(
          ~s(<div id="c-col-2">),
          ~s(<div id="c-col-5"><label id="phone-name" for="phone-box" class="block">Phone</label><input id="phone-box" type="text" name={f[:phone].name} /></div><div id="c-col-2">)
        )
        |> String.replace(
          ~s(<div id="n-col">),
          ~s(<div id="n-col-2"><label id="code-name" for="code-box" class="block">Code</label><input id="code-box" type="text" name={w[:code].name} /></div><div id="n-col">)
        )

      {:ok, tree} = Tree.parse(source)
      %{tree: tree, section: "page", components: chelekom}
    end

    test "In form takes a field's Label element along, from either form", %{chelekom: chelekom} do
      session = labelled(chelekom)

      for {field, label, column, from, to, key} <- [
            {"phone-box", "phone-name", "c-col-5", "contact-form", "news-form", ~s(w[:phone])},
            {"code-box", "code-name", "n-col-2", "news-form", "contact-form", ~s(f[:code])}
          ] do
        assert FormPlacement.unit(session.tree, with_id(session, field), chelekom).id ==
                 with_id(session, column).id

        {:ok, ops, _note} =
          FormPlacement.move_ops(
            session,
            with_id(session, field).id,
            with_id(session, to).id
          )

        moved = run(session, ops)
        named = with_id(moved, label)

        assert Tree.descendant?(moved.tree, with_id(moved, to).id, named.id), label
        refute Tree.descendant?(moved.tree, with_id(moved, from).id, named.id), label
        assert html(moved) =~ key
      end
    end

    test "Move its fields into keeps each Label element with its field", %{chelekom: chelekom} do
      session = labelled(chelekom)
      contact = with_id(session, "contact-form")

      {:ok, ops, _note} =
        FormPlacement.merge_ops(session, with_id(session, "news-form").id, contact.id)

      merged = run(session, ops)

      assert Tree.descendant?(merged.tree, contact.id, with_id(merged, "code-name").id)
      assert keys(specs(merged)["contact"]) == [:name, :phone, :email, :code, :email_2]
    end

    test "a field in a component's slot moves without the slot", %{chelekom: chelekom} do
      source =
        String.replace(
          @two_forms,
          ~s(<div id="c-col-2">),
          ~s(<div id="c-col-6"><.component component_name="chelekom-card" site="Global" id="s-card"><:footer><input id="slot-box" name={f[:extra].name} /></:footer></.component></div><div id="c-col-2">)
        )

      {:ok, tree} = Tree.parse(source)
      session = %{tree: tree, section: "page", components: chelekom}
      slot = Tree.get(tree, with_id(session, "slot-box").parent_id)

      assert FormPlacement.unit(tree, with_id(session, "slot-box"), chelekom).id ==
               with_id(session, "slot-box").id

      {:ok, ops, _note} =
        FormPlacement.move_ops(
          session,
          with_id(session, "slot-box").id,
          with_id(session, "news-form").id
        )

      moved = run(session, ops)
      assert Tree.get(moved.tree, slot.id).parent_id == with_id(session, "s-card").id
    end

    test "a loose field beside a heading does not take its section along", %{chelekom: chelekom} do
      for {wrapped, unit} <- [
            {~s(<input id="lone" name="lone" />), "lone"},
            {~s(<label id="lone-label">Lone <input id="lone" name="lone" /></label>),
             "lone-label"}
          ] do
        source =
          String.replace(
            @two_forms,
            ~s(<div id="loose"></div>),
            ~s(<section id="hero"><h2>Join us</h2><div id="lone-col">#{wrapped}</div></section>)
          )

        {:ok, tree} = Tree.parse(source)
        session = %{tree: tree, section: "page", components: chelekom}

        assert FormPlacement.unit(tree, with_id(session, "lone"), chelekom).id ==
                 with_id(session, unit).id,
               unit
      end
    end

    test "moving a checkbox unit rebinds both controls in the other form, before its Send", %{
      chelekom: chelekom
    } do
      session = grouped(chelekom)
      news = with_id(session, "news-form")

      {:ok, ops, note} =
        FormPlacement.move_ops(session, with_id(session, "agree-box").id, news.id)

      moved = run(session, ops)

      assert note == "Moved it to the News form."
      assert keys(specs(moved)["news"]) == [:email, :agree]
      assert keys(specs(moved)["contact"]) == [:name, :plan, :email]
      assert html(moved) =~ ~s(<input type="hidden" name={w[:agree].name} value="false")
      assert html(moved) =~ ~s(name={w[:agree].name} value="true")
      assert Tree.get(moved.tree, with_id(session, "c-col-3").id).parent_id == news.id

      assert Tree.get(moved.tree, with_id(session, "agree-label").id).parent_id ==
               with_id(session, "c-col-3").id
    end

    test "moving a radio group moves the fieldset and every option", %{chelekom: chelekom} do
      session = grouped(chelekom)
      news = with_id(session, "news-form")

      {:ok, ops, _note} =
        FormPlacement.move_ops(session, with_id(session, "plan-one").id, news.id)

      moved = run(session, ops)

      assert keys(specs(moved)["news"]) == [:email, :plan]
      assert html(moved) =~ ~s(name={w[:plan].name} value="one")
      assert html(moved) =~ ~s(name={w[:plan].name} value="two")
      refute html(moved) =~ ~s(f[:plan])
    end

    test "dragging one control of a field into another form takes its whole field along", %{
      chelekom: chelekom
    } do
      session = grouped(chelekom)
      news = with_id(session, "news-form")
      n_col = with_id(session, "n-col").id

      moved =
        Enum.reduce(~w(agree-box plan-one), session, fn id, acc ->
          assert {:run, ops, "Added it to the News form."} =
                   FormPlacement.moving(acc, %{
                     "node_id" => with_id(acc, id).id,
                     "parent_id" => n_col,
                     "index" => 1
                   })

          run(acc, ops)
        end)

      assert keys(specs(moved)["contact"]) == [:name, :email]
      assert keys(specs(moved)["news"]) == [:email, :plan, :agree]
      assert html(moved) =~ ~s(<input type="hidden" name={w[:agree].name} value="false")
      assert html(moved) =~ ~s(id="agree-box" type="checkbox" name={w[:agree].name} value="true")
      assert html(moved) =~ ~s(name={w[:plan].name} value="one")
      assert html(moved) =~ ~s(name={w[:plan].name} value="two")
      refute html(moved) =~ ~r/f\[:(agree|plan)\]/

      for id <- ~w(agree-label plan-set),
          do: assert(Tree.descendant?(moved.tree, news.id, with_id(moved, id).id), id)
    end

    test "dragging one control of a field out of every form puts its whole field in a new one", %{
      chelekom: chelekom
    } do
      session = grouped(chelekom)

      assert {:run, ops, _started} =
               FormPlacement.moving(session, %{
                 "node_id" => with_id(session, "agree-box").id,
                 "parent_id" => with_id(session, "loose").id,
                 "index" => 0
               })

      moved = run(session, ops)

      assert keys(specs(moved)["form"]) == [:agree]
      assert keys(specs(moved)["contact"]) == [:name, :plan, :email]
      assert html(moved) =~ ~s(<input type="hidden" name={f[:agree].name} value="false")
    end

    test "a key the other form already uses is renamed", %{chelekom: chelekom} do
      session = two_forms(chelekom)
      email = session.tree |> Tree.walk() |> Enum.find(&(Node.attr_text(&1, "type") == "email"))

      {:ok, ops, _note} =
        FormPlacement.move_ops(session, email.id, with_id(session, "news-form").id)

      assert keys(specs(run(session, ops))["news"]) == [:email, :email_2]
    end

    test "the form it leaves with no fields is removed in the same step", %{chelekom: chelekom} do
      {:ok, tree} = Tree.parse(~s(<div id="page">#{@kit_deep}#{@core_deep}</div>))
      session = %{tree: tree, section: "page", components: chelekom}

      only =
        session.tree |> Tree.walk() |> Enum.find(&((Node.attr_text(&1, "name") || "") =~ "w[:"))

      {:ok, ops, note} =
        FormPlacement.move_ops(session, only.id, with_id(session, "contact-form").id)

      moved = run(session, ops)

      assert note == "Moved it to the Contact form. The empty form was removed."
      assert Map.keys(specs(moved)) == ["contact"]
      assert keys(specs(moved)["contact"]) == [:name, :email, :email_2]
    end

    test "to a new form: after the one it leaves, with a Send button", %{chelekom: chelekom} do
      session = grouped(chelekom)

      {:ok, ops, note} =
        FormPlacement.move_ops(
          session,
          with_id(session, "agree-box").id,
          FormPlacement.new_target()
        )

      moved = run(session, ops)

      assert note == "Moved it to a new form with a Send button."
      assert specs(moved)["form"] |> keys() == [:agree]
      assert Enum.map(PageForms.declared(html(moved)), & &1.as) == ~w(contact form news)
      assert html(moved) =~ ~s(name={f[:agree].name} value="true")
    end

    test "refuses what is not a field, and the form it is already in", %{chelekom: chelekom} do
      session = grouped(chelekom)
      contact = with_id(session, "contact-form").id

      assert {:error, _} = FormPlacement.move_ops(session, with_id(session, "c-grid").id, contact)

      assert {:error, "It is already in that form."} =
               FormPlacement.move_ops(session, with_id(session, "agree-box").id, contact)
    end

    test "merge_ops/3 moves every field of a form into another and removes it", %{
      chelekom: chelekom
    } do
      session = grouped(chelekom)
      news = with_id(session, "news-form").id

      {:ok, ops, note} =
        FormPlacement.merge_ops(session, with_id(session, "contact-form").id, news)

      merged = run(session, ops)

      assert note == "Moved its fields to the News form. The empty form was removed."
      assert Map.keys(specs(merged)) == ["news"]
      assert keys(specs(merged)["news"]) == [:email, :name, :agree, :plan, :email_2]
      refute html(merged) =~ "f[:"
    end
  end

  # Forms that bind no variable, each with its field in card > grid > column: nothing to bind to.
  describe "moving/2 into a form that binds no variable" do
    defp unwired(id, field),
      do:
        ~s(<.component component_name="chelekom-form-wrapper" site="Global" id="#{id}" for={%{}}>) <>
          ~s(<.component component_name="chelekom-card" site="Global"><div class="grid"><div id="#{id}-col">#{field}</div></div></.component></.component>)

    defp raw(id, field),
      do:
        ~s(<form id="#{id}"><div class="card"><div class="grid"><div id="#{id}-col">#{field}</div></div></div></form>)

    defp dragged(session, id, into),
      do: %{
        "node_id" => with_id(session, id).id,
        "parent_id" => with_id(session, into).id,
        "index" => 1
      }

    test "a field moves between two unwired Chelekom wrappers as it is, and both stay", %{
      chelekom: chelekom
    } do
      {:ok, tree} =
        Tree.parse(
          ~s(<div id="page">) <>
            unwired(
              "a-form",
              ~s(<.component component_name="chelekom-text-field" site="Global" id="a-email" name="email" value="" label="Email" />)
            ) <>
            unwired(
              "b-form",
              ~s(<.component component_name="chelekom-text-field" site="Global" id="b-phone" name="phone" value="" label="Phone" />)
            ) <> "</div>"
        )

      session = %{tree: tree, section: "page", components: chelekom}
      params = dragged(session, "a-email", "b-form-col")

      assert {:plain, spot} = FormPlacement.moving(session, params)

      moved =
        run(session, [
          %{
            kind: :move,
            node_id: params["node_id"],
            parent_id: spot["parent_id"],
            index: spot["index"]
          }
        ])

      assert html(moved) =~ ~s(id="a-email" name="email")
      refute html(moved) =~ "[:"
      assert with_id(moved, "a-form") && with_id(moved, "b-form")
    end

    test "a field moves between two raw forms as it is, and both stay", %{chelekom: chelekom} do
      {:ok, tree} =
        Tree.parse(
          ~s(<div id="page">#{raw("ra", ~s(<input id="ra-q" name="q" />))}#{raw("rb", ~s(<input name="z" />))}</div>)
        )

      session = %{tree: tree, section: "page", components: chelekom}

      assert {:plain, _spot} = FormPlacement.moving(session, dragged(session, "ra-q", "rb-col"))
    end
  end
end
