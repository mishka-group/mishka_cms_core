# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecksTest do
  @moduledoc """
  Every rule the Forms audit group can raise, and the tree edit each one's Fix makes.

  A finding is only worth having if it is true of the document, so each rule is read off a page that
  really has that fault and asserted absent from a page that does not. The repairs are applied for
  real, through `MishkaCmsCore.Runtime.PageBuilder.Op`, and the result read back as a form spec —
  which is the only thing that proves a fix produced markup the compiler will accept.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
  alias MishkaCmsCore.Runtime.PageBuilder.Op
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecks
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Test.Factory

  @moduletag :unit

  @real ~w(chelekom-button chelekom-input-button chelekom-card chelekom-text-field chelekom-form-wrapper chelekom-simple-form)

  # The real rows these checks meet on a Chelekom install, a renamed copy of the button, and a renamed
  # form pair only their markup marks as forms.
  setup_all do
    kit = Factory.chelekom_rows(@real)
    button = Enum.find(kit, &(&1.name == "chelekom-button"))

    {:ok, kit: [%{button | name: "my-kit-button"} | kit] ++ Factory.renamed_form_pair(kit)}
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

  @wrapper %{
    name: "kit-form",
    attrs: [],
    slots: [%{"name" => "inner_block"}],
    template: "",
    form: %{"role" => "wrapper"}
  }

  @healthy ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input type="email" name={f[:email].name} value={f[:email].value} /><button type="submit">Send</button></.form>)

  @tagged String.replace(@healthy, ~s(_validate"), ~s(-k7m2q-validate"))
          |> String.replace(~s(_submit"), ~s(-k7m2q-submit"))

  # A PAGE — forms are a page's, and the Fix that wraps a loose field goes through the same
  # `FormPlacement.wrap/3` the drop does, which now asks the session which section it is on.
  defp session(source), do: on(source, "page")

  defp on(source, section) do
    {:ok, tree} = Tree.parse(source)
    %{tree: tree, section: section, components: [@kit, @pair, @wrapper]}
  end

  defp record(names), do: %{events: Enum.map(names, &%{name: &1, code: "{:noreply, socket}"})}

  defp findings(source, record) do
    source
    |> session()
    |> then(&FormChecks.findings(&1.tree, record, &1))
  end

  defp rules(source, record \\ %{}), do: source |> findings(record) |> Enum.map(& &1.rule)

  defp one(source, rule, record \\ %{}) do
    source
    |> findings(record)
    |> Enum.filter(&(&1.rule == rule))
    |> single()
  end

  defp single([finding]), do: finding
  defp single(other), do: flunk("expected exactly one finding, got #{inspect(other)}")

  defp node_with(session, tag),
    do: session.tree |> Tree.walk() |> Enum.find(&(&1.tag == tag))

  defp forms(session),
    do: session.tree |> Tree.walk() |> Enum.filter(&(&1.tag == ".form"))

  defp inputs(session),
    do: session.tree |> Tree.walk() |> Enum.filter(&(&1.tag == "input"))

  defp apply_ops!(tree, ops), do: Enum.reduce(ops, tree, &apply_op!(&2, &1))

  defp apply_op!(tree, params) do
    {:ok, op} = Op.build(params)
    applied(Op.apply_to(op, tree))
  end

  defp applied({:ok, tree}), do: tree
  defp applied({:ok, tree, _focus}), do: tree

  defp specs(tree), do: tree |> Serializer.serialize() |> PageForms.declared()

  describe "a form with nothing wrong with it" do
    test "raises nothing at all" do
      assert findings(@healthy, record(["contact_submit"])) == []
    end

    test "is still reported as having nowhere to send what was typed when no handler exists" do
      assert rules(@healthy) == ["form-no-destination"]
    end
  end

  describe "forms?/2" do
    test "sees Phoenix's own component, a raw form element and a kit wrapper" do
      for source <- [
            @healthy,
            ~s(<form action="/x"><input name="a" /></form>),
            ~s(<div for={assigns[:x_form]}></div>),
            ~s(<.component component_name="kit-form" site="Global" />)
          ] do
        session = session(source)
        assert FormChecks.forms?(Tree.walk(session.tree), session)
      end
    end

    test "answers false for a page with only a loose field on it" do
      session = session(~s(<div><input name="a" /></div>))

      refute FormChecks.forms?(Tree.walk(session.tree), session)
    end
  end

  # ONLY A PAGE COMPILES A FORM. `FormPlacement.page_forms?/1` is why a drop into a layout, an error
  # page or a component leaves the field bare, and this group used to call that same field a blocker
  # whose Fix comes back through that gate as `:none`. Writing the form by hand only swapped it for
  # `form-no-destination`, which tells the author visitors are thanked and code can receive the form
  # — false where no compiler emits `__page_forms__/0`. What HTML itself is wrong about still runs
  # there.
  describe "a section that compiles no form handlers" do
    @loose ~s(<div><input name="email" /></div>)
    @by_hand ~s(<div><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name={f[:email].name} /><button type="submit">Send</button></.form></div>)

    @nested ~s(<header><form action="/search"><form action="/x"><input name="q" /><button>Go</button></form></form></header>)
    @unsendable ~s(<header><form action="/search"><input type="text" name="q" /></form></header>)
    @stray ~s(<div><form action="/s"><input name="q" /><button>Go</button></form><button type="submit">Send</button></div>)

    for section <- ~w(layout error_page error-page component) do
      test "asks nothing of the page-form model on a #{section}" do
        for source <- [@loose, @by_hand] do
          session = on(source, unquote(section))

          assert FormChecks.findings(session.tree, %{}, session) == []
          refute FormChecks.forms?(Tree.walk(session.tree), session)
        end
      end

      # A SEARCH BOX IN A LAYOUT HEADER IS ORDINARY MARKUP, and these three are true of it wherever
      # it was written — the browser really does drop the inner form. Suppressing them with the rest
      # would lose a warning the author can act on to spare them two they cannot.
      test "still reports what HTML itself is wrong about on a #{section}" do
        for {source, rule} <- [
              {@nested, "form-in-form"},
              {@unsendable, "form-no-submit"},
              {@stray, "submit-no-form"}
            ] do
          session = on(source, unquote(section))

          assert Enum.map(FormChecks.findings(session.tree, %{}, session), & &1.rule) == [rule]
        end
      end

      test "and its Fix edits the #{section} instead of coming back through the insert gate" do
        session = on(@unsendable, unquote(section))

        assert {:op, %{"kind" => "insert"}} =
                 FormChecks.repair(session, "form-no-submit", node_with(session, "form").id)
      end
    end

    test "while a page raises both of the blockers nothing there could clear" do
      assert "field-no-form" in rules(@loose)
      assert "form-no-destination" in rules(@by_hand)
    end
  end

  describe "field-no-form" do
    test "is a blocker on a control that names itself, and says what it costs" do
      finding = one(~s(<div><input name="email" /></div>), "field-no-form")

      assert finding.severity == :blocker
      assert finding.group == :forms
      assert finding.message == "This field is not inside a form"

      assert finding.detail ==
               "Nothing submits it, so what the visitor types never leaves the page."
    end

    # A BOUND FIELD OUT HERE IS NOT THE SAME FAULT. It still reads the `:let` variable of the form it
    # came from, nothing binds it, and `MishkaCmsCore.Runtime.PageBuilder.CodeCheck` — the validation
    # on the page's own action — refuses to store the page at all. `code_check_test.exs` compiles
    # exactly this markup and gets `undefined variable "f"`.
    test "says the page cannot be saved when the field is bound to a form that is gone" do
      finding =
        one(~s(<section><.input field={f[:email]} type="text" /></section>), "field-no-form")

      assert finding.severity == :blocker
      assert finding.detail == "This page cannot be saved until it is back inside a form."
    end

    test "reads the binding off a name and value pair too" do
      finding =
        one(
          ~s(<section><input name={f[:email].name} value={f[:email].value} /></section>),
          "field-no-form"
        )

      assert finding.detail == "This page cannot be saved until it is back inside a form."
    end

    test "covers a kit component the palette says is a field" do
      source = ~s(<div><.component component_name="kit-text-field" site="Global" /></div>)

      assert "field-no-form" in rules(source)
    end

    # `<.input>` IS THE FIELD EVERY SHIPPED FORM IS BUILT OUT OF, and it is not a palette row — it is
    # `MishkaCmsCore.CoreComponents.input/1`. Asked of the catalog alone it answered "not a field",
    # so dragging one out of its form raised nothing here and then failed to compile on publish,
    # because `f[:email]` with no `:let` in scope is an undefined variable.
    test "covers the CMS's own field component, which is in no catalog" do
      assert "field-no-form" in rules(
               ~s(<section><.input field={f[:email]} type="text" /></section>)
             )
    end

    test "is not raised for the CMS's own field inside a form" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><.input field={f[:email]} type="text" /></.form>)

      refute "field-no-form" in rules(source)
      refute "field-no-key" in rules(source)
    end

    test "is not raised for a field that is inside one" do
      refute "field-no-form" in rules(@healthy, record(["contact_submit"]))
    end

    test "is not raised for a button, which carries no value" do
      refute "field-no-form" in rules(~s(<div><input type="submit" name="go" /></div>))
    end

    test "Fix wraps the field in a form and takes the loose one away" do
      session = session(~s(<div><input name="email" /></div>))
      node = node_with(session, "input")

      assert {:ops, ops} = FormChecks.repair(session, "field-no-form", node.id)

      tree = apply_ops!(session.tree, ops)

      assert [spec] = specs(tree)
      assert spec.as == "form"
      assert spec.assign == :form_form
      assert spec.id == "form"
      assert spec.fields == [%{key: :email, type: :string, rules: []}]
      assert Tree.get(tree, node.id) == nil
    end

    test "Fix keeps the field where it stood among its siblings" do
      session = session(~s(<div><p>before</p><input name="email" /><p>after</p></div>))
      node = node_with(session, "input")

      {:ops, ops} = FormChecks.repair(session, "field-no-form", node.id)

      assert session.tree
             |> apply_ops!(ops)
             |> Serializer.serialize() =~ ~r{<p>before</p><\.form.*</\.form><p>after</p>}
    end
  end

  describe "field-no-key" do
    test "is a blocker on a field inside a form that binds nothing" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><.component component_name="kit-text-field" site="Global" /></.form>)

      finding = one(source, "field-no-key")

      assert finding.severity == :blocker
      assert finding.message == "This field has no name"
      assert finding.detail == "Two unnamed fields overwrite each other on submit."
    end

    test "is not raised for a control carrying a literal name" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><input name="email" /></.form>)

      refute "field-no-key" in rules(source)
    end

    test "Fix writes the binding on the attribute the kit declared" do
      session =
        session(
          ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><.component component_name="kit-text-field" site="Global" /></.form>)
        )

      node = node_with(session, ".component")

      assert {:ops, ops} = FormChecks.repair(session, "field-no-key", node.id)

      tree = apply_ops!(session.tree, ops)

      assert Serializer.serialize(tree) =~ ~s(bind={f[:kit_text_field]})
      assert [%{fields: [%{key: :kit_text_field}]}] = specs(tree)
    end

    test "Fix writes the name and value pair for a kit that takes no form field struct" do
      session =
        session(
          ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><.component component_name="kit-pair-field" site="Global" caption="Email" /></.form>)
        )

      node = node_with(session, ".component")

      {:ops, ops} = FormChecks.repair(session, "field-no-key", node.id)
      source = session.tree |> apply_ops!(ops) |> Serializer.serialize()

      assert source =~ ~s(input_name={f[:email].name})
      assert source =~ ~s(input_value={f[:email].value})
    end

    test "Fix takes a key the form is not already using" do
      session =
        session(
          ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><input name={f[:email].name} /><.component component_name="kit-pair-field" site="Global" caption="Email" /></.form>)
        )

      node = node_with(session, ".component")

      {:ops, ops} = FormChecks.repair(session, "field-no-key", node.id)

      assert session.tree |> apply_ops!(ops) |> Serializer.serialize() =~
               ~s(input_name={f[:email_2].name})
    end

    test "Fix defers to the assistant when the form binds no variable to bind to" do
      session =
        session(
          ~s(<.form id="q-form" as={:q} for={assigns[:q_form]}><.component component_name="kit-text-field" site="Global" /></.form>)
        )

      assert FormChecks.repair(session, "field-no-key", node_with(session, ".component").id) ==
               :none
    end
  end

  describe "form-no-as" do
    test "is a blocker on a form with no param name" do
      finding =
        one(
          ~s(<.form :let={f} id="signup-form" for={assigns[:signup_form]}></.form>),
          "form-no-as"
        )

      assert finding.severity == :blocker
      assert finding.message == "This form has no name of its own"
      assert finding.detail == "Two forms on this page would mix up each other's answers."
    end

    test "Fix derives the name from the form's own id" do
      session = session(~s(<.form :let={f} id="signup-form" for={assigns[:signup_form]}></.form>))

      assert {:op, op} = FormChecks.repair(session, "form-no-as", node_with(session, ".form").id)

      assert session.tree |> apply_op!(op) |> Serializer.serialize() =~ ~s(as={:signup})
    end

    test "Fix mints a name no other form is using" do
      session =
        session(
          ~s(<div><.form :let={f} as={:signup} for={assigns[:signup_form]}></.form><.form :let={g} id="signup-form" for={assigns[:x_form]}></.form></div>)
        )

      node = session |> forms() |> List.last()

      {:op, op} = FormChecks.repair(session, "form-no-as", node.id)

      assert session.tree |> apply_op!(op) |> Serializer.serialize() =~ ~s(as={:signup_2})
    end
  end

  describe "form-no-source" do
    test "is a blocker on a form pointing at no page assign" do
      finding = one(~s(<.form :let={f} id="q-form" as={:q}></.form>), "form-no-source")

      assert finding.severity == :blocker
      assert finding.message == "This form has nowhere to keep what was typed"
      assert finding.detail == "It comes back empty every time, and never says what was wrong."
    end

    test "Fix points it at the assign its param name derives" do
      session = session(~s(<.form :let={f} id="q-form" as={:contact}></.form>))

      {:op, op} = FormChecks.repair(session, "form-no-source", node_with(session, ".form").id)

      assert session.tree |> apply_op!(op) |> Serializer.serialize() =~
               ~s(for={assigns[:contact_form]})
    end
  end

  describe "form-duplicate-seed" do
    @two ~s(<div><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"></.form><.form :let={g} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"></.form></div>)

    test "names the shared seed and fires once, on the second form" do
      session = session(@two)

      assert [finding] =
               session.tree
               |> FormChecks.findings(record(["contact_submit"]), session)
               |> Enum.filter(&(&1.rule == "form-duplicate-seed"))

      assert finding.severity == :blocker
      assert finding.message == ~s(Two forms share the name "contact")
      assert finding.detail == "Typing in one of them shows up in the other."
      assert finding.node_id == session |> forms() |> List.last() |> Map.fetch!(:id)
    end

    test "Fix renumbers all five of the second form's derived names" do
      session = session(@two)
      node = session |> forms() |> List.last()

      assert {:ops, ops} = FormChecks.repair(session, "form-duplicate-seed", node.id)
      assert length(ops) == 5

      tree = apply_ops!(session.tree, ops)

      assert [_first, second] = specs(tree)
      assert second.as == "contact_2"
      assert second.assign == :contact_2_form
      assert second.id == "contact_2-form"

      # Renamed, so it leaves the untagged names behind and takes a token of its own.
      assert second.change =~ ~r/^contact_2-[a-z2-7]{5}-validate$/
      assert second.submit =~ ~r/^contact_2-[a-z2-7]{5}-submit$/
    end

    test "Fix keeps the second form's token when no other form holds it" do
      session =
        session(@tagged <> String.replace(@tagged, "k7m2q", "p3xa6"))

      node = session |> forms() |> List.last()

      assert {:ops, ops} = FormChecks.repair(session, "form-duplicate-seed", node.id)
      assert [_first, second] = specs(apply_ops!(session.tree, ops))

      assert {second.change, second.submit} ==
               {"contact_2-p3xa6-validate", "contact_2-p3xa6-submit"}
    end

    test "and gives it a fresh one when it shares the first form's" do
      session = session(@tagged <> @tagged)
      node = session |> forms() |> List.last()

      assert {:ops, ops} = FormChecks.repair(session, "form-duplicate-seed", node.id)
      assert [first, second] = specs(apply_ops!(session.tree, ops))
      assert first.submit == "contact-k7m2q-submit"
      assert second.submit =~ ~r/^contact_2-[a-z2-7]{5}-submit$/
      refute second.submit == "contact_2-k7m2q-submit"
    end
  end

  describe "form-duplicate-token" do
    @sharing @tagged <> String.replace(@tagged, "contact", "newsletter")

    test "fires once, on the later of two forms carrying one token" do
      session = session(@sharing)

      assert [finding] =
               session.tree
               |> FormChecks.findings(record([]), session)
               |> Enum.filter(&(&1.rule == "form-duplicate-token"))

      assert finding.severity == :blocker
      assert finding.message == "Two forms answer to the same handlers"
      assert finding.node_id == session |> forms() |> List.last() |> Map.fetch!(:id)
    end

    test "is not raised for forms with tokens of their own, or none" do
      refute "form-duplicate-token" in rules(
               @tagged <> String.replace(@healthy, "contact", "newsletter")
             )

      refute "form-duplicate-token" in rules(
               @tagged <>
                 (@tagged
                  |> String.replace("contact", "newsletter")
                  |> String.replace("k7m2q", "p3xa6"))
             )
    end

    test "Fix gives the later form a fresh token and leaves its seed alone" do
      session = session(@sharing)
      node = session |> forms() |> List.last()

      assert {:ops, ops} = FormChecks.repair(session, "form-duplicate-token", node.id)

      tree = apply_ops!(session.tree, ops)

      assert [first, second] = specs(tree)
      assert first.submit == "contact-k7m2q-submit"
      assert second.as == "newsletter"
      assert second.submit =~ ~r/^newsletter-[a-z2-7]{5}-submit$/
      assert second.change =~ ~r/^newsletter-[a-z2-7]{5}-validate$/
      refute second.submit == "newsletter-k7m2q-submit"

      assert "form-duplicate-token" not in (tree
                                            |> FormChecks.findings(record([]), %{
                                              session
                                              | tree: tree
                                            })
                                            |> Enum.map(& &1.rule))
    end
  end

  # THE FIVE NAMES CAN DISAGREE, and grouping by the param name alone never saw it. Duplicate a form
  # and change only the copy's `as` in the code drawer: `PageForm.validate/4` resolves a spec by its
  # assign and takes the first match, so the copy posts under a param name that spec does not scope,
  # reads back `%{}`, and every keystroke in it empties the form the visitor filled in first — which
  # renders from the same assign. The rail said the page was clean.
  describe "form-duplicate-source" do
    @shared ~s(<div><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"></.form><.form :let={g} id="contact2-form" as={:contact2} for={assigns[:contact_form]} phx-change="contact2_validate" phx-submit="contact2_submit"></.form></div>)

    test "names the shared assign and fires once, on the second form" do
      session = session(@shared)

      assert [finding] =
               session.tree
               |> FormChecks.findings(record(["contact_submit", "contact2_submit"]), session)
               |> Enum.filter(&(&1.rule == "form-duplicate-source"))

      assert finding.severity == :blocker
      assert finding.message == "Two forms keep what is typed in the same place"
      assert finding.detail == "Both read contact_form, so typing in this one empties the other."
      assert finding.node_id == session |> forms() |> List.last() |> Map.fetch!(:id)
    end

    test "Fix re-derives all five from the form's own param name" do
      session = session(@shared)
      node = session |> forms() |> List.last()

      assert {:ops, ops} = FormChecks.repair(session, "form-duplicate-source", node.id)

      tree = apply_ops!(session.tree, ops)

      assert [first, second] = specs(tree)
      assert first.assign == :contact_form
      assert second.assign == :contact2_form
      assert second.as == "contact2"
    end

    # One form, one finding. A pair sharing both names carries the duplicate-seed blocker, and
    # renumbering is the same repair either one would ask for.
    test "says nothing extra about a pair that already shares its param name" do
      assert session(@two)
             |> then(&FormChecks.findings(&1.tree, record(["contact_submit"]), &1))
             |> Enum.filter(&(&1.rule in ["form-duplicate-seed", "form-duplicate-source"]))
             |> Enum.map(& &1.rule) == ["form-duplicate-seed"]
    end

    test "and nothing at all about two forms that keep their own" do
      assert "form-duplicate-source" not in rules(@healthy, record(["contact_submit"]))
    end
  end

  # THE RAIL RE-RUNS ON EVERY RENDER while it is the open tab, so an author typing a `name=` into the
  # Inspector used to mint one permanent atom per intermediate value — `e`, `em`, `ema`, `emai`,
  # `email` — from a source with no bound on it. Atoms are never collected. The one consumer,
  # `Naming.field_key/2`, compares text either way.
  describe "what an audit pass interns" do
    test "nothing, for a name nobody has ever written down" do
      unseen = "n#{System.unique_integer([:positive])}"

      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><input name="#{unseen}" /><button type="submit">Send</button></.form>)

      assert "field-no-key" not in rules(source, record(["q_submit"]))
      assert_raise ArgumentError, fn -> String.to_existing_atom(unseen) end
    end

    test "and a control with no name at all is still reported as having none" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><input type="text" /></.form>)

      assert "field-no-key" in rules(source, record(["q_submit"]))
    end
  end

  describe "field-duplicate-key" do
    @duplicated ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><input name={f[:email].name} value={f[:email].value} /><input name={f[:email].name} value={f[:email].value} /></.form>)

    test "names the shared key and fires once, on the second field" do
      session = session(@duplicated)

      assert [finding] =
               session.tree
               |> FormChecks.findings(%{}, session)
               |> Enum.filter(&(&1.rule == "field-duplicate-key"))

      assert finding.severity == :blocker
      assert finding.message == ~s(Two fields share the name "email")
      assert finding.detail =~ "replaces the first"
      assert finding.node_id == session |> inputs() |> List.last() |> Map.fetch!(:id)
    end

    test "is not raised for two fields under keys of their own" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><input name={f[:email].name} value={f[:email].value} /><input name={f[:phone].name} value={f[:phone].value} /></.form>)

      refute "field-duplicate-key" in rules(source)
    end

    # A CHECKBOX IS ONE FIELD IN TWO CONTROLS: the hidden `false` and the box that sends `true` share
    # the key on purpose, and so does every option in a radio group.
    test "is not raised for a group of controls answering to one key" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><label><input type="hidden" name={f[:agree].name} value="false" /><input type="checkbox" name={f[:agree].name} value="true" />I agree</label></.form>)

      refute "field-duplicate-key" in rules(source)
    end

    # EACH FORM SCOPES ITS OWN PARAMS, so two forms both holding an `email` collide nowhere: one
    # posts `contact[email]` and the other `signup[email]`.
    test "is not raised for one key used once in each of two forms" do
      source =
        ~s(<.form :let={f} id="a-form" as={:a} for={assigns[:a_form]}><input name={f[:email].name} value={f[:email].value} /></.form><.form :let={g} id="b-form" as={:b} for={assigns[:b_form]}><input name={g[:email].name} value={g[:email].value} /></.form>)

      refute "field-duplicate-key" in rules(source)
    end

    test "is not raised for a label that names the field beside it" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><label for={f[:email].id}>Email</label><input name={f[:email].name} value={f[:email].value} /></.form>)

      refute "field-duplicate-key" in rules(source)
    end

    test "Fix moves the second field onto a key of its own, both attributes together" do
      session = session(@duplicated)
      node = session |> inputs() |> List.last()

      assert {:ops, ops} = FormChecks.repair(session, "field-duplicate-key", node.id)

      tree = apply_ops!(session.tree, ops)

      assert [spec] = specs(tree)
      assert Enum.map(spec.fields, & &1.key) == [:email, :email_2]
      assert Serializer.serialize(tree) =~ ~s(name={f[:email_2].name} value={f[:email_2].value})
    end
  end

  describe "form-no-destination" do
    test "is a note for developers when nothing declares a handler for the submit" do
      finding = one(@healthy, "form-no-destination")

      assert finding.severity == :note
      assert finding.message == "Nothing receives this form"

      assert finding.detail ==
               "Visitors see the Success message, but what they type is not kept or sent anywhere yet."
    end

    test "is cleared by a handler the page declares under that name" do
      refute "form-no-destination" in rules(@healthy, record(["contact_submit"]))
    end

    test "is not cleared by a handler under some other name" do
      assert "form-no-destination" in rules(@healthy, record(["newsletter_submit"]))
    end

    test "is cleared by a handler stored under the form's name before a rename, by its token" do
      refute "form-no-destination" in rules(@tagged, record(["enquiry-k7m2q-submit"]))
      assert "form-no-destination" in rules(@tagged, record(["enquiry-k7m2q-validate"]))
      assert "form-no-destination" in rules(@tagged, record(["enquiry-p3xa6-submit"]))
    end

    # CUSTOMIZE THEN SAVE MUST NOT SILENCE IT. The default code prints and then does what the
    # generated handler does, so nothing more receives the answers than before.
    test "is not cleared by the default code nobody has edited" do
      for code <- [
            LiveViewCompiler.form_handler_sample(:submit, "contact-k7m2q-submit"),
            LiveViewCompiler.form_handler_source(:submit, "contact-k7m2q-submit")
          ],
          name <- ["contact-k7m2q-submit", "enquiry-k7m2q-submit"] do
        record = %{events: [%{name: name, code: code}]}

        assert "form-no-destination" in rules(@tagged, record),
               "an untouched #{inspect(code)} under #{name} is not a destination"
      end
    end

    test "is cleared once the default code is edited" do
      code = LiveViewCompiler.form_handler_sample(:submit, "contact-k7m2q-submit")
      edited = String.replace(code, "params)", "params, &MyApp.store/1)")

      refute "form-no-destination" in rules(@tagged, %{
               events: [%{name: "contact-k7m2q-submit", code: edited}]
             })
    end

    test "fires on a form that names no submit event at all" do
      source = ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}></.form>)

      assert "form-no-destination" in rules(source, record(["q_submit"]))
    end

    # The Fix names the form's submit event for the Code window, and carries a plain sentence for
    # someone who cannot write code.
    test "Fix names the submit event to open in code, and a plain sentence for anyone else" do
      session = session(@tagged)

      assert {:code, "contact-k7m2q-submit", sentence} =
               FormChecks.repair(session, "form-no-destination", node_with(session, ".form").id)

      refute sentence =~ "handler"
      refute sentence =~ "contact"
      refute sentence =~ "administrator"
    end

    test "Fix gives a form with no submit event one, with the form's own token" do
      source =
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q-k7m2q-validate"><button type="submit">Go</button></.form>)

      session = session(source)
      form = node_with(session, ".form")

      assert {:op, op} = FormChecks.repair(session, "form-no-destination", form.id)

      assert [spec] = specs(apply_op!(session.tree, op))
      assert spec.submit == "q-k7m2q-submit"
    end

    @search ~s(<form id="search-form" action="/search" method="get"><input type="search" name="q" /><button type="submit">Go</button></form>)

    @deep_search ~s(<form id="search-form" action="/search" method="get"><div class="card"><div class="grid"><div class="col"><input type="search" name="q" /></div><div class="col"><button type="submit">Go</button></div></div></div></form>)

    test "is not raised on a form that posts to its own address, and its Fix writes nothing" do
      for source <- [@search, @deep_search, "<div>" <> @deep_search <> @healthy <> "</div>"] do
        session = session(source)
        search = with_id(session, "search-form")

        refute Enum.any?(
                 FormChecks.findings(session.tree, %{}, session),
                 &(&1.rule == "form-no-destination" and &1.node_id == search.id)
               )

        assert FormChecks.repair(session, "form-no-destination", search.id) == :none
      end

      assert "form-no-destination" in rules("<div>" <> @deep_search <> @healthy <> "</div>")
    end

    # One edit per click: the form's name, then its source, then its submit event, and then code.
    test "Fix finishes a raw form deep in a card, then names its submit event for code" do
      raw =
        ~s(<form id="search-form" phx-submit="search_go"><div class="card"><div class="grid"><div class="col"><input type="search" name="q" /></div><div class="col"><button type="submit">Go</button></div></div></div></form>)

      for source <- [raw, "<div>" <> raw <> @healthy <> "</div>"] do
        assert fix_steps(source, "search-form") == ["as", "for", {:code, "search_go"}]
      end
    end

    test "Fix gives a form with no name its name first, and one with no source its source" do
      no_as =
        ~s(<.form :let={f} id="q-form" for={assigns[:q_form]} phx-submit="q_submit"><div class="card"><div class="grid"><div class="col"><input name={f[:q].name} /></div><div class="col"><button type="submit">Go</button></div></div></div></.form>)

      no_source = String.replace(no_as, "for={assigns[:q_form]}", "as={:q}")

      assert fix_steps(no_as, "q-form") == ["as", {:code, "q_submit"}]
      assert fix_steps(no_source, "q-form") == ["for", {:code, "q_submit"}]

      assert fix_steps("<div>" <> no_as <> @healthy <> "</div>", "q-form") == [
               "as",
               {:code, "q_submit"}
             ]
    end

    test "Fix wires an unwired kit wrapper deep in a card, then names its submit event" do
      wrapper =
        ~s(<.component component_name="kit-form" site="Global" id="news-form"><div class="card"><div class="grid"><div class="col"><input name="email" /></div><div class="col"><button type="submit">Join</button></div></div></div></.component>)

      for source <- [wrapper, "<div>" <> @healthy <> wrapper <> "</div>"] do
        assert fix_steps(source, "news-form") == [
                 "as",
                 "for",
                 "phx-submit",
                 {:code, "news_submit"}
               ]
      end
    end
  end

  # What each click of the note's Fix does to the form with this DOM id, applied in turn: the
  # attribute an op writes, or `{:code, event}` once the form is answered in code.
  defp fix_steps(source, dom_id) do
    session = session(source)
    id = with_id(session, dom_id).id

    Enum.reduce_while(1..5, {session.tree, []}, fn _click, {tree, steps} ->
      case FormChecks.repair(%{session | tree: tree}, "form-no-destination", id) do
        {:op, op} -> {:cont, {apply_op!(tree, op), [op["name"] | steps]}}
        {:code, event, _sentence} -> {:halt, {tree, [{:code, event} | steps]}}
        other -> {:halt, {tree, [other | steps]}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  describe "receiver/2, the check form-no-destination makes" do
    defp contact(source), do: source |> session() |> node_with(".form")

    test "is :none with no handler, and with a handler for another event" do
      assert FormChecks.receiver(contact(@tagged), %{}) == :none

      assert FormChecks.receiver(contact(@tagged), record(["contact-k7m2q-validate"])) ==
               :none
    end

    test "is :code for a written handler, by name or by token" do
      assert FormChecks.receiver(contact(@tagged), record(["contact-k7m2q-submit"])) == :code
      assert FormChecks.receiver(contact(@tagged), record(["enquiry-k7m2q-submit"])) == :code
    end

    test "is :none for the default code as Customize wrote it" do
      sample = LiveViewCompiler.form_handler_sample(:submit, "contact-k7m2q-submit")

      assert FormChecks.receiver(contact(@tagged), %{
               events: [%{"name" => "contact-k7m2q-submit", "code" => sample}]
             }) == :none
    end

    test "is :none for a form that names no submit event" do
      source = ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}></.form>)

      assert FormChecks.receiver(contact(source), record(["q_submit"])) == :none
    end

    test "is :action for a form that names no submit event and posts to its own address" do
      for source <- [@search, @deep_search] do
        assert FormChecks.receiver(source |> session() |> node_with("form"), %{}) == :action
      end

      page_form =
        String.replace(@healthy, ~s( phx-submit="contact_submit"), ~s( action="/thanks"))

      assert FormChecks.receiver(contact(page_form), %{}) == :action
    end

    test "a submit event is answered by code or by nothing, whatever the action says" do
      with_event = String.replace(@search, "<form ", ~s(<form phx-submit="search_go" ))
      form = with_event |> session() |> node_with("form")

      assert FormChecks.receiver(form, %{}) == :none
      assert FormChecks.receiver(form, record(["search_go"])) == :code
    end
  end

  describe "form-in-form" do
    @nested ~s(<.form :let={f} id="a-form" as={:a} for={assigns[:a_form]} phx-change="a_validate" phx-submit="a_submit"><.form :let={g} id="b-form" as={:b} for={assigns[:b_form]} phx-change="b_validate" phx-submit="b_submit"><button type="submit">Go</button></.form><button type="submit">Go</button></.form>)

    test "is a warning on the inner form" do
      finding = one(@nested, "form-in-form", record(["a_submit", "b_submit"]))

      assert finding.severity == :warning
      assert finding.message == "This form is inside another form"
      assert finding.detail =~ "everything after it stops submitting"
    end

    test "Fix unwraps the inner one" do
      session = session(@nested)
      inner = session |> forms() |> List.last()

      assert FormChecks.repair(session, "form-in-form", inner.id) ==
               {:op, %{"kind" => "unwrap", "node_id" => inner.id}}
    end

    # UNWRAPPING DELETES THE `:let` THE FIELDS INSIDE READ. Taking this one away leaves `g[:email]`
    # bound to nothing, which `MishkaCmsCore.Runtime.PageBuilder.CodeCheck` refuses the whole page
    # for — a Fix that turns a warning into an unsaveable page.
    test "Fix refuses when the fields inside would be left reading a form that is gone" do
      session =
        session(
          ~s(<.form :let={f} id="a-form" as={:a} for={assigns[:a_form]}><.form :let={g} id="b-form" as={:b} for={assigns[:b_form]}><input name={g[:email].name} value={g[:email].value} /></.form></.form>)
        )

      inner = session |> forms() |> List.last()

      assert {:say, sentence} = FormChecks.repair(session, "form-in-form", inner.id)
      assert sentence =~ "fields inside it"
    end

    test "Fix unwraps when the form around it binds the same variable those fields read" do
      session =
        session(
          ~s(<.form :let={f} id="a-form" as={:a} for={assigns[:a_form]}><.form :let={f} id="b-form" as={:b} for={assigns[:b_form]}><input name={f[:email].name} value={f[:email].value} /></.form></.form>)
        )

      inner = session |> forms() |> List.last()

      assert FormChecks.repair(session, "form-in-form", inner.id) ==
               {:op, %{"kind" => "unwrap", "node_id" => inner.id}}
    end
  end

  describe "form-no-change" do
    test "is a warning on a form that only checks on send" do
      source =
        ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-submit="contact_submit"><button type="submit">Send</button></.form>)

      finding = one(source, "form-no-change", record(["contact_submit"]))

      assert finding.severity == :warning
      assert finding.message == "This form checks only when sent"

      assert finding.detail ==
               "The visitor finds out what they got wrong after they press Send, not while they type."
    end

    test "Fix names the validate event after the form's own seed" do
      session =
        session(
          ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-submit="contact_submit"></.form>)
        )

      {:op, op} = FormChecks.repair(session, "form-no-change", node_with(session, ".form").id)

      assert session.tree |> apply_op!(op) |> Serializer.serialize() =~
               ~s(phx-change="contact_validate")
    end

    test "Fix keeps the form's token in the validate event it writes" do
      session =
        session(
          ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-submit="contact-k7m2q-submit"></.form>)
        )

      {:op, op} = FormChecks.repair(session, "form-no-change", node_with(session, ".form").id)

      assert session.tree |> apply_op!(op) |> Serializer.serialize() =~
               ~s(phx-change="contact-k7m2q-validate")
    end
  end

  describe "form-no-submit" do
    @buttonless ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name={f[:email].name} /></.form>)

    test "is a warning on a form nothing can send" do
      finding = one(@buttonless, "form-no-submit", record(["q_submit"]))

      assert finding.severity == :warning
      assert finding.message == "This form has no submit button"
      assert finding.detail == "Most visitors will have no way to send it."
    end

    test "is not raised for a bare button, which HTML already treats as the submit" do
      source = String.replace(@buttonless, "</.form>", "<button>Send</button></.form>")

      refute "form-no-submit" in rules(source, record(["q_submit"]))
    end

    test "is raised when the only button says it is not one" do
      source =
        String.replace(@buttonless, "</.form>", ~s(<button type="button">x</button></.form>))

      assert "form-no-submit" in rules(source, record(["q_submit"]))
    end

    test "Fix appends the styled Send button from Elements to the form" do
      session = session(@buttonless)

      {:op, op} = FormChecks.repair(session, "form-no-submit", node_with(session, ".form").id)

      assert op["template"] == FormPlacement.send_button()
      assert op["template"] == Elements.get("el-submit").template

      fixed = apply_op!(session.tree, op)
      button = fixed |> Tree.walk() |> Enum.find(&(&1.tag == "button"))

      assert button.parent_id == node_with(session, ".form").id
      assert Node.attr_text(button, "type") == "submit"
      assert Node.attr_text(button, "class") =~ "bg-slate-900"

      refute "form-no-submit" in (fixed
                                  |> Serializer.serialize()
                                  |> rules(record(["q_submit"])))
    end
  end

  describe "submit-no-form" do
    test "is a warning on a submit button outside every form" do
      finding = one(~s(<div><button type="submit">Go</button></div>), "submit-no-form")

      assert finding.severity == :warning
      assert finding.message == "This submit button is not inside a form"
      assert finding.detail == "It has nothing to send."
    end

    test "is not raised for an ordinary button with no type on it" do
      assert rules(~s(<div><button>Go</button></div>)) == []
    end

    test "Fix moves it into the page's only form" do
      session =
        session(
          ~s(<div><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name={f[:email].name} /></.form><button type="submit">Go</button></div>)
        )

      node = node_with(session, "button")

      assert {:op, op} = FormChecks.repair(session, "submit-no-form", node.id)

      assert session.tree |> apply_op!(op) |> Serializer.serialize() =~
               ~s(<input name={f[:email].name} /><button type="submit">Go</button></.form>)
    end

    # THE EDITOR KNOWS BOTH CANDIDATES, so it takes the one the button is sitting under rather than
    # handing the author to the assistant — which from their seat is a Fix button that only changes
    # panels. An author who meant the other form has a drag and an undo.
    test "Fix moves it into the form it sits under when there is more than one" do
      session =
        session(
          ~s(<div><.form :let={f} id="a-form" as={:a} for={assigns[:a_form]}><input name={f[:x].name} /><input name={f[:y].name} /></.form><.form :let={g} id="b-form" as={:b} for={assigns[:b_form]}></.form><button type="submit">Go</button></div>)
        )

      assert {:op, op} =
               FormChecks.repair(session, "submit-no-form", node_with(session, "button").id)

      assert op["parent_id"] == session |> forms() |> List.last() |> Map.fetch!(:id)
    end

    test "and takes the first one below it when the button is above them all" do
      session =
        session(
          ~s(<div><button type="submit">Go</button><.form :let={f} id="a-form" as={:a} for={assigns[:a_form]}></.form><.form :let={g} id="b-form" as={:b} for={assigns[:b_form]}></.form></div>)
        )

      assert {:op, op} =
               FormChecks.repair(session, "submit-no-form", node_with(session, "button").id)

      assert op["parent_id"] == session |> forms() |> List.first() |> Map.fetch!(:id)
    end

    test "Fix says there is nowhere to put it when the page has no form at all" do
      session = session(~s(<div><button type="submit">Go</button></div>))

      assert {:say, sentence} =
               FormChecks.repair(session, "submit-no-form", node_with(session, "button").id)

      assert sentence =~ "no form on this page"
    end
  end

  # A kit button whose `type` is an atom: the Inspector writes the author's pick as `type={:submit}`.
  @atom_button %{
    name: "acme-atom-button",
    attrs: [
      %{
        "name" => "type",
        "type" => "atom",
        "opts" => %{"default" => "button", "values" => ~w(button submit)}
      }
    ],
    slots: [%{"name" => "inner_block"}],
    template: ~S|<button type={@type}>{render_slot(@inner_block)}</button>|
  }

  describe "a button's type, however it is written" do
    test "a submit input in capitals is the form's Send button, not a field" do
      for input <- [~s(<input type="Submit" value="Send" />), ~s(<input type=" SUBMIT " />)] do
        source = String.replace(@healthy, ~s(<button type="submit">Send</button>), input)

        assert findings(source, record(["contact_submit"])) == [], input
      end
    end

    test "and outside a form it is a stray button, not a stray field" do
      assert rules(~s(<div><input type="Submit" value="Send" /></div>)) == ["submit-no-form"]
    end

    test "a button that computes its type may send the form, so no second Send is asked for", %{
      kit: kit
    } do
      for button <- [
            ~S(<button type={assigns[:kind]}>Go</button>),
            kit_button(~S( type={assigns[:t]}))
          ] do
        refute "form-no-submit" in kit_rules(phoenix_form("q", deep(button)), kit), button
      end
    end

    test "a literal written as an expression sends the form", %{kit: kit} do
      kit = [@atom_button | kit]

      atom_button =
        &~s(<.component component_name="acme-atom-button" site="Global" type={#{&1}}>Go</.component>)

      refute "form-no-submit" in kit_rules(phoenix_form("q", atom_button.(":submit")), kit)
      assert "form-no-submit" in kit_rules(phoenix_form("q", atom_button.(":button")), kit)

      refute "form-no-submit" in kit_rules(
               phoenix_form("q", ~S(<button type={"submit"}>Go</button>)),
               kit
             )
    end
  end

  defp kit_session(source, kit) do
    {:ok, tree} = Tree.parse(source)
    %{tree: tree, section: "page", components: kit}
  end

  defp kit_findings(%{tree: tree} = session), do: FormChecks.findings(tree, %{}, session)

  defp kit_findings(source, kit), do: source |> kit_session(kit) |> kit_findings()

  defp with_id(session, id),
    do: session.tree |> Tree.walk() |> Enum.find(&(Node.attr_text(&1, "id") == id))

  defp kit_rules(source, kit), do: source |> kit_findings(kit) |> Enum.map(& &1.rule)

  defp phoenix_form(seed, inner),
    do:
      ~s(<.form :let={f} id="#{seed}-form" as={:#{seed}} for={assigns[:#{seed}_form]} ) <>
        ~s(phx-change="#{seed}_validate" phx-submit="#{seed}_submit">) <>
        ~s(<input name={f[:email].name} />) <> inner <> "</.form>"

  defp wrapper_form(component, inner, seed \\ "k"),
    do:
      ~s(<.component component_name="#{component}" site="Global" :let={f} id="#{seed}-form" ) <>
        ~s(as={:#{seed}} for={assigns[:#{seed}_form]} phx-change="#{seed}_validate" ) <>
        ~s(phx-submit="#{seed}_submit"><input name={f[:email].name} />) <>
        inner <> "</.component>"

  # A card, a two-column grid, a column: the button three levels under the form.
  defp deep(inner),
    do:
      ~s(<.component component_name="chelekom-card" site="Global" padding="large">) <>
        ~s(<div class="grid grid-cols-2 gap-4"><div class="col-span-1">) <>
        inner <> "</div></div></.component>"

  defp kit_button(attrs, text \\ "Send"),
    do:
      ~s(<.component component_name="chelekom-button" site="Global"#{attrs}>#{text}</.component>)

  describe "a Send button at any depth, read from the real kit" do
    test "a kit button inside a card inside a grid sends a Phoenix form", %{kit: kit} do
      assert "form-no-submit" in kit_rules(phoenix_form("q", deep("<p>No button</p>")), kit)
      refute "form-no-submit" in kit_rules(phoenix_form("q", deep(kit_button(""))), kit)
    end

    test "and the kit's own form wrapper, and the simple form that calls it", %{kit: kit} do
      for wrapper <- ~w(chelekom-form-wrapper chelekom-simple-form) do
        assert "form-no-submit" in kit_rules(wrapper_form(wrapper, deep("")), kit), wrapper

        refute "form-no-submit" in kit_rules(wrapper_form(wrapper, deep(kit_button(""))), kit),
               wrapper
      end
    end

    test "deeper still: a card inside a card", %{kit: kit} do
      source = phoenix_form("q", deep(deep(deep(kit_button("")))))

      refute "form-no-submit" in kit_rules(source, kit)
    end

    test "a kit button saying type=button deep inside does not send it", %{kit: kit} do
      for attrs <- [~s( type="button"), ~s( type="reset")] do
        assert "form-no-submit" in kit_rules(phoenix_form("q", deep(kit_button(attrs))), kit),
               attrs
      end
    end

    test "a kit button given a link attribute still sends it", %{kit: kit} do
      source = phoenix_form("q", deep(kit_button(~s( navigate="/pricing"))))

      refute "form-no-submit" in kit_rules(source, kit)
    end

    test "a renamed copy of the kit button sends it the same way", %{kit: kit} do
      renamed = ~s(<.component component_name="my-kit-button" site="Global">Send</.component>)

      refute "form-no-submit" in kit_rules(phoenix_form("q", deep(renamed)), kit)
    end

    test "the kit's input button is not a Send button", %{kit: kit} do
      input = ~s(<.component component_name="chelekom-input-button" site="Global" value="Go" />)

      assert "form-no-submit" in kit_rules(phoenix_form("q", deep(input)), kit)
    end

    test "the CMS's own button sends by default and not when it says button", %{kit: kit} do
      refute "form-no-submit" in kit_rules(
               phoenix_form("q", deep("<.button>Send</.button>")),
               kit
             )

      assert "form-no-submit" in kit_rules(
               phoenix_form("q", deep(~s(<.button type="button">Open</.button>))),
               kit
             )
    end

    test "two forms are judged one at a time", %{kit: kit} do
      session =
        kit_session(
          ~s(<div>) <>
            phoenix_form("contact", deep(kit_button(""))) <>
            phoenix_form("signup", deep(kit_button(~s( type="button"), "Open"))) <> ~s(</div>),
          kit
        )

      assert [finding] =
               session |> kit_findings() |> Enum.filter(&(&1.rule == "form-no-submit"))

      assert finding.node_id == with_id(session, "signup-form").id
    end

    test "the Fix gives a wrapper with no button the styled Send, and the rule clears", %{
      kit: kit
    } do
      source = wrapper_form("chelekom-form-wrapper", deep(""))
      {:ok, tree} = Tree.parse(source)
      session = %{tree: tree, section: "page", components: kit}

      form =
        tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "chelekom-form-wrapper"))

      assert {:op, %{"template" => template} = op} =
               FormChecks.repair(session, "form-no-submit", form.id)

      assert template == FormPlacement.send_button()
      assert template == Elements.get("el-submit").template

      refute "form-no-submit" in (tree
                                  |> apply_op!(op)
                                  |> Serializer.serialize()
                                  |> kit_rules(kit))
    end
  end

  describe "a form that sends to another address" do
    @elsewhere ~s( action="https://pay.example.com/checkout" method="post" csrf_token={false} phx-trigger-action={assigns[:contact_send]})

    defp elsewhere(source),
      do:
        String.replace(source, ~s( phx-submit="), @elsewhere <> ~s( phx-submit="), global: false)

    test "has somewhere to go, deep fields and all, so no note is raised", %{kit: kit} do
      source = phoenix_form("contact", deep(kit_button("")))

      assert "form-no-destination" in kit_rules(source, kit)
      refute "form-no-destination" in kit_rules(elsewhere(source), kit)

      [form] = source |> elsewhere() |> kit_session(kit) |> then(&[with_id(&1, "contact-form")])
      assert FormChecks.receiver(form, %{}) == :action
    end

    test "the duplicate-name Fix renumbers its trigger with it", %{kit: kit} do
      source =
        ~s(<div>) <>
          elsewhere(phoenix_form("contact", "")) <>
          elsewhere(phoenix_form("contact", "")) <> ~s(</div>)

      session = kit_session(source, kit)
      [_first, second] = session.tree |> Tree.walk() |> Enum.filter(&(&1.tag == ".form"))

      {:ops, ops} = FormChecks.repair(session, "form-duplicate-seed", second.id)
      fixed = session.tree |> apply_ops!(ops) |> Tree.get(second.id)

      assert PageForms.param_name(fixed) == "contact_2"
      assert PageForms.trigger_assign(fixed) == :contact_2_send
      assert PageForms.address(fixed) == "https://pay.example.com/checkout"
    end
  end

  describe "a form that works as they type" do
    defp typed(source, marker \\ " data-sends-as-typed"),
      do: String.replace(source, ~s( phx-submit="), marker <> ~s( phx-submit="), global: false)

    test "raises no form-no-submit, deep in a core form or a kit wrapper", %{kit: kit} do
      for source <- [
            phoenix_form("q", deep("<p>Type to search</p>")),
            wrapper_form("chelekom-form-wrapper", deep("<p>Type to search</p>"))
          ] do
        assert "form-no-submit" in kit_rules(source, kit), source
        refute "form-no-submit" in kit_rules(typed(source), kit), source
      end
    end

    test "a form that lost its Send offers both ways out, each one clearing it", %{kit: kit} do
      source =
        ~s(<div>) <>
          phoenix_form("contact", deep("<p>No button</p>")) <>
          wrapper_form("chelekom-form-wrapper", deep(kit_button("")), "news") <> ~s(</div>)

      session = kit_session(source, kit)
      form = with_id(session, "contact-form")

      assert [finding] =
               session |> kit_findings() |> Enum.filter(&(&1.rule == "form-no-submit"))

      assert finding.node_id == form.id

      assert finding.fixes == [
               %{fix: "send", label: "Add a Send button"},
               %{fix: "typing", label: "Make it work as they type"}
             ]

      assert {:ops, ops} = FormChecks.repair(session, "form-no-submit", form.id, "typing")
      as_typed = apply_ops!(session.tree, ops)

      assert as_typed |> Tree.get(form.id) |> PageForms.as_typed?()
      assert Node.attr_text(Tree.get(as_typed, form.id), "phx-submit") == "contact_submit"

      refute "form-no-submit" in (as_typed |> Serializer.serialize() |> kit_rules(kit))

      assert FormChecks.repair(session, "form-no-submit", form.id, "send") ==
               FormChecks.repair(session, "form-no-submit", form.id)
    end

    test "a form that cannot carry the choice offers only the Send button, and refuses as they type",
         %{kit: kit} do
      source =
        ~s(<div>) <>
          phoenix_form("contact", deep("<p>No button</p>")) <>
          wrapper_form("chelekom-simple-form", deep("<p>No button</p>"), "lead") <>
          wrapper_form("chelekom-form-wrapper", deep("<p>No button</p>"), "news") <> ~s(</div>)

      session = kit_session(source, kit)
      layout = %{session | section: "layout"}

      fixes = fn session, id ->
        [finding] =
          session
          |> kit_findings()
          |> Enum.filter(&(&1.rule == "form-no-submit" and &1.node_id == with_id(session, id).id))

        Enum.map(finding.fixes, & &1.fix)
      end

      assert fixes.(session, "contact-form") == ~w(send typing)
      assert fixes.(session, "news-form") == ~w(send typing)
      assert fixes.(session, "lead-form") == ~w(send)
      assert fixes.(layout, "contact-form") == ~w(send)

      for {session, id} <- [{session, "lead-form"}, {layout, "contact-form"}] do
        assert {:say, "This form cannot work as they type."} =
                 FormChecks.repair(session, "form-no-submit", with_id(session, id).id, "typing")
      end
    end

    test "a form that is not a page's own offers only the Send button" do
      assert %{fixes: [%{fix: "send"}]} =
               one(~s(<form id="raw"><input name="q" /></form>), "form-no-submit")
    end
  end

  describe "a button outside every form, read from the real kit" do
    test "a hero button and the CMS's own button raise nothing", %{kit: kit} do
      source =
        ~s(<section class="hero"><h1>Build faster</h1>) <>
          kit_button("", "Start free") <>
          ~s(<.button>Learn more</.button>) <>
          ~s(<.component component_name="my-kit-button" site="Global">Pricing</.component>) <>
          ~s(</section>)

      assert kit_rules(source, kit) == []
    end

    test "a dialog's own buttons raise nothing either", %{kit: kit} do
      source =
        ~s(<div role="dialog">) <>
          kit_button(~s( type="button"), "Close") <>
          ~s(<.button type="button">Cancel</.button><button type="button">x</button></div>)

      assert kit_rules(source, kit) == []
    end

    test "a button that says it submits still warns", %{kit: kit} do
      for button <- [
            kit_button(~s( type="submit")),
            ~s(<.button type="submit">Send</.button>),
            ~s(<.component component_name="my-kit-button" site="Global" type="submit">Send</.component>),
            ~s(<input type="image" src="/send.png" />)
          ] do
        assert kit_rules(~s(<section>#{button}</section>), kit) == ["submit-no-form"], button
      end
    end

    test "a button inside a card inside a form is not outside it", %{kit: kit} do
      button = deep(kit_button(~s( type="submit")))

      assert kit_rules(~s(<section>#{button}</section>), kit) == ["submit-no-form"]
      refute "submit-no-form" in kit_rules(phoenix_form("q", button), kit)
    end
  end

  # Fields as a real page places them: in a column of a grid in a card, three levels under the form,
  # beside the Send button. A kit form here holds `for={%{}}` as the palette seeds it, so no page
  # assign marks it as a form: its markup does.
  describe "fields and a Send button deep in a card, read from the real kit" do
    defp kit_form(component, inner, seed),
      do:
        ~s(<.component component_name="#{component}" site="Global" :let={f} id="#{seed}-form" ) <>
          ~s(for={%{}}>) <> inner <> "</.component>"

    defp deep_fields(var),
      do:
        deep(
          ~s(<.component component_name="chelekom-text-field" site="Global" field={#{var}[:name]} label="Name" />) <>
            ~s(<input name={#{var}[:phone].name} value={#{var}[:phone].value} />) <>
            kit_button("")
        )

    test "belong to the form around the card, whatever kind of form it is", %{kit: kit} do
      for form <- ~w(chelekom-form-wrapper chelekom-simple-form acme-wrapper acme-simple) do
        raised = kit_rules(kit_form(form, deep_fields("f"), "k"), kit)

        for rule <- ~w(field-no-form field-no-key form-no-submit submit-no-form) do
          refute rule in raised, "#{rule} inside #{form}"
        end
      end

      refute "field-no-form" in kit_rules(phoenix_form("q", deep_fields("f")), kit)
      refute "form-no-submit" in kit_rules(phoenix_form("q", deep_fields("f")), kit)

      stranded = kit_findings(~s(<section>) <> deep_fields("f") <> ~s(</section>), kit)
      assert stranded |> Enum.filter(&(&1.rule == "field-no-form")) |> length() == 2
    end

    test "two forms on one page are judged apart, fields and Send buttons alike", %{kit: kit} do
      contact = phoenix_form("contact", deep_fields("f"))

      signup =
        kit_form(
          "acme-simple",
          deep(~s(<input name={f[:name].name} /><.button type="button">Preview</.button>)),
          "signup"
        )

      session = kit_session(~s(<div>) <> contact <> signup <> ~s(</div>), kit)
      findings = kit_findings(session)

      assert [no_send] = Enum.filter(findings, &(&1.rule == "form-no-submit"))
      assert no_send.node_id == with_id(session, "signup-form").id

      for rule <- ~w(field-no-form field-duplicate-key form-in-form submit-no-form) do
        refute Enum.any?(findings, &(&1.rule == rule)), rule
      end
    end

    test "a form in another form's card is a form inside a form, either way round", %{kit: kit} do
      kit_in_phoenix =
        kit_session(
          phoenix_form("outer", deep(kit_form("acme-simple", deep(kit_button("")), "inner"))),
          kit
        )

      phoenix_in_kit =
        kit_session(
          kit_form("acme-simple", deep(phoenix_form("inner", deep(kit_button("")))), "outer"),
          kit
        )

      for session <- [kit_in_phoenix, phoenix_in_kit] do
        assert [finding] = session |> kit_findings() |> Enum.filter(&(&1.rule == "form-in-form"))
        assert finding.node_id == with_id(session, "inner-form").id
      end
    end
  end

  describe "field-name-shadow" do
    @shadowed ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name="email" value={f[:phone].value} /><button type="submit">Send</button></.form>)

    test "names the value the form will really send" do
      finding = one(@shadowed, "field-name-shadow", record(["q_submit"]))

      assert finding.severity == :warning
      assert finding.message == "This field's name overrides its binding"

      assert finding.detail ==
               "What the visitor types arrives under email, which nothing on this page is checking."
    end

    test "is not raised when the name is bound rather than literal" do
      refute "field-name-shadow" in rules(@healthy, record(["contact_submit"]))
    end

    test "Fix removes the literal name" do
      session = session(@shadowed)

      assert FormChecks.repair(session, "field-name-shadow", node_with(session, "input").id) ==
               {:op,
                %{
                  "kind" => "delete_attr",
                  "node_id" => node_with(session, "input").id,
                  "name" => "name"
                }}
    end
  end

  describe "what repair refuses" do
    test "a node that is no longer in the tree" do
      assert FormChecks.repair(session(@healthy), "field-no-form", "nzzzzzzzz") == :none
    end

    test "a node id of nothing at all" do
      assert FormChecks.repair(session(@healthy), "field-no-form", nil) == :none
    end

    test "a rule this module does not answer for" do
      session = session(@healthy)

      assert FormChecks.repair(session, "img-alt", node_with(session, ".form").id) == :none
    end
  end

  # THE FIX AND THE INSERT FUNNEL HAVE TO AGREE. A palette card is seeded `name=""` `value=""` so it
  # renders standing alone, and a kit derives both with `assign_new/3`, which fills only an ABSENT
  # key. When these were two copies of one rule the funnel learned to drop the blank pair and the Fix
  # did not, so pressing Fix produced a field that renders and submits nothing.
  describe "the field-no-key Fix on a card that carries the seeded blank pair" do
    @kit %{
      name: "kit-text-field",
      template: ~s(<input name={@name} value={@value} />),
      attrs: [
        %{"name" => "name", "type" => "any", "opts" => %{}},
        %{"name" => "value", "type" => "any", "opts" => %{}},
        %{
          "name" => "bind",
          "type" => "struct",
          "struct_name" => "Phoenix.HTML.FormField",
          "opts" => %{}
        }
      ],
      slots: [],
      helpers: []
    }

    @seeded ~s(<.form :let={f} id="c-form" as={:c} for={assigns[:c_form]}>) <>
              ~s(<.component component_name="kit-text-field" site="Global" name="" value="" />) <>
              ~s(</.form>)

    defp seeded_session do
      {:ok, tree} = Tree.parse(@seeded)
      %{tree: tree, section: "page", components: [@kit]}
    end

    defp field_node(session),
      do: session.tree |> Tree.walk() |> Enum.find(&(&1.tag == ".component"))

    test "writes the binding on the attribute the kit declared" do
      session = seeded_session()
      node = field_node(session)

      assert {:ops, ops} = FormChecks.repair(session, "field-no-key", node.id)
      assert Enum.any?(ops, &(&1["kind"] == "set_attr" and &1["name"] == "bind"))
    end

    test "and takes the blank pair the binding supersedes away with it" do
      session = seeded_session()
      node = field_node(session)

      {:ops, ops} = FormChecks.repair(session, "field-no-key", node.id)
      dropped = for %{"kind" => "delete_attr", "name" => name} <- ops, do: name

      assert "name" in dropped
      assert "value" in dropped
    end
  end

  # Fields and Send buttons three levels down, card > grid > column, in a core `<.form>` and in a kit
  # wrapper that lends its form through `:let`.
  describe "forms built deep inside a card" do
    @deep_core ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div class="col"><input type="email" name={f[:email].name} value={f[:email].value} /></div><div class="col"><.component component_name="kit-text-field" site="Global" bind={f[:name]} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>)

    @deep_kit ~s(<.component component_name="kit-form" site="Global" :let={g} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div class="col"><input type="email" name={g[:address].name} value={g[:address].value} /></div><div class="col"><button type="submit">Join</button></div></div></div></.component>)

    @both @deep_core <> @deep_kit

    test "raise nothing, in a core form and in a kit wrapper" do
      assert findings(@both, record(["contact-k7m2q-submit", "news-p3xa6-submit"])) == []
    end

    test "each form without its deep Send button is asked for one, and only that form" do
      for {buttonless, other, id} <- [
            {String.replace(@deep_core, ~s(<button type="submit">Send</button>), ""), @deep_kit,
             "contact-form"},
            {String.replace(@deep_kit, ~s(<button type="submit">Join</button>), ""), @deep_core,
             "news-form"}
          ] do
        assert [finding] = deep_findings(buttonless <> other, "form-no-submit")
        assert finding.id == id
      end
    end

    test "a deep field outside both forms is still loose" do
      loose =
        ~s(<div class="card"><div class="grid"><div class="col"><input name="stray" /></div></div></div>)

      assert "field-no-form" in rules(
               @both <> loose,
               record(~w(contact-k7m2q-submit news-p3xa6-submit))
             )
    end

    test "a custom handler reaches only its own form, and an untouched default reaches neither" do
      record = %{
        events: [
          %{name: "enquiry-k7m2q-submit", code: "{:noreply, socket}"},
          %{
            name: "news-p3xa6-submit",
            code: LiveViewCompiler.form_handler_sample(:submit, "news-p3xa6-submit")
          }
        ]
      }

      assert [finding] = deep_findings(@both, "form-no-destination", record)
      assert finding.id == "news-form"
      assert finding.severity == :note
    end

    test "the default code a rename moved off a pre-token name still reaches nothing" do
      session = session(@both)
      [contact, _news] = session.tree |> Tree.walk() |> Enum.filter(&PageForms.form?/1)

      moved =
        PageForms.follow(
          [
            %{
              name: "contact_submit",
              code: LiveViewCompiler.form_handler_sample(:submit, "contact_submit")
            }
          ],
          ["contact-k7m2q-validate", "contact-k7m2q-submit"],
          %{"contact_submit" => "contact-k7m2q-submit"}
        )

      assert FormChecks.receiver(contact, %{events: moved}) == :none

      assert ["contact-form", "news-form"] ==
               @both
               |> deep_findings("form-no-destination", %{events: moved})
               |> Enum.map(& &1.id)
    end

    test "the Fix of each deep form names its own submit event" do
      session = session(@both)
      [contact, news] = session.tree |> Tree.walk() |> Enum.filter(&PageForms.form?/1)

      assert {:code, "contact-k7m2q-submit", _sentence} =
               FormChecks.repair(session, "form-no-destination", contact.id)

      assert {:code, "news-p3xa6-submit", _sentence} =
               FormChecks.repair(session, "form-no-destination", news.id)
    end

    test "two deep forms sharing a token: the later one is reported, and Fix retokens it alone" do
      shared = String.replace(@deep_kit, "p3xa6", "k7m2q")
      session = session(@deep_core <> shared)
      kit = kit_form(session.tree)

      assert [%{id: "news-form"}] = deep_findings(@deep_core <> shared, "form-duplicate-token")

      assert {:ops, ops} = FormChecks.repair(session, "form-duplicate-token", kit.id)
      assert [contact, news] = specs(apply_ops!(session.tree, ops))
      assert contact.submit == "contact-k7m2q-submit"
      assert news.submit =~ ~r/^news-[a-z2-7]{5}-submit$/
      refute Naming.token(news.submit) == "k7m2q"
      assert Naming.same_form?(news.change, news.submit)
    end

    test "a form placed in another form's card is reported as inside it" do
      inner =
        ~s(<.form :let={h} id="quote-form" as={:quote} for={assigns[:quote_form]} phx-change="quote-aaaa2-validate" phx-submit="quote-aaaa2-submit"><button type="submit">Ask</button></.form>)

      source =
        String.replace(
          @deep_core,
          ~s(<div class="col"><button),
          ~s(<div class="col">#{inner}<button)
        )

      assert [finding] = deep_findings(source, "form-in-form")
      assert finding.id == "quote-form"
    end

    defp kit_form(tree),
      do: tree |> Tree.walk() |> Enum.find(&(Node.attr_text(&1, "id") == "news-form"))

    # The findings for `rule`, each with the `id` attribute of the node it was raised on.
    defp deep_findings(
           source,
           rule,
           record \\ record(~w(contact-k7m2q-submit news-p3xa6-submit quote-aaaa2-submit))
         ) do
      session = session(source)

      session.tree
      |> FormChecks.findings(record, session)
      |> Enum.filter(&(&1.rule == rule))
      |> Enum.map(&Map.put(&1, :id, Node.attr_text(Tree.get(session.tree, &1.node_id), "id")))
    end
  end
end
