# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.PageFormsTest do
  @moduledoc """
  A page's forms are whatever its own markup says they are, and every way of getting that wrong is
  quiet.

  Read one field short and the visitor's answer is dropped on submit with the page reporting success.
  Read one field too many and a form validates a key nothing renders, so it can never become valid.
  Give two forms one name and each one's typing appears in the other. None of it raises, and none of
  it shows up in a browser until somebody sends a real message.

  So the tests here pin the boundaries rather than the happy path alone: where one form's fields
  stop, what counts as a binding when the kit invented its own attribute name, and what a broken
  document answers.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageForm.Rules

  @moduletag :unit

  @seeds ~w(contact newsletter quote feedback signup)

  defp contact_form do
    """
    <.form
      :let={f}
      id="contact-form"
      as={:contact}
      for={assigns[:contact_form]}
      phx-change="contact_validate"
      phx-submit="contact_submit"
      data-success="Thanks, we will be in touch."
    >
      <.input field={f[:name]} type="text" label="Your name" required minlength="2" />
      <.input field={f[:email]} type="email" label="Email" required minlength="5" data-format="email" />
      <.input field={f[:message]} type="textarea" required minlength="10" maxlength="2000" />
      <button type="submit">Send</button>
    </.form>
    """
  end

  defp one_form(seed) do
    """
    <.form
      :let={f}
      id="#{seed}-form"
      as={:#{seed}}
      for={assigns[:#{seed}_form]}
      phx-change="#{seed}_validate"
      phx-submit="#{seed}_submit"
    >
      <.input field={f[:#{seed}_bound]} required />
      <input name="#{seed}_written" />
    </.form>
    """
  end

  defp keys(spec), do: Enum.map(spec.fields, & &1.key)

  defp rules(spec, key), do: spec.fields |> Enum.find(&(&1.key == key)) |> Map.get(:rules)

  defp node!(source, tag) do
    {:ok, tree} = Tree.parse(source)
    tree |> Tree.walk() |> Enum.find(&(&1.tag == tag))
  end

  describe "declared/1 over one form" do
    test "reads the five derived names, the success message and every field in order" do
      assert [spec] = PageForms.declared(contact_form())

      assert spec.assign == :contact_form
      assert spec.as == "contact"
      assert spec.id == "contact-form"
      assert spec.change == "contact_validate"
      assert spec.submit == "contact_submit"
      assert spec.success == "Thanks, we will be in touch."
      assert keys(spec) == [:name, :email, :message]
    end

    test "a submit button is not a field" do
      assert [spec] = PageForms.declared(contact_form())
      refute Enum.any?(spec.fields, &(&1.key == :submit))
      assert length(spec.fields) == 3
    end

    test "the id and the success message fall back rather than being left blank" do
      assert [spec] =
               PageForms.declared(
                 ~s(<.form :let={f} as={:quote} for={assigns[:quote_form]}></.form>)
               )

      assert spec.id == "quote-form"
      assert spec.success != nil
      assert spec.success != ""
    end

    test "a form keeping its state in a plain assign rather than in assigns[] declares nothing" do
      assert PageForms.declared(~s(<.form :let={f} for={@contact_form} as={:contact}></.form>)) ==
               []
    end

    test "a form with no param name declares nothing, because its fields would post at the top level" do
      assert PageForms.declared(~s(<.form :let={f} for={assigns[:contact_form]}></.form>)) == []
    end

    test "an unfilled form is still a form" do
      assert [spec] =
               PageForms.declared(
                 ~s(<.form :let={f} id="empty-form" as={:empty} for={assigns[:empty_form]}></.form>)
               )

      assert spec.fields == []
      assert spec.assign == :empty_form
    end
  end

  describe "declared/1 over five forms on one page" do
    setup do
      {:ok, specs: @seeds |> Enum.map_join("\n", &one_form/1) |> PageForms.declared()}
    end

    test "every form is read, in document order", %{specs: specs} do
      assert Enum.map(specs, & &1.as) == @seeds
    end

    test "no derived name is shared by two forms", %{specs: specs} do
      for read <- [& &1.assign, & &1.as, & &1.id, & &1.change, & &1.submit] do
        assert specs |> Enum.map(read) |> Enum.uniq() |> length() == 5
      end
    end

    test "a form owns its own fields and nobody else's", %{specs: specs} do
      for spec <- specs do
        assert keys(spec) == [:"#{spec.as}_bound", :"#{spec.as}_written"]
      end
    end
  end

  describe "which form a field belongs to" do
    test "a field outside every form belongs to none of them" do
      source = """
      <input name="stray" />
      <.form :let={f} as={:contact} for={assigns[:contact_form]}>
        <input name="inside" />
      </.form>
      <.input field={f[:ghost]} />
      """

      assert [spec] = PageForms.declared(source)
      assert keys(spec) == [:inside]
    end

    test "a nested form keeps its own fields, and the outer one does not adopt them" do
      source = """
      <.form :let={f} as={:outer} for={assigns[:outer_form]}>
        <input name="mine" />
        <.form :let={g} as={:inner} for={assigns[:inner_form]}>
          <input name="theirs" />
        </.form>
      </.form>
      """

      assert [outer, inner] = PageForms.declared(source)
      assert keys(outer) == [:mine]
      assert keys(inner) == [:theirs]
    end

    test "one key bound twice is one field" do
      source = """
      <.form :let={f} as={:contact} for={assigns[:contact_form]}>
        <label for={f[:email].id}>Email</label>
        <input name={f[:email].name} value={f[:email].value} />
      </.form>
      """

      assert [spec] = PageForms.declared(source)
      assert keys(spec) == [:email]
    end
  end

  describe "what counts as a binding" do
    test "the kit's own attribute name is read, whatever it is" do
      source = """
      <.form :let={f} as={:contact} for={assigns[:contact_form]}>
        <.text_field bind={f[:email]} />
        <.slider hold={f[:size]} />
      </.form>
      """

      assert [spec] = PageForms.declared(source)
      assert keys(spec) == [:email, :size]
    end

    test "a value read off a binding is the same fact as the binding" do
      source = """
      <.form :let={f} as={:contact} for={assigns[:contact_form]}>
        <.text_field value={f[:email].value} />
      </.form>
      """

      assert [spec] = PageForms.declared(source)
      assert keys(spec) == [:email]
    end

    test "an inner :let variable binds to its own thing, not to the form" do
      source = """
      <.form :let={f} as={:contact} for={assigns[:contact_form]}>
        <.fieldset :let={g}>
          <.text_field bind={f[:email]} />
          <.text_field bind={g[:row]} />
        </.fieldset>
      </.form>
      """

      assert [spec] = PageForms.declared(source)
      assert keys(spec) == [:email]
    end

    test "a form binding no :let variable has only its hand-written controls" do
      source = """
      <.form as={:contact} for={assigns[:contact_form]}>
        <.text_field bind={f[:email]} />
        <input name="written" />
      </.form>
      """

      assert [spec] = PageForms.declared(source)
      assert keys(spec) == [:written]
    end

    test "name is read off HTML's own controls and off nothing else" do
      source = """
      <.form :let={f} as={:contact} for={assigns[:contact_form]}>
        <.icon name="hero-user" />
        <input type="submit" name="go" />
        <select name="country"><option value="ir">Iran</option></select>
        <textarea name="note"></textarea>
      </.form>
      """

      assert [spec] = PageForms.declared(source)
      assert keys(spec) == [:country, :note]
    end
  end

  describe "rules lifted off the markup" do
    setup do
      source = """
      <.form :let={f} as={:r} for={assigns[:r_form]}>
        <input
          name="qty"
          data-cast="integer"
          required
          minlength="2"
          maxlength="9"
          min="1"
          max="10"
          pattern="[0-9]+"
          data-format="url"
          data-confirms="other"
        />
        <input name="loose" />
        <input name="broken" pattern="[" />
        <input name="fuzzy" minlength="a lot" />
      </.form>
      """

      {:ok, [spec]} = PageForms.read(source)
      {:ok, spec: spec}
    end

    test "every HTML constraint becomes one rule, in a stable order", %{spec: spec} do
      assert rules(spec, :qty) == [
               :required,
               {:min_length, 2},
               {:max_length, 9},
               {:min, 1},
               {:max, 10},
               {:pattern, "[0-9]+"},
               {:format, :url},
               {:confirms, "other"}
             ]
    end

    test "data-cast decides the type, and a field without one is text", %{spec: spec} do
      assert Enum.find(spec.fields, &(&1.key == :qty)).type == :integer
      assert Enum.find(spec.fields, &(&1.key == :loose)).type == :string
    end

    test "a field declaring no constraint carries no rule", %{spec: spec} do
      assert rules(spec, :loose) == []
    end

    test "a pattern that will not compile contributes no rule", %{spec: spec} do
      assert rules(spec, :broken) == []
    end

    test "a length that is not a number contributes no rule", %{spec: spec} do
      assert rules(spec, :fuzzy) == []
    end

    test "an email format is read as an atom the runtime can match on" do
      source =
        ~s(<.form :let={f} as={:c} for={assigns[:c_form]}><input name="e" data-format="email" /></.form>)

      assert [spec] = PageForms.declared(source)
      assert rules(spec, :e) == [{:format, :email}]
    end

    # HTML'S `min` AND `max` ARE FLOATING POINT on `type="number"`. Lifted with `Integer.parse/1`
    # they were dropped without a trace — no log, no audit finding, nothing in the editor — so the
    # browser refused 0.1 and the server took it.
    test "a fractional min or max is a rule, not a silence" do
      source =
        ~s(<.form :let={f} as={:c} for={assigns[:c_form]}><input name="amount" min="0.5" max="99.99" data-cast="float" /></.form>)

      assert [spec] = PageForms.declared(source)
      assert rules(spec, :amount) == [{:min, 0.5}, {:max, 99.99}]
    end

    test "and the server then refuses what the browser refuses" do
      source =
        ~s(<.form :let={f} as={:c} for={assigns[:c_form]}><input name="amount" min="0.5" data-cast="float" /></.form>)

      assert [spec] = PageForms.declared(source)

      refute Rules.changeset(spec, %{"amount" => "0.1"}).valid?
      assert Rules.changeset(spec, %{"amount" => "0.5"}).valid?
    end

    test "a whole min stays whole, so the message reads 10 rather than 10.0" do
      source =
        ~s(<.form :let={f} as={:c} for={assigns[:c_form]}><input name="qty" min="10" data-cast="integer" /></.form>)

      assert [spec] = PageForms.declared(source)
      assert rules(spec, :qty) == [{:min, 10}]
    end

    # A LENGTH IS A COUNT OF CHARACTERS, so half of one is not a bound the browser enforces either.
    test "a fractional minlength is still no rule at all" do
      source =
        ~s(<.form :let={f} as={:c} for={assigns[:c_form]}><input name="word" minlength="2.5" /></.form>)

      assert [spec] = PageForms.declared(source)
      assert rules(spec, :word) == []
    end
  end

  # THE COMPILED PAGE WANTS ATOMS AND THE EDITOR MUST NOT MINT ANY. `names/2` is asked on every drop
  # and on every render of the audit rail, from a `name=` an author is halfway through typing, and
  # the only consumer compares text.
  describe "names/2, the editor's half of the same question" do
    test "answers the same field list as fields/2, in text" do
      source =
        ~s(<.form :let={f} id="c-form" as={:c} for={assigns[:c_form]}><input name={f[:email].name} /><input name="phone" /></.form>)

      {:ok, tree} = Tree.parse(source)
      form = tree |> Tree.walk() |> Enum.find(&PageForms.form?/1)

      assert PageForms.names(tree, form) == ["email", "phone"]
      assert tree |> PageForms.fields(form) |> Enum.map(& &1.key) == [:email, :phone]
    end

    test "interns nothing for a name nobody has ever written" do
      unseen = "n#{System.unique_integer([:positive])}"

      source =
        ~s(<.form :let={f} id="c-form" as={:c} for={assigns[:c_form]}><input name="#{unseen}" /></.form>)

      {:ok, tree} = Tree.parse(source)
      form = tree |> Tree.walk() |> Enum.find(&PageForms.form?/1)

      assert PageForms.names(tree, form) == [unseen]
      assert_raise ArgumentError, fn -> String.to_existing_atom(unseen) end
    end
  end

  describe "a document that cannot be read" do
    test "read/1 answers the parse error rather than raising" do
      assert {:error, error} = PageForms.read(~s(<.form :let={f} as={:c} for={assigns[:c_form]}>))
      assert error.line == 1
      assert is_binary(error.message)
    end

    test "declared/1 answers no forms, so one broken page never fails a compile" do
      assert PageForms.declared(~s(<.form :let={f} as={:c} for={assigns[:c_form]}>)) == []
      assert PageForms.declared("<div class=></div>") == []
    end

    test "an empty template and a missing one are both simply formless" do
      assert PageForms.declared("") == []
      assert PageForms.declared(nil) == []
    end

    test "an attribute expression that is not valid Elixir declares nothing" do
      assert PageForms.declared(~s(<.form :let={f} as={:c} for={assigns[:c}></.form>)) == []
    end
  end

  describe "field_key_from/2" do
    test "reads the key a binding names" do
      assert PageForms.field_key_from("f[:email]", :f) == :email
      assert PageForms.field_key_from(" f[:email] ", :f) == :email
    end

    test "reads through a field read off the binding" do
      assert PageForms.field_key_from("f[:email].value", :f) == :email
      assert PageForms.field_key_from("f[:email].name", :f) == :email
    end

    test "another variable is another form's business" do
      assert PageForms.field_key_from("g[:email]", :f) == nil
    end

    test "a form binding nothing binds no field" do
      assert PageForms.field_key_from("f[:email]", nil) == nil
    end

    test "anything that is not a key access is not a key" do
      assert PageForms.field_key_from("@email", :f) == nil
      assert PageForms.field_key_from("f[key]", :f) == nil
      assert PageForms.field_key_from(~s(f["email"]), :f) == nil
      assert PageForms.field_key_from("f[:email", :f) == nil
    end
  end

  # THE HALF `field_key_from/2` FORGETS. The key is the same fact for all three expressions, which
  # is right for "which form owns this field" and wrong for anything that has to RENDER one: the
  # canvas handed a kit's `name` assign the whole `%Phoenix.HTML.FormField{}` because `f[:email]`
  # and `f[:email].name` answered alike, and the node red-boxed with
  # `protocol Phoenix.HTML.Safe not implemented`.
  describe "field_access/2" do
    test "keeps what the expression reads off the field" do
      assert PageForms.field_access("f[:email]", :f) == {:email, []}
      assert PageForms.field_access("f[:email].name", :f) == {:email, [:name]}
      assert PageForms.field_access("f[:email].value", :f) == {:email, [:value]}
    end

    test "and keeps a longer path in the order it was written" do
      assert PageForms.field_access("f[:email].form.id", :f) == {:email, [:form, :id]}
    end

    test "agrees with field_key_from/2 about the key, which is why there is one parse" do
      for source <- ["f[:email]", "f[:email].name", "f[:email].value"] do
        {key, _path} = PageForms.field_access(source, :f)

        assert key == PageForms.field_key_from(source, :f)
      end
    end

    test "answers nothing for what is not a binding of this form" do
      assert PageForms.field_access("g[:email]", :f) == nil
      assert PageForms.field_access("f[:email]", nil) == nil
      assert PageForms.field_access("@email", :f) == nil
      assert PageForms.field_access("f[:email", :f) == nil
    end
  end

  # THE SAME QUESTION WITH NO FORM TO ASK IT ABOUT, which is what a field outside every form is. A
  # bound one reads a `:let` variable nothing binds and the page will not compile; a control that
  # names itself compiles and merely submits nothing. The audit tells the author which of the two
  # they have, so this has to tell them apart.
  describe "bound_var/1" do
    test "names the variable a field reads its key off" do
      assert ~s(<.input field={f[:email]} />) |> node!(".input") |> PageForms.bound_var() == :f

      assert ~s(<input name={g[:email].name} value={g[:email].value} />)
             |> node!("input")
             |> PageForms.bound_var() == :g
    end

    test "a control that names itself binds nothing" do
      assert ~s(<input name="email" value="" />) |> node!("input") |> PageForms.bound_var() == nil
    end

    # `assigns` is in scope in every template, so reading a key off it is not a binding waiting for a
    # `:let` — otherwise every form on the page would look like a stranded field.
    test "reading a page assign is not a binding" do
      assert ~s(<.form for={assigns[:contact_form]}></.form>)
             |> node!(".form")
             |> PageForms.bound_var() == nil
    end

    test "and neither is an assign or an unparseable expression" do
      for source <- [~s(<.input value={@email} />), ~s(<.input value={f[:email} />)] do
        assert source |> node!(".input") |> PageForms.bound_var() == nil
      end
    end
  end

  describe "reading one node" do
    test "source_assign/1 names the page assign, and form?/1 is the same question" do
      node = node!(~s(<.form for={assigns[:contact_form]}></.form>), ".form")

      assert PageForms.source_assign(node) == :contact_form
      assert PageForms.form?(node)
    end

    test "a node with no for is not a form" do
      node = node!(~s(<div class="wrap"></div>), "div")

      assert PageForms.source_assign(node) == nil
      refute PageForms.form?(node)
    end

    test "param_name/1 reads both the atom form and the string form" do
      assert ~s(<.form as={:contact}></.form>) |> node!(".form") |> PageForms.param_name() ==
               "contact"

      assert ~s(<.form as="contact"></.form>) |> node!(".form") |> PageForms.param_name() ==
               "contact"

      assert ~s(<.form as="  "></.form>) |> node!(".form") |> PageForms.param_name() == nil
      assert ~s(<.form></.form>) |> node!(".form") |> PageForms.param_name() == nil
    end

    test "let_var/1 reads the variable a form binds" do
      assert ~s(<.form :let={f}></.form>) |> node!(".form") |> PageForms.let_var() == :f
      assert ~s(<.form :let={form}></.form>) |> node!(".form") |> PageForms.let_var() == :form
      assert ~s(<.form></.form>) |> node!(".form") |> PageForms.let_var() == nil
    end

    test "bound_key/2 ignores a literal name, which field_key/2 falls back to" do
      node = node!(~s(<input name="email" />), "input")

      assert PageForms.bound_key(node, :f) == nil
      assert PageForms.field_key(node, :f) == :email
    end
  end

  describe "answered?/2" do
    test "an entry named exactly after the event answers it" do
      assert PageForms.answered?([%{name: "contact_submit"}], "contact_submit")
      assert PageForms.answered?([%{"name" => "contact-k7m2q-submit"}], "contact-k7m2q-submit")
      assert PageForms.answered?(["contact_submit"], "contact_submit")
    end

    test "an entry with the same token and kind answers it after its form was renamed" do
      assert PageForms.answered?([%{name: "contact-k7m2q-submit"}], "enquiry-k7m2q-submit")
    end

    test "the same token with the other kind, or another token, does not" do
      refute PageForms.answered?([%{name: "contact-k7m2q-validate"}], "enquiry-k7m2q-submit")
      refute PageForms.answered?([%{name: "contact-p3xa6-submit"}], "contact-k7m2q-submit")
      refute PageForms.answered?([%{name: "contact_submit"}], "contact-k7m2q-submit")
    end

    test "no event is answered by anything, not even a blank entry" do
      refute PageForms.answered?([%{name: ""}, %{}], nil)
      refute PageForms.answered?([%{name: ""}], "")
    end
  end

  describe "follow/2" do
    @current ["enquiry-k7m2q-validate", "enquiry-k7m2q-submit", "news-p3xa6-submit"]

    defp names(entries), do: Enum.map(entries, & &1.name)

    test "a stored entry under a renamed form's old event takes the current one" do
      entries = [%{name: "contact-k7m2q-submit", code: ":ok", signature: "sig"}]

      assert PageForms.follow(entries, @current) == [
               %{name: "enquiry-k7m2q-submit", code: ":ok", signature: "sig"}
             ]
    end

    test "each kind follows its own event" do
      entries = [%{name: "contact-k7m2q-validate"}, %{name: "contact-k7m2q-submit"}]

      assert names(PageForms.follow(entries, @current)) == @current |> Enum.take(2)
    end

    test "an exact match, an untagged name and another token are left alone" do
      entries = [
        %{name: "news-p3xa6-submit"},
        %{name: "contact_submit"},
        %{name: "contact-zzzzz-submit"},
        %{name: "save"}
      ]

      assert PageForms.follow(entries, @current) == entries
    end

    test "never gives two entries one name" do
      entries = [%{name: "enquiry-k7m2q-submit"}, %{name: "contact-k7m2q-submit"}]

      assert names(PageForms.follow(entries, @current)) ==
               ["enquiry-k7m2q-submit", "contact-k7m2q-submit"]

      stale = [%{name: "contact-k7m2q-submit"}, %{name: "old-k7m2q-submit"}]

      assert names(PageForms.follow(stale, @current)) ==
               ["enquiry-k7m2q-submit", "old-k7m2q-submit"]
    end

    test "reads string-keyed entries, as the code window holds them" do
      assert PageForms.follow([%{"name" => "contact-k7m2q-submit", "code" => ":ok"}], @current) ==
               [%{"name" => "enquiry-k7m2q-submit", "code" => ":ok"}]
    end
  end

  # A pre-token form renamed by a code author: `retagged` says which untagged names took its token.
  describe "follow/3" do
    @current ["enquiry-k7m2q-validate", "enquiry-k7m2q-submit"]
    @retagged %{
      "contact_validate" => "contact-k7m2q-validate",
      "contact_submit" => "contact-k7m2q-submit"
    }

    test "an untagged entry named in retagged takes its form's current event" do
      entries = [%{name: "contact_submit", code: ":ok"}, %{"name" => "contact_validate"}]

      assert PageForms.follow(entries, @current, @retagged) == [
               %{name: "enquiry-k7m2q-submit", code: ":ok"},
               %{"name" => "enquiry-k7m2q-validate"}
             ]
    end

    test "an untagged entry's code that quotes its own name takes the new name with it" do
      code =
        ~s|IO.inspect(params, label: "contact_submit")\nsubmit(socket, "contact_submit", params)|

      assert PageForms.follow([%{name: "contact_submit", code: code}], @current, @retagged) == [
               %{
                 name: "enquiry-k7m2q-submit",
                 code:
                   ~s|IO.inspect(params, label: "enquiry-k7m2q-submit")\nsubmit(socket, "enquiry-k7m2q-submit", params)|
               }
             ]

      assert [%{"code" => ~s|"enquiry-k7m2q-validate" <> "contact_submit"|}] =
               PageForms.follow(
                 [
                   %{
                     "name" => "contact_validate",
                     "code" => ~s|"contact_validate" <> "contact_submit"|
                   }
                 ],
                 @current,
                 @retagged
               )
    end

    test "a tagged entry's code is left as written, since its token still reaches the form" do
      code = ~s|submit(socket, "contact-k7m2q-submit", params)|

      assert PageForms.follow([%{name: "contact-k7m2q-submit", code: code}], @current) ==
               [%{name: "enquiry-k7m2q-submit", code: code}]
    end

    test "stays while a form still answers the untagged name, as after an Undo" do
      entries = [%{name: "contact_submit"}]

      assert PageForms.follow(entries, ["contact_validate", "contact_submit"], @retagged) ==
               entries

      assert PageForms.follow(entries, ["contact_submit", "enquiry-k7m2q-submit"], @retagged) ==
               entries
    end

    test "stays when no form carries the token any more, and never takes a claimed name" do
      assert PageForms.follow([%{name: "contact_submit"}], ["news-p3xa6-submit"], @retagged) ==
               [%{name: "contact_submit"}]

      claimed = [%{name: "enquiry-k7m2q-submit"}, %{name: "contact_submit"}]
      assert PageForms.follow(claimed, @current, @retagged) == claimed
    end
  end

  # Two forms on one page, a core `<.form>` and a kit wrapper that lends its form through `:let`,
  # each with its fields and its Send button three levels down: card > grid > column.
  describe "forms whose fields sit deep inside a card" do
    defp deep_page(contact_seed \\ "contact") do
      """
      <section>
        <.form :let={f} id="#{contact_seed}-form" as={:#{contact_seed}} for={assigns[:#{contact_seed}_form]} phx-change="#{contact_seed}-k7m2q-validate" phx-submit="#{contact_seed}-k7m2q-submit">
          <div class="card">
            <div class="grid grid-cols-2">
              <div class="col"><.input field={f[:name]} type="text" required minlength="2" /></div>
              <div class="col"><input type="email" name={f[:email].name} value={f[:email].value} required /></div>
              <div class="col"><select name={f[:topic].name}><option value="a">A</option></select></div>
              <div class="col"><button type="submit">Send</button></div>
            </div>
          </div>
        </.form>
        <.component component_name="kit-form" site="Global" :let={g} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">
          <div class="card">
            <div class="grid">
              <div class="col">
                <.component component_name="kit-text-field" site="Global" bind={g[:address]} />
                <.input field={g[:frequency]} type="text" />
              </div>
              <div class="col"><button type="submit">Join</button></div>
            </div>
          </div>
        </.component>
      </section>
      """
    end

    test "each form reads the fields under its own card and no one else's" do
      assert [contact, news] = PageForms.declared(deep_page())

      assert keys(contact) == [:name, :email, :topic]
      assert keys(news) == [:address, :frequency]
      assert rules(contact, :name) == [:required, {:min_length, 2}]
    end

    test "the kit wrapper is a form with its own tagged events" do
      assert [contact, news] = PageForms.declared(deep_page())

      assert {contact.change, contact.submit} ==
               {"contact-k7m2q-validate", "contact-k7m2q-submit"}

      assert {news.assign, news.as} == {:news_form, "news"}
      assert {news.change, news.submit} == {"news-p3xa6-validate", "news-p3xa6-submit"}
    end

    test "a handler follows its own form after a rename, and never the other one" do
      specs = PageForms.declared(deep_page("enquiry"))
      current = Enum.flat_map(specs, &[&1.change, &1.submit])

      entries = [
        %{name: "contact-k7m2q-submit", code: ":contact"},
        %{name: "news-p3xa6-validate", code: ":news"}
      ]

      assert PageForms.follow(entries, current) == [
               %{name: "enquiry-k7m2q-submit", code: ":contact"},
               %{name: "news-p3xa6-validate", code: ":news"}
             ]

      assert PageForms.answered?(entries, "enquiry-k7m2q-submit")
      refute PageForms.answered?(entries, "news-p3xa6-submit")
    end

    test "handler_forms/2 lists both forms, each with its own two events" do
      {:ok, tree} = Tree.parse(deep_page())

      assert [
               %{name: "Contact", handlers: contact},
               %{name: "News", handlers: news}
             ] = PageForms.handler_forms(tree, [])

      assert contact == [
               %{kind: :validate, event: "contact-k7m2q-validate", custom?: false},
               %{kind: :submit, event: "contact-k7m2q-submit", custom?: false}
             ]

      assert Enum.map(news, & &1.event) == ["news-p3xa6-validate", "news-p3xa6-submit"]
    end

    test "an entry marks its own form's event Custom, by name or by token, and no other" do
      {:ok, tree} = Tree.parse(deep_page("enquiry"))
      entries = [%{"name" => "contact-k7m2q-submit", "code" => ":ok"}]

      [contact, news] = PageForms.handler_forms(tree, entries)

      assert Enum.map(contact.handlers, & &1.custom?) == [false, true]
      assert Enum.map(news.handlers, & &1.custom?) == [false, false]
    end

    test "handler_for/3 finds the row naming an event, with its form's node" do
      {:ok, tree} = Tree.parse(deep_page())
      [_contact, news] = PageForms.handler_forms(tree, [])

      assert %{kind: :submit, event: "news-p3xa6-submit", node_id: node_id} =
               PageForms.handler_for(tree, [], "news-p3xa6-submit")

      assert node_id == news.node_id
      assert PageForms.handler_for(tree, [], "gone-aaaaa-submit") == nil
    end
  end

  describe "handlers/2" do
    test "gives no row to an event the form does not name" do
      {:ok, tree} =
        Tree.parse(
          ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-submit="q_submit"><input name={f[:x].name} /></.form>)
        )

      [form] = tree |> Tree.walk() |> Enum.filter(&PageForms.form?/1)

      assert PageForms.handlers(form, ["q_submit"]) == [
               %{kind: :submit, event: "q_submit", custom?: true}
             ]
    end

    test "a form with no param name is not listed, since it has no name to read" do
      {:ok, tree} =
        Tree.parse(
          ~s(<.form for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"></.form>)
        )

      assert PageForms.handler_forms(tree, []) == []
    end
  end
end
