# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.PageForms.NamingTest do
  @moduledoc """
  Two forms on one page have to be two forms, and the failure when they are not is silent: the second
  form's inputs post under the first one's param name, the first one's assign answers both
  `phx-change` handlers, and the page looks right the whole time.

  So the tests here pin the two halves that make the collision impossible. Every name a form carries
  comes from one seed, and the seed a page already uses is read back out of the page by parsing it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @moduletag :unit

  defp tree!(source) do
    {:ok, tree} = Tree.parse(source)
    tree
  end

  defp form(seed), do: ~s(<.form :let={f} #{attrs_source(seed)}><input name="email" /></.form>)

  defp attrs_source(seed) do
    seed
    |> Naming.attrs()
    |> Enum.map_join(" ", fn
      {name, {:string, value}} -> ~s(#{name}="#{value}")
      {name, {:expr, value}} -> ~s(#{name}={#{value}})
    end)
  end

  defp forms(tree), do: tree |> Tree.walk() |> Enum.filter(&(&1.tag == ".form"))

  defp tagged(seed, token),
    do: ~s(<.form :let={f} #{attrs_source(seed, token)}><input name="email" /></.form>)

  defp attrs_source(seed, token) do
    seed
    |> Naming.attrs(token)
    |> Enum.map_join(" ", fn
      {name, {:string, value}} -> ~s(#{name}="#{value}")
      {name, {:expr, value}} -> ~s(#{name}={#{value}})
    end)
  end

  defp events(node), do: {Node.attr_text(node, "phx-change"), Node.attr_text(node, "phx-submit")}

  defp seeds(tree), do: tree |> Naming.seeds() |> Enum.map(fn {_id, seed} -> seed end)

  describe "seed/1" do
    test "a label becomes a lowercase, underscore-joined seed" do
      assert Naming.seed("Contact us") == "contact_us"
      assert Naming.seed("Newsletter") == "newsletter"
    end

    test "punctuation collapses and accents fold away" do
      assert Naming.seed("Contáct — Üs!!") == "contact_us"
      assert Naming.seed("  Quote   /  Request  ") == "quote_request"
      assert Naming.seed("Señor Renée's café") == "senor_renee_s_cafe"
    end

    test "a seed never starts with a digit, because :2024_signup is not an atom literal" do
      assert Naming.seed("2024 Signup") == "signup"
      assert Naming.seed("42") == "form"
    end

    test "a label with nothing usable in it falls back" do
      assert Naming.seed("") == "form"
      assert Naming.seed(nil) == "form"
      assert Naming.seed("   ") == "form"
      assert Naming.seed("!!! ???") == "form"
      assert Naming.seed("تماس با ما") == "form"
    end

    test "a very long label is cut short rather than becoming the DOM id from hell" do
      seed = Naming.seed(String.duplicate("long label ", 20))

      assert String.length(seed) <= 40
      refute String.ends_with?(seed, "_")
    end

    test "every seed is a legal atom literal, assign name and DOM id" do
      for label <- ["Contact us", "Contáct — Üs!!", "2024 Signup", "", "تماس با ما", "a-b-c"] do
        seed = Naming.seed(label)

        assert seed =~ ~r/^[a-z][a-z0-9_]*$/
        assert {:ok, atom} = Code.string_to_quoted(":" <> seed)
        assert is_atom(atom)
      end
    end

    test "minting is idempotent, so a seed can be re-minted on every write" do
      for label <- ["Contact us", "Contáct — Üs!!", "2024 Signup", "", "contact_2"] do
        seed = Naming.seed(label)

        assert Naming.seed(seed) == seed
      end
    end
  end

  describe "attrs/1 and derived/0" do
    test "one seed gives all five names" do
      assert Naming.attrs("contact") == [
               {"id", {:string, "contact-form"}},
               {"as", {:expr, ":contact"}},
               {"for", {:expr, "assigns[:contact_form]"}},
               {"phx-change", {:string, "contact_validate"}},
               {"phx-submit", {:string, "contact_submit"}}
             ]
    end

    test "the same seed always gives the same five names" do
      assert Naming.attrs("contact") == Naming.attrs("contact")
      assert Naming.attrs("Contact us") == Naming.attrs("contact_us")
    end

    test "a raw label is minted on the way out, so no derived name is ever unparseable" do
      assert Naming.attrs("2024 Sign up!") == Naming.attrs("sign_up")
    end

    test "derived/0 names exactly the attributes attrs/1 writes" do
      assert Naming.derived() == Enum.map(Naming.attrs("contact"), fn {name, _value} -> name end)
    end
  end

  describe "label/1" do
    test "the unnamed family reads as numbered forms" do
      assert Naming.label("form") == "Form 1"
      assert Naming.label("form_2") == "Form 2"
      assert Naming.label("form_12") == "Form 12"
    end

    test "any other seed is capitalised, with spaces" do
      assert Naming.label("contact") == "Contact"
      assert Naming.label("contact_2") == "Contact 2"
      assert Naming.label("my_contact_form") == "My contact form"
    end

    test "reads a label the way a seed is minted from it" do
      assert Naming.label("Contáct Us") == "Contact us"
      assert Naming.label(nil) == "Form 1"
    end
  end

  describe "seeds/1" do
    test "reads the seeds a page already carries, by parsing them" do
      tree = tree!(form("contact") <> form("newsletter"))

      assert seeds(tree) == ["contact", "newsletter"]
    end

    test "an as written as a string is read too" do
      tree = tree!(~s(<.form for={assigns[:x_form]} as="contact"></.form>))

      assert seeds(tree) == ["contact"]
    end

    test "a page with no form has no seeds" do
      tree = tree!(~s(<div class="p-4"><p>Hello</p></div>))

      assert seeds(tree) == []
    end
  end

  describe "unique/2" do
    test "a free seed is handed back untouched" do
      assert Naming.unique(tree!(form("contact")), "newsletter") == "newsletter"
    end

    test "a taken seed is numbered" do
      assert Naming.unique(tree!(form("contact")), "contact") == "contact_2"
    end

    test "numbering continues past the highest in the family" do
      assert Naming.unique(tree!(form("contact") <> form("contact_2")), "contact") == "contact_3"
    end

    test "a gap left by a deleted form is filled" do
      assert Naming.unique(tree!(form("contact") <> form("contact_3")), "contact") == "contact_2"
    end

    test "a numbered base counts as one of the family rather than starting a new one" do
      assert Naming.unique(tree!(form("contact") <> form("contact_2")), "contact_2") ==
               "contact_3"
    end

    test "the base is minted first, so an author's label is safe to pass straight in" do
      assert Naming.unique(tree!(form("contact_us")), "Contact us") == "contact_us_2"
    end

    test "an empty page mints the label itself" do
      assert Naming.unique(Tree.new(), "Contact us") == "contact_us"
    end

    test "a hand-written seed counts as the name it would be minted as" do
      tree = tree!(~s(<.form for={assigns[:x_form]} as="My form"></.form>))

      assert Naming.unique(tree, "my form") == "my_form_2"
    end
  end

  describe "dedupe/1" do
    test "the second of two identical forms is renumbered in all five attributes" do
      tree = Naming.dedupe(tree!(form("contact") <> form("contact")))

      assert seeds(tree) == ["contact", "contact_2"]

      [_first, second] = forms(tree)

      assert Node.attr(second, "id") == {:string, "contact_2-form"}
      assert Node.attr(second, "as") == {:expr, ":contact_2"}
      assert Node.attr(second, "for") == {:expr, "assigns[:contact_2_form]"}

      # RENUMBERED IS RENAMED, so the copy leaves the untagged names behind and gets a token.
      assert Node.attr_text(second, "phx-change") =~ ~r/^contact_2-[a-z2-7]{5}-validate$/
      assert Node.attr_text(second, "phx-submit") =~ ~r/^contact_2-[a-z2-7]{5}-submit$/

      assert Naming.same_form?(
               Node.attr_text(second, "phx-change"),
               Node.attr_text(second, "phx-submit")
             )
    end

    test "the first form keeps every name it had" do
      tree = Naming.dedupe(tree!(form("contact") <> form("contact")))

      [first, _second] = forms(tree)

      for {name, value} <- Naming.attrs("contact") do
        assert Node.attr(first, name) == value
      end
    end

    test "three of the same form become contact, contact_2 and contact_3" do
      tree = Naming.dedupe(tree!(form("contact") <> form("contact") <> form("contact")))

      assert seeds(tree) == ["contact", "contact_2", "contact_3"]
    end

    test "renumbering leaves the rest of the node alone" do
      tree = Naming.dedupe(tree!(form("contact") <> form("contact")))

      [_first, second] = forms(tree)

      assert Node.attr(second, ":let") == {:expr, "f"}
      assert length(second.children) == 1
    end

    test "a page with one form is answered with the tree it was given" do
      tree = tree!(form("contact"))

      assert Naming.dedupe(tree) == tree
    end

    test "a page with no form is answered with the tree it was given" do
      tree = tree!(~s(<div><p>Hello</p></div>))

      assert Naming.dedupe(tree) == tree
    end

    test "two forms that already differ are left alone" do
      tree = tree!(form("contact") <> form("newsletter"))

      assert Naming.dedupe(tree) == tree
    end

    test "a hand-written seed is renumbered into a name that is legal on its own" do
      source = ~s(<.form for={assigns[:x_form]} as="My form"></.form>)
      tree = Naming.dedupe(tree!(source <> source))

      [_first, second] = forms(tree)

      assert Node.attr(second, "as") == {:expr, ":my_form_2"}
      assert Node.attr(second, "for") == {:expr, "assigns[:my_form_2_form]"}
    end

    test "a duplicate lands beside the family it belongs to, not on a free lower number" do
      tree = Naming.dedupe(tree!(form("contact") <> form("contact_2") <> form("contact_2")))

      assert seeds(tree) == ["contact", "contact_2", "contact_3"]
    end
  end

  describe "attrs/2 and the event names" do
    test "a token goes inside both event names and nowhere else" do
      assert Naming.attrs("contact", "k7m2q") == [
               {"id", {:string, "contact-form"}},
               {"as", {:expr, ":contact"}},
               {"for", {:expr, "assigns[:contact_form]"}},
               {"phx-change", {:string, "contact-k7m2q-validate"}},
               {"phx-submit", {:string, "contact-k7m2q-submit"}}
             ]
    end

    test "a minted token gives a tagged submit name, and nil gives the untagged five" do
      {"phx-submit", {:string, submit}} =
        "Contact" |> Naming.attrs(Naming.mint_token(Tree.new())) |> List.last()

      assert submit =~ ~r/^contact-[a-z2-7]{5}-submit$/
      assert Naming.attrs("contact", nil) == Naming.attrs("contact")
    end

    test "event/3 writes both spellings" do
      assert Naming.event("contact", "k7m2q", :submit) == "contact-k7m2q-submit"
      assert Naming.event("contact", nil, :validate) == "contact_validate"
    end

    test "event_key/1 reads the token and kind of a tagged name, and nothing else" do
      assert Naming.event_key("contact-k7m2q-submit") == {"k7m2q", :submit}
      assert Naming.event_key("contact_2-k7m2q-validate") == {"k7m2q", :validate}

      for other <- [
            "contact_submit",
            "contact-k7m21-submit",
            "contact-K7M2Q-submit",
            "contact-k7m2-submit",
            "contact-k7m2q-save",
            "-k7m2q-submit",
            nil,
            :atom
          ] do
        assert Naming.event_key(other) == nil, "#{inspect(other)} is not a tagged event name"
      end
    end

    test "token/1 is the token of a tagged name, or nil" do
      assert Naming.token("contact-k7m2q-submit") == "k7m2q"
      assert Naming.token("contact_submit") == nil
    end

    test "same_event?/2 matches token and kind across seeds, and never two untagged names" do
      assert Naming.same_event?("contact-k7m2q-submit", "enquiry-k7m2q-submit")
      refute Naming.same_event?("contact-k7m2q-submit", "contact-k7m2q-validate")
      refute Naming.same_event?("contact-k7m2q-submit", "contact-p3xa6-submit")
      refute Naming.same_event?("contact_submit", "contact_submit")
    end

    test "same_form?/2 matches the token whatever the kind" do
      assert Naming.same_form?("contact-k7m2q-submit", "enquiry-k7m2q-validate")
      refute Naming.same_form?("contact-k7m2q-submit", "contact-p3xa6-submit")
      refute Naming.same_form?("contact_submit", "contact_validate")
    end

    test "no seed contains -, so no seed can pass for a token" do
      for label <- ["a-b-c", "Contact-us", "x-k7m2q", "--", "contact-k7m2q-submit"] do
        seed = Naming.seed(label)

        refute seed =~ "-"
        assert Naming.event_key(Naming.event(seed, nil, :submit)) == nil
        assert Naming.event_key(Naming.event(seed, "k7m2q", :submit)) == {"k7m2q", :submit}
      end
    end

    test "mint_token/1 is five characters of the node-id alphabet" do
      tree = tree!(tagged("contact", "k7m2q"))

      for _round <- 1..50 do
        token = Naming.mint_token(tree)

        assert token =~ ~r/^[a-z2-7]{5}$/
        refute token == "k7m2q"
      end
    end

    test "form_token/1 reads the submit name first, then the change name" do
      [form] = forms(tree!(tagged("contact", "k7m2q")))

      assert Naming.form_token(form) == "k7m2q"

      [change_only] =
        forms(
          tree!(~s(<.form as={:c} for={assigns[:c_form]} phx-change="c-p3xa6-validate"></.form>))
        )

      assert Naming.form_token(change_only) == "p3xa6"
      assert Naming.form_token(hd(forms(tree!(form("contact"))))) == nil
    end
  end

  # A FORM THAT SENDS TO ANOTHER ADDRESS carries four more attributes, and one of them is named
  # after its seed: every writer of the five names keeps them together.
  describe "a form that sends to another address" do
    @elsewhere ~s( action="https://pay.example.com/checkout" method="post" csrf_token={false} phx-trigger-action={assigns[:contact_send]})

    defp sending(source),
      do: String.replace(source, "><input", @elsewhere <> "><input", global: false)

    defp deep_sending(seed),
      do:
        ~s(<div class="card"><div class="grid"><div class="col">) <>
          sending(tagged(seed, "k7m2q")) <> "</div></div></div>"

    test "a duplicate renumbered by dedupe/2 gets its own trigger and keeps the address" do
      tree = tree!(deep_sending("contact") <> deep_sending("contact"))
      [_first, second] = forms(tree)
      [first, copy] = tree |> Naming.dedupe([second.id]) |> forms()

      assert PageForms.trigger_assign(first) == :contact_send
      assert PageForms.trigger_assign(copy) == :contact_2_send
      assert PageForms.address(copy) == "https://pay.example.com/checkout"
      assert Node.attr_text(copy, "method") == "post"
      assert Node.attr_text(copy, "csrf_token") == "false"
    end

    test "names_for/3 adds the trigger under the new seed only to a form that sends elsewhere" do
      [plain] = forms(tree!(tagged("contact", "k7m2q")))
      [elsewhere] = forms(tree!(sending(tagged("contact", "k7m2q"))))

      assert Naming.names_for(plain, "Sales", "k7m2q") == Naming.attrs("Sales", "k7m2q")

      assert Naming.names_for(elsewhere, "Sales", "k7m2q") ==
               Naming.attrs("Sales", "k7m2q") ++
                 [{"phx-trigger-action", {:expr, "assigns[:sales_send]"}}]

      [stray] =
        "contact"
        |> tagged("k7m2q")
        |> sending()
        |> String.replace(~s( action="https://pay.example.com/checkout"), "")
        |> tree!()
        |> forms()

      assert Naming.names_for(stray, "Sales", "k7m2q") == Naming.attrs("Sales", "k7m2q")
    end
  end

  describe "retokened/2" do
    test "swaps the token in tagged names and keeps their seed" do
      [node] = forms(tree!(tagged("contact", "k7m2q")))

      assert Naming.retokened(node, "p3xa6") == [
               {"phx-change", {:string, "contact-p3xa6-validate"}},
               {"phx-submit", {:string, "contact-p3xa6-submit"}}
             ]
    end

    test "tags the untagged names of the form's own seed" do
      [node] = forms(tree!(form("contact")))

      assert Naming.retokened(node, "p3xa6") == [
               {"phx-change", {:string, "contact-p3xa6-validate"}},
               {"phx-submit", {:string, "contact-p3xa6-submit"}}
             ]
    end

    test "leaves out a name a developer chose" do
      [node] =
        forms(
          tree!(
            ~s(<.form as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="save_contact"></.form>)
          )
        )

      assert Naming.retokened(node, "p3xa6") == [
               {"phx-change", {:string, "contact-p3xa6-validate"}}
             ]
    end
  end

  describe "dedupe/2 and tokens" do
    test "each arrival gets its own token, and the incumbent keeps its own" do
      tree = tree!(tagged("contact", "k7m2q") <> tagged("contact", "k7m2q"))
      [first, second] = forms(tree)

      [kept, arrived] = tree |> Naming.dedupe([second.id]) |> forms()

      assert events(kept) == {"contact-k7m2q-validate", "contact-k7m2q-submit"}
      assert Node.attr_text(arrived, "phx-submit") =~ ~r/^contact_2-[a-z2-7]{5}-submit$/
      refute Naming.form_token(arrived) == "k7m2q"
      assert kept.id == first.id
    end

    test "a form arriving ABOVE the incumbent is still the one retokened" do
      tree = tree!(tagged("newsletter", "k7m2q") <> tagged("contact", "k7m2q"))
      [arrival, incumbent] = forms(tree)

      [arrived, kept] = tree |> Naming.dedupe([arrival.id]) |> forms()

      assert Naming.form_token(kept) == "k7m2q"
      assert kept.id == incumbent.id
      assert Node.attr_text(arrived, "phx-submit") =~ ~r/^newsletter-[a-z2-7]{5}-submit$/
      refute Naming.form_token(arrived) == "k7m2q"
    end

    test "an untagged arrival gets a token and keeps its other three names" do
      tree = tree!(form("contact"))
      [arrival] = forms(tree)

      [arrived] = tree |> Naming.dedupe([arrival.id]) |> forms()

      assert Node.attr_text(arrived, "phx-change") =~ ~r/^contact-[a-z2-7]{5}-validate$/
      assert Node.attr_text(arrived, "phx-submit") =~ ~r/^contact-[a-z2-7]{5}-submit$/

      assert Naming.same_form?(
               Node.attr_text(arrived, "phx-change"),
               Node.attr_text(arrived, "phx-submit")
             )

      for name <- ~w(id as for) do
        assert Node.attr(arrived, name) == Node.attr(arrival, name)
      end
    end

    test "two untagged arrivals get two different tokens" do
      tree = tree!(form("contact") <> form("newsletter"))
      ids = tree |> forms() |> Enum.map(& &1.id)

      tokens = tree |> Naming.dedupe(ids) |> forms() |> Enum.map(&Naming.form_token/1)

      assert [a, b] = tokens
      assert is_binary(a) and is_binary(b)
      refute a == b
    end

    test "an untagged arrival answering a name the page carried keeps its untagged names" do
      tree = tree!(form("contact"))
      [arrival] = forms(tree)

      carried = ~w(contact_validate contact_submit)

      assert Naming.dedupe(tree, [arrival.id], carried) == tree
    end

    test "a carried name does not spare an arrival whose seed another form holds" do
      tree = tree!(form("contact") <> form("contact"))
      [_incumbent, arrival] = forms(tree)

      [kept, arrived] =
        tree |> Naming.dedupe([arrival.id], ~w(contact_validate contact_submit)) |> forms()

      assert events(kept) == {"contact_validate", "contact_submit"}
      assert Node.attr_text(arrived, "phx-submit") =~ ~r/^contact_2-[a-z2-7]{5}-submit$/
    end

    test "an arrival carrying a token nobody else holds keeps it" do
      tree = tree!(form("contact") <> tagged("newsletter", "k7m2q"))
      [_incumbent, arrival] = forms(tree)

      assert Naming.dedupe(tree, [arrival.id]) == tree
    end

    test "an untagged incumbent is left untagged" do
      tree = tree!(form("contact") <> tagged("newsletter", "k7m2q"))
      [_incumbent, arrival] = forms(tree)

      [kept, _arrived] = tree |> Naming.dedupe([arrival.id]) |> forms()

      assert events(kept) == {"contact_validate", "contact_submit"}
    end

    test "a shared token is retokened with no arrivals, as put_tree has none" do
      tree = tree!(tagged("contact", "k7m2q") <> tagged("newsletter", "k7m2q"))

      [first, second] = tree |> Naming.dedupe() |> forms()

      assert events(first) == {"contact-k7m2q-validate", "contact-k7m2q-submit"}
      assert Node.attr_text(second, "phx-submit") =~ ~r/^newsletter-[a-z2-7]{5}-submit$/
      refute Naming.form_token(second) == "k7m2q"
      assert Naming.seeds(Naming.dedupe(tree)) |> Enum.map(&elem(&1, 1)) == ~w(contact newsletter)
    end

    test "a renumbered form with a token of its own keeps it" do
      tree = tree!(tagged("contact", "k7m2q") <> tagged("contact", "p3xa6"))

      [_first, second] = tree |> Naming.dedupe() |> forms()

      assert events(second) == {"contact_2-p3xa6-validate", "contact_2-p3xa6-submit"}
    end

    test "a kit wrapper arriving beside a deep core form is renamed and retokened like one" do
      core =
        ~s(<section><div class="card"><div class="grid"><div class="col">#{tagged("contact", "k7m2q")}</div></div></div></section>)

      kit =
        ~s(<div class="card"><div class="col"><.component component_name="kit-form" site="Global" :let={g} #{attrs_source("contact", "k7m2q")}><div class="grid"><input name={g[:email].name} /></div></.component></div></div>)

      tree = tree!(core <> kit)
      arrival = Enum.find(Tree.walk(tree), &(&1.tag == ".component"))

      [kept, arrived] =
        tree |> Naming.dedupe([arrival.id]) |> Tree.walk() |> Enum.filter(&PageForms.form?/1)

      assert kept.tag == ".form"
      assert events(kept) == {"contact-k7m2q-validate", "contact-k7m2q-submit"}
      assert arrived.id == arrival.id
      assert Node.attr(arrived, "as") == {:expr, ":contact_2"}
      assert Node.attr_text(arrived, "phx-submit") =~ ~r/^contact_2-[a-z2-7]{5}-submit$/
      refute Naming.form_token(arrived) == "k7m2q"
    end

    test "untagged forms with different seeds and no arrivals are left alone" do
      tree = tree!(form("contact") <> form("newsletter"))

      assert Naming.dedupe(tree) == tree
    end
  end

  describe "field_key/2" do
    test "a label becomes a key" do
      assert Naming.field_key("Email address", []) == "email_address"
    end

    test "an unusable label falls back to field rather than to form" do
      assert Naming.field_key("", []) == "field"
      assert Naming.field_key(nil, []) == "field"
    end

    test "a key already bound in this form is numbered" do
      assert Naming.field_key("Email", [:email]) == "email_2"
      assert Naming.field_key("Email", ["email", "email_2"]) == "email_3"
    end

    test "keys taken as atoms and as binaries count the same" do
      assert Naming.field_key("Email", [:email, "email_2"]) == "email_3"
    end
  end

  # `as` IS AN ORDINARY HTML ATTRIBUTE. Reading it as "this is a form" made a font preload into one:
  # `dedupe/1` runs on every insert, duplicate and wrap AND on every save, draft restore and history
  # revert, so what it wrote is what got stored.
  describe "a node that merely carries an `as` attribute" do
    @preload ~s(<div><link rel="preload" as="font" href="/a.woff2" /><link rel="preload" as="font" href="/b.woff2" /></div>)

    defp preloads do
      {:ok, tree} = Tree.parse(@preload)
      tree
    end

    test "is not counted as a form" do
      assert Naming.seeds(preloads()) == []
    end

    test "and dedupe leaves it exactly as it was" do
      before = Serializer.serialize(preloads())

      assert preloads() |> Naming.dedupe() |> Serializer.serialize() == before
    end

    test "so no phantom form is declared for it" do
      source = preloads() |> Naming.dedupe() |> Serializer.serialize()

      assert PageForms.declared(source) == []
    end

    test "while a real form beside it still counts" do
      {:ok, tree} =
        Tree.parse(
          ~s(<div><link rel="preload" as="font" href="/a.woff2" />) <>
            ~s(<.form :let={f} id="c-form" as={:c} for={assigns[:c_form]}></.form></div>)
        )

      assert [{_id, "c"}] = Naming.seeds(tree)
    end
  end
end
