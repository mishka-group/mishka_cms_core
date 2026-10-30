# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.FieldsRoleTest do
  @moduledoc """
  What part of a form a component plays: declared by the kit when the kit says, inferred from its
  markup when it does not, and left at `:none` for an error component, which has no structural
  signal.

  The inference fails OPEN — get it wrong and the editor writes a binding onto a component that
  cannot take one, and `KeyError :name` lands inside LiveView's diff with nothing in the editor to
  notice. So every branch is pinned here against a hand-built entry whose one distinguishing signal
  is named in the test, and against the real Chelekom rows and renamed copies of them.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Fields
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Test.Factory

  @moduletag :unit

  @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

  setup_all do
    by_name =
      @kits_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path |> File.read!() |> Jason.decode!() |> Map.get("components", [])
      end)
      |> Map.new(&{&1["name"], &1})

    {:ok, by_name: by_name}
  end

  defp entry(component) do
    %{
      name: component["name"],
      global?: true,
      attrs: component["attrs"] || [],
      slots: component["slots"] || [],
      helpers: component["helpers"] || [],
      template: component["template"] || ""
    }
  end

  defp form_field_entry(attr_name, struct_name \\ "Phoenix.HTML.FormField") do
    %{
      name: "acme-thing",
      attrs: [
        %{"name" => attr_name, "type" => "struct", "struct_name" => struct_name},
        %{"name" => "input_name", "type" => "string"},
        %{"name" => "input_value", "type" => "string"}
      ],
      template: ~S(<input name={@input_name} value={@input_value} />)
    }
  end

  describe "a declaration beats inference" do
    test "a component whose attrs say field is whatever its kit declared" do
      declared = Map.put(form_field_entry("field"), :form, %{"role" => "submit"})

      assert Fields.role(form_field_entry("field")) == :field
      assert Fields.role(declared) == :submit
      refute Fields.field?(declared)
    end

    test "a declaration arriving with string keys is read the same way" do
      entry = Map.put(form_field_entry("field"), "form", %{"role" => "wrapper"})

      assert Fields.role(entry) == :wrapper
      assert Fields.wrapper?(entry)
    end

    test "a role the kit invented is not a role, so inference answers instead" do
      entry = Map.put(form_field_entry("field"), :form, %{"role" => "input"})

      assert Fields.role(entry) == :field
    end
  end

  defp struct_only_entry(struct_name) do
    %{
      name: "acme-thing",
      attrs: [%{"name" => "bind", "type" => "struct", "struct_name" => struct_name}],
      template: ~S(<div class="wrap">bound</div>)
    }
  end

  describe "inferring a field from a form-field struct" do
    test "the attribute may be called anything at all" do
      entry = form_field_entry("bind")

      assert Fields.role(entry) == :field
      assert Fields.binding_attr(entry) == "bind"
    end

    # ONLY PHOENIX'S OWN STRUCT CAN BE INFERRED, because only Phoenix's own struct is what the
    # editor can write: what goes into the attribute is `f[:email]`, and `to_form/2` produces
    # nothing else. Matching the last dot-segment recognised `Acme.Forms.FormField` too and then
    # wrote a Phoenix struct into it — which the kit's `%Acme.Forms.FormField{} = field` clause head
    # cannot match, so the call fell through to the rendering clause and raised `KeyError :name` on
    # the published page. A kit with its own struct declares `extra.form` instead.
    test "another vendor's FormField is not inferred, because the binding would not match it" do
      entry = struct_only_entry("Acme.Forms.FormField")

      assert Fields.role(entry) == :none
      assert Fields.binding_attr(entry) == nil
    end

    test "and it becomes a field the moment its kit says so, with the binding it named" do
      entry =
        "Acme.Forms.FormField"
        |> struct_only_entry()
        |> Map.put(:form, %{"role" => "field", "field" => "bind"})

      assert Fields.role(entry) == :field
      assert Fields.binding_attr(entry) == "bind"
    end

    test "a fully qualified atom struct name is read the same way as the string" do
      entry = struct_only_entry(Phoenix.HTML.FormField)

      assert Fields.role(entry) == :field
      assert Fields.binding_attr(entry) == "bind"
    end

    test "a struct attribute that is not a FormField is not a field" do
      entry = struct_only_entry("Phoenix.HTML.Form")

      assert Fields.role(entry) == :none
      assert Fields.binding_attr(entry) == nil
    end

    # A BINDING NAMES AN ATTRIBUTE, AND A SLOT IS NOT ONE. Validating a declared key against attrs
    # AND slots reopened the failure `MishkaCmsCore.Builder.FormRole` exists to prevent from the
    # other side: `inner_block` really is declared, so the key survived and the editor wrote
    # `inner_block={f[:email]}` — which is not an attribute the component accepts either.
    test "a binding that names a slot is dropped, not written" do
      entry =
        %{
          name: "acme-slotted",
          attrs: [%{"name" => "class", "type" => "string"}],
          slots: [%{"name" => "inner_block"}],
          template: "",
          form: %{"role" => "field", "field" => "inner_block"}
        }

      assert Fields.role(entry) == :field
      assert Fields.binding_attr(entry) == nil
    end
  end

  describe "inferring a wrapper from the component's own markup" do
    test "a template rendering a raw form element is a wrapper" do
      entry = %{
        name: "acme-form",
        attrs: [],
        template: ~S(<form action="/search"><input type="text" /></form>)
      }

      assert Fields.role(entry) == :wrapper
      assert Fields.wrapper?(entry)
    end

    test "a template calling Phoenix's form component is a wrapper" do
      entry = %{
        name: "acme-form",
        attrs: [%{"name" => "for", "type" => "any"}],
        template: ~S(<.form for={@for}><div class="p-2" /></.form>)
      }

      assert Fields.role(entry) == :wrapper
    end

    # The parser is the point. A `String.contains?(template, "<.form")` test called this a wrapper,
    # and every drop of it seeded `for={%{}}` onto a component with no form in it.
    test "a component that only mentions a form in a comment is not a wrapper" do
      entry = %{
        name: "acme-hint",
        attrs: [],
        template: ~S(<!-- put a <.form> around this --><div class="hint">Hint</div>)
      }

      assert String.contains?(entry.template, "<.form")
      assert Fields.role(entry) == :none
      refute Fields.wrapper?(entry)
    end

    # `chelekom-simple-form` renders no form of its own: it forwards everything to
    # `chelekom-form-wrapper` through an `{assigns}` splat, so the only signal left is the promise.
    test "a required `for` is the component saying the form's data is its own to hand on" do
      entry = %{
        name: "acme-simple-form",
        attrs: [%{"name" => "for", "type" => "any", "opts" => %{"required" => true}}],
        template: ~S(<.component component_name="acme-form" {assigns} />)
      }

      assert Fields.role(entry) == :wrapper
    end

    test "an optional `for` on a label is an element id, not a form" do
      entry = %{
        name: "acme-label",
        attrs: [%{"name" => "for", "type" => "string"}],
        template: ~S(<label for={@for}>Name</label>)
      }

      assert Fields.role(entry) == :none
    end
  end

  # `structural?/1` used to read the raw template with two regexes — `name={@name}` beside a
  # `value=`/`checked=` binding — which is a hardcoded spelling of a kit's attribute names and, worse,
  # matches text that is not markup at all. The parse answers both, and answers them for a kit that
  # calls its attributes something else.
  describe "inferring a field from the control the component renders" do
    defp rendering(attrs, template),
      do: %{name: "acme-thing", attrs: attrs, template: template}

    @pair_attrs [%{"name" => "name", "type" => "any"}, %{"name" => "value", "type" => "any"}]

    test "a control bound to the component's own name and value is a field" do
      entry = rendering(@pair_attrs, ~S(<input type="text" name={@name} value={@value} />))

      assert Fields.structural?(entry)
      assert Fields.role(entry) == :field
    end

    test "the two attributes may be called anything at all, and pair_attrs names them" do
      entry =
        rendering(
          [
            %{"name" => "input_name", "type" => "any"},
            %{"name" => "input_value", "type" => "any"}
          ],
          ~S(<input name={@input_name} value={@input_value} />)
        )

      assert Fields.structural?(entry)
      assert Fields.pair_attrs(entry) == {"input_name", "input_value"}
    end

    test "a checkbox carrying `checked` rather than `value` is a field too" do
      entry =
        rendering(
          [%{"name" => "name", "type" => "any"}, %{"name" => "checked", "type" => "boolean"}],
          ~S(<input type="checkbox" name={@name} checked={@checked} />)
        )

      assert Fields.structural?(entry)
      assert Fields.pair_attrs(entry) == {"name", "checked"}
    end

    # THE REGEX SAID YES TO THIS. A third-party submit button declaring `name` and `value` matched
    # all four of its conditions, so the palette called it a field, the insert funnel wrapped it in
    # a form of its own, and its caption `value="Save"` was overwritten with a binding.
    test "a submit button is not a field, however it binds its name and value" do
      entry =
        rendering(
          @pair_attrs ++ [%{"name" => "class", "type" => "any"}],
          ~S(<input type="submit" name={@name} value={@value} class={@class} />)
        )

      refute Fields.structural?(entry)
      refute Fields.field?(entry)
      assert Fields.role(entry) == :submit
      assert Fields.pair_attrs(entry) == {nil, nil}
    end

    test "and neither is a reset button" do
      entry = rendering(@pair_attrs, ~S(<input type="reset" name={@name} value={@value} />))

      refute Fields.structural?(entry)
    end

    # A COMMENT IS NOT A CONTROL. The regex read the source as text, so a component that merely
    # quotes an input in a doc sample answered `structural? true`.
    test "a component that only quotes an input inside a comment is not a field" do
      entry =
        rendering(
          @pair_attrs,
          ~S(<!-- <input name={@name} value={@value} /> --><div class="hint">Hint</div>)
        )

      assert String.contains?(entry.template, ~S(name={@name}))
      refute Fields.structural?(entry)
      assert Fields.role(entry) == :none
    end

    test "an assign the component never declared is not one of its attributes" do
      entry = rendering([], ~S(<input name={@name} value={@value} />))

      refute Fields.structural?(entry)
    end

    test "a literal name is nothing the editor can bind to" do
      entry = rendering(@pair_attrs, ~S(<input name="q" value={@value} />))

      refute Fields.structural?(entry)
    end

    test "an unparseable template answers no rather than raising" do
      entry = rendering(@pair_attrs, ~S(<input name={@name} value={@value}))

      refute Fields.structural?(entry)
      assert Fields.role(entry) == :none
    end
  end

  describe "the role that is never inferred, and the one that now is" do
    test "a component that renders nothing but errors is still `:none`" do
      entry = %{
        name: "acme-error-message",
        attrs: [%{"name" => "errors", "type" => "list"}],
        template: ~S(<p :for={msg <- @errors} class="text-red-600">{msg}</p>)
      }

      assert Fields.role(entry) == :none
    end

    test "a component whose outer element is a submit input is `:submit`" do
      entry = %{
        name: "acme-submit-button",
        attrs: [%{"name" => "value", "type" => "string"}],
        template: ~S(<input type="submit" value={@value} />)
      }

      assert Fields.role(entry) == :submit
    end

    test "both roles are still reachable by declaration on markup that says nothing" do
      for role <- ~w(error submit) do
        entry =
          Map.put(%{name: "acme-thing", attrs: [], template: "<div />"}, :form, %{
            "role" => role
          })

        assert Fields.role(entry) == String.to_existing_atom(role)
      end
    end
  end

  defp type_attr(default, values),
    do: %{
      "name" => "type",
      "type" => "any",
      "opts" => %{"default" => default, "values" => values}
    }

  defp send_entry(template, attrs \\ []),
    do: %{name: "acme-button", attrs: attrs, template: template}

  describe "inferring a Send button from the outer element" do
    test "an outer button whose type attribute defaults to nothing is a Send button" do
      entry =
        send_entry(
          ~S|<button type={@type} class="btn"><span>{render_slot(@inner_block)}</span></button>|,
          [type_attr(nil, ["button", "submit", "reset", nil])]
        )

      assert Fields.role(entry) == :submit
    end

    test "an outer button with no type written at all is one too" do
      assert Fields.role(send_entry(~S(<button class="btn">Go</button>))) == :submit
    end

    test "an outer input typed submit or image is one" do
      for type <- ~w(submit image) do
        assert Fields.role(send_entry(~s(<input type="#{type}" />))) == :submit, type
      end
    end

    test "an outer input whose bound type can be submit is one" do
      entry = send_entry(~S(<input type={@type} />), [type_attr("text", ~w(text submit))])

      assert Fields.role(entry) == :submit
    end

    test "an outer input whose type can never submit is not" do
      entry = send_entry(~S(<input type={@type} />), [type_attr("button", ~w(button reset))])

      assert Fields.role(entry) == :none
      assert Fields.role(send_entry(~S(<input {@rest} />))) == :none
    end

    test "an outer button written as type button or reset is not" do
      for type <- ~w(button reset) do
        assert Fields.role(send_entry(~s(<button type="#{type}">Go</button>))) == :none, type
      end
    end

    test "a type the markup computes is not guessed" do
      entry = send_entry(~S(<button type={@type || "button"}>Go</button>), [type_attr(nil, [])])

      assert Fields.role(entry) == :none
    end

    test "a literal written as an expression is read as that literal" do
      assert Fields.role(send_entry(~S(<input type={"submit"} />))) == :submit
      assert Fields.role(send_entry(~S(<input type={:image} src="/go.png" />))) == :submit
      assert Fields.role(send_entry(~S(<button type={:button}>Go</button>))) == :none
    end

    test "buttons inside the markup never count" do
      entry =
        send_entry(
          ~S(<div class="card"><button>Close</button><button type="submit">Go</button></div>)
        )

      assert Fields.role(entry) == :none
    end

    test "two outer elements are not one button" do
      assert Fields.role(send_entry(~S(<button>Go</button><span>after</span>))) == :none
    end

    test "text and comments around the one outer element do not hide it" do
      assert Fields.role(send_entry("\n  <!-- a note -->\n  <button>Go</button>\n")) == :submit
    end

    test "a row with no markup is asked of its declared type" do
      assert Fields.role(send_entry("", [type_attr("submit", ~w(button submit reset))])) ==
               :submit

      assert Fields.role(send_entry("", [type_attr("text", ~w(text email))])) == :none
      assert Fields.role(send_entry("")) == :none
    end
  end

  defp placed(source),
    do: source |> Tree.parse!() |> Tree.walk() |> Enum.find(&(&1.kind in [:tag, :component]))

  defp memo(node, components) do
    roles = Fields.roles([node], components)
    {roles, Fields.submit_rules(roles, components)}
  end

  defp sends?(source, components \\ []) do
    node = placed(source)
    {roles, rules} = memo(node, components)
    Fields.submit_node?(node, roles, rules)
  end

  defp explicit?(source, components \\ []) do
    node = placed(source)
    {roles, rules} = memo(node, components)
    Fields.explicit_submit?(node, roles, rules)
  end

  defp button?(source, components \\ []) do
    node = placed(source)
    {roles, rules} = memo(node, components)
    Fields.button_node?(node, roles, rules)
  end

  describe "submit_node?/3, decided per placed node" do
    test "HTML's own button sends unless its type says otherwise" do
      assert sends?(~S(<button>Go</button>))
      assert sends?(~S(<button type="submit">Go</button>))
      assert sends?(~S(<button type=" Submit ">Go</button>))
      refute sends?(~S(<button type="button">Go</button>))
      refute sends?(~S(<button type="reset">Go</button>))
      refute sends?(~S(<button type={@kind}>Go</button>))
    end

    test "HTML's own input sends only when typed submit or image" do
      assert sends?(~S(<input type="submit" />))
      assert sends?(~S(<input type="image" src="/go.png" />))
      refute sends?(~S(<input type="text" name="q" />))
      refute sends?(~S(<input name="q" />))
    end

    test "the CMS's own button sends by its declared default" do
      assert sends?(~S(<.button>Send</.button>))
      assert sends?(~S(<.button type="submit">Send</.button>))
      refute sends?(~S(<.button type="button">Open</.button>))
      refute sends?(~S(<.button type="reset">Clear</.button>))
    end

    test "the CMS's own button renders a link when given one, and a link never sends" do
      for link <- ~w(href navigate patch) do
        refute sends?(~s(<.button #{link}="/home">Home</.button>)), link
      end
    end

    test "HTML's own button stays a button whatever link attribute it carries" do
      for link <- ~w(href navigate patch) do
        assert sends?(~s(<button #{link}="/home">Home</button>)), link
        assert sends?(~s(<input type="submit" #{link}="/home" />)), link
      end
    end

    test "a component with no markup is a link only through a link attribute it declares" do
      plain = send_entry("", [type_attr("submit", ~w(button submit reset))])

      linking = %{
        plain
        | attrs: [
            %{"name" => "rest", "type" => "global", "opts" => %{"include" => ~w(navigate)}}
            | plain.attrs
          ]
      }

      node =
        ~S(<.component component_name="acme-button" site="Global" navigate="/x">Go</.component>)

      assert sends?(node, [plain])
      refute sends?(node, [linking])
    end

    test "a component that is not a button never sends" do
      refute sends?(~S(<.component component_name="acme-card" site="Global" />), [
               %{name: "acme-card", attrs: [], template: ~S(<div><button>x</button></div>)}
             ])
    end

    test "a type written as a literal expression is read as the word it holds" do
      assert sends?(~S(<button type={"submit"}>Go</button>))
      assert sends?(~S(<input type={"Submit"} />))
      assert sends?(~S(<.button type={:submit}>Go</.button>))
      refute sends?(~S(<.button type={:button}>Go</.button>))
      refute sends?(~S(<button type={"button"}>Go</button>))
    end

    test "an atom-typed kit button sends by the atom the Inspector writes" do
      kit = [atom_button()]

      button =
        &~s(<.component component_name="acme-button" site="Global" type={#{&1}}>Go</.component>)

      assert sends?(button.(":submit"), kit)
      refute sends?(button.(":button"), kit)
      assert explicit?(button.(":submit"), kit)
      refute explicit?(button.(":button"), kit)
    end
  end

  # A kit button whose `type` is an atom, as `chelekom-alert`'s `kind` is.
  defp atom_button,
    do:
      send_entry(~S|<button type={@type}>{render_slot(@inner_block)}</button>|, [
        %{
          "name" => "type",
          "type" => "atom",
          "opts" => %{"default" => "button", "values" => ~w(button submit)}
        }
      ])

  describe "explicit_submit?/3, what counts outside a form" do
    test "a button left to its default does not say it submits" do
      refute explicit?(~S(<button>Go</button>))
      refute explicit?(~S(<.button>Go</.button>))
      refute explicit?(~S(<input type="button" value="Go" />))
    end

    test "a written submit or image does" do
      assert explicit?(~S(<button type="submit">Go</button>))
      assert explicit?(~S(<input type="image" src="/go.png" />))
      assert explicit?(~S(<.button type="submit">Go</.button>))
    end

    test "so does one written as a literal expression, in any case" do
      assert explicit?(~S(<button type={"submit"}>Go</button>))
      assert explicit?(~S(<input type={:image} src="/go.png" />))
      assert explicit?(~S(<.button type={:submit}>Go</.button>))
      assert explicit?(~S(<input type="SUBMIT" />))
      refute explicit?(~S(<button type={@kind}>Go</button>))
    end

    test "a link does not, even with the word written on it" do
      refute explicit?(~S(<.button type="submit" navigate="/">Go</.button>))
    end

    test "HTML's own button says it with a link attribute on it too" do
      assert explicit?(~S(<button type="submit" href="/">Go</button>))
    end

    test "a kit whose outer element fixes the literal says it for every node" do
      kit = %{
        name: "acme-send",
        attrs: [%{"name" => "value", "type" => "string"}],
        template: ~S(<input type="submit" value={@value} class="btn" />)
      }

      assert explicit?(~S(<.component component_name="acme-send" site="Global" />), [kit])
    end
  end

  defp unread?(source, components \\ []) do
    node = placed(source)
    {roles, rules} = memo(node, components)
    Fields.type_unread?(node, roles, rules)
  end

  describe "type_unread?/3" do
    test "a button that computes its type cannot be read", %{by_name: by_name} do
      assert unread?(~S(<button type={@kind}>Go</button>))
      assert unread?(~S(<.button type={assigns[:kind]}>Go</.button>))

      assert unread?(
               ~S(<.component component_name="chelekom-button" site="Global" type={@t}>Go</.component>),
               [entry(by_name["chelekom-button"])]
             )
    end

    test "a written, literal or absent type, a link, a field and a fixed kit are read" do
      kit = %{
        name: "acme-send",
        attrs: [%{"name" => "value", "type" => "string"}],
        template: ~S(<input type="submit" value={@value} />)
      }

      for {source, palette} <- [
            {~S(<button>Go</button>), []},
            {~S(<button type="button">Go</button>), []},
            {~S(<button type={:button}>Go</button>), []},
            {~S(<.button navigate="/" type={@kind}>Go</.button>), []},
            {~S(<input type={@kind} name="q" />), []},
            {~S(<div type={@kind}>Go</div>), []},
            {~S(<.component component_name="acme-send" site="Global" type={@kind} />), [kit]}
          ] do
        refute unread?(source, palette), source
      end
    end
  end

  defp written_on(source, components \\ []) do
    node = placed(source)
    {roles, rules} = memo(node, components)
    Fields.type_attr(node, roles, rules)
  end

  describe "type_attr/3" do
    test "a button's type is written on type, and a button that renders a link has none" do
      assert written_on(~S(<.button>Go</.button>)) == "type"
      assert written_on(~S(<button type="button">Go</button>)) == "type"

      for link <- ~w(href navigate patch) do
        refute written_on(~s(<.button #{link}="/back">Back</.button>)), link
      end
    end
  end

  describe "button_node?/3" do
    test "HTML's buttons, button-typed inputs and Send components are buttons" do
      for source <- [
            ~S(<button>Go</button>),
            ~S(<button type="button">Go</button>),
            ~S(<input type="reset" />),
            ~S(<.button>Go</.button>)
          ] do
        assert button?(source), source
      end
    end

    test "a text input and a div are not" do
      for source <- [~S(<input type="text" name="q" />), ~S(<div>Go</div>)] do
        refute button?(source), source
      end
    end

    test "a kit input that can be a Send button is one only where it is placed as one" do
      kit = [send_entry(~S(<input type={@type} />), [type_attr("text", ~w(text email submit))])]
      input = &~s(<.component component_name="acme-button" site="Global"#{&1} />)

      refute button?(input.(""), kit)
      refute button?(input.(~s( type="email")), kit)
      assert button?(input.(~s( type="submit")), kit)
      assert button?(input.(~s( type={@kind})), kit)
    end

    test "a kit button is a button whatever type it is given", %{by_name: by_name} do
      palette = [entry(by_name["chelekom-button"])]

      for attrs <- ["", ~s( type="button"), ~s( type="email")] do
        assert button?(
                 ~s(<.component component_name="chelekom-button" site="Global"#{attrs}>Go</.component>),
                 palette
               ),
               attrs
      end
    end
  end

  @lending %{
    name: "acme-form",
    attrs: [%{"name" => "for", "type" => "any"}],
    template: ~S|<.form :let={f} for={@for}><div>{render_slot(@inner_block, f)}</div></.form>|
  }

  @list %{
    name: "acme-list",
    attrs: [%{"name" => "items", "type" => "list"}],
    template: ~S|<ul><li :for={item <- @items}>{render_slot(@inner_block, item)}</li></ul>|
  }

  describe "lends_form?/2 and hands_form?/2" do
    test "a form handed to what is written inside it is lent" do
      assert Fields.lends_form?(@lending)
    end

    test "a form that keeps its variable to itself is not" do
      entry = %{
        @lending
        | template: ~S|<.form :let={f} for={@for}>{render_slot(@inner_block)}</.form>|
      }

      refute Fields.lends_form?(entry)
    end

    test "handing on some other variable is not handing on the form" do
      entry = %{
        @lending
        | template: ~S|<.form :let={f} for={@for}>{render_slot(@inner_block, @for)}</.form>|
      }

      refute Fields.lends_form?(entry)
    end

    test "the hand-on has to sit inside the form that binds it" do
      entry = %{
        @lending
        | template:
            ~S|<div>{render_slot(@inner_block, f)}</div><.form :let={f} for={@for}></.form>|
      }

      refute Fields.lends_form?(entry)
    end

    test "a raw form lends nothing, because HEEx refuses `:let` on a tag" do
      entry = %{
        name: "acme-raw",
        attrs: [],
        template: ~S|<form>{render_slot(@inner_block)}</form>|
      }

      refute Fields.lends_form?(entry)
      refute Fields.hands_form?(placed(~S(<form action="/x"></form>)), [])
      assert Fields.hands_form?(placed(~S(<.form for={%{}}></.form>)), [])
    end

    test "a list that yields each item is not lending a form" do
      wrapper = %{
        name: "acme-list-wrapper",
        attrs: [%{"name" => "items", "type" => "list"}],
        template:
          ~S|<.component component_name="acme-list" site="Global" :let={item} items={@items}>{render_slot(@inner_block, item)}</.component>|
      }

      refute Fields.lends_form?(@list, [@list, wrapper])
      refute Fields.lends_form?(wrapper, [@list, wrapper])
      refute Fields.hands_form?(placed(~S(<.component component_name="acme-list" />)), [@list])
    end

    test "a component calling a lending one lends through it, read from its markup" do
      outer = %{
        name: "acme-simple",
        attrs: [%{"name" => "for", "type" => "any"}],
        template:
          ~S|<.component component_name="acme-form" site="Global" :let={f} {assigns}>{render_slot(@inner_block, f)}</.component>|
      }

      assert Fields.lends_form?(outer, [@lending, outer])

      assert Fields.hands_form?(placed(~S(<.component component_name="acme-simple" />)), [
               @lending,
               outer
             ])

      refute Fields.lends_form?(outer), "without the palette the call cannot be read"
    end

    test "two components that call each other answer instead of looping" do
      a = %{
        name: "acme-a",
        attrs: [],
        template:
          ~S|<.component component_name="acme-b" :let={f}>{render_slot(@inner_block, f)}</.component>|
      }

      b = %{
        name: "acme-b",
        attrs: [],
        template:
          ~S|<.component component_name="acme-a" :let={f}>{render_slot(@inner_block, f)}</.component>|
      }

      refute Fields.lends_form?(a, [a, b])
      assert Fields.role(a, [a, b]) == :none
    end
  end

  describe "a wrapper through the component it calls" do
    @simple %{
      name: "acme-simple",
      attrs: [%{"name" => "for", "type" => "any"}],
      template:
        ~S|<.component component_name="acme-form" site="Global" :let={f} {assigns}>{render_slot(@inner_block, f)}</.component>|
    }

    test "is a wrapper when the component it calls is one, with no required `for`" do
      assert Fields.role(@simple, [@lending, @simple]) == :wrapper
    end

    test "and is not one when the palette cannot say what it calls" do
      assert Fields.role(@simple) == :none
    end

    test "counts as a form on the page" do
      node = placed(~S(<.component component_name="acme-simple" site="Global" for={%{}} />))

      assert Fields.form_node?(node, Fields.roles([node], [@lending, @simple]))
    end

    test "calling a list is not calling a form" do
      caller = %{
        @simple
        | name: "acme-list-caller",
          template: ~S(<.component component_name="acme-list" />)
      }

      assert Fields.role(caller, [@list, caller]) == :none
    end
  end

  describe "binding_attr/1 and pair_attrs/1" do
    test "a declared binding names the component's own attribute" do
      entry =
        %{
          name: "acme-thing",
          attrs: [
            %{"name" => "bind", "type" => "any"},
            %{"name" => "input_name", "type" => "string"},
            %{"name" => "input_value", "type" => "string"}
          ],
          template: ~S(<input name={@input_name} value={@input_value} />)
        }
        |> Map.put(:form, %{
          "role" => "field",
          "field" => "bind",
          "name" => "input_name",
          "value" => "input_value"
        })

      assert Fields.binding_attr(entry) == "bind"
      assert Fields.pair_attrs(entry) == {"input_name", "input_value"}
    end

    test "a declared binding naming an attribute the component does not have is dropped" do
      entry =
        %{name: "acme-thing", attrs: [], template: "<div />"}
        |> Map.put(:form, %{"role" => "field", "field" => "nowhere"})

      assert Fields.binding_attr(entry) == nil
      assert Fields.pair_attrs(entry) == {nil, nil}
    end

    # THE FALLBACK USED TO BE THE LITERAL "name" AND "value", which is Phoenix's spelling of two
    # attributes this component does not have. The drop then deleted two absent attributes and left
    # the two real blanks in place — and a kit derives them with `assign_new/3`, which fills only an
    # ABSENT key, so `input_name=""` won and the input submitted nothing.
    test "a kit declaring only its binding still has its own pair read off its markup" do
      entry = Map.put(form_field_entry("bind"), :form, %{"role" => "field", "field" => "bind"})

      assert Fields.binding_attr(entry) == "bind"
      assert Fields.pair_attrs(entry) == {"input_name", "input_value"}
    end

    test "an undeclared component falls back to the FormField attribute and its rendered pair" do
      entry = form_field_entry("bind")

      assert Fields.binding_attr(entry) == "bind"
      assert Fields.pair_attrs(entry) == {"input_name", "input_value"}
    end

    test "a component with no pair at all says so, rather than naming Phoenix's two" do
      entry = %{name: "acme-thing", attrs: [], template: ~S(<div class="x">nothing</div>)}

      assert Fields.pair_attrs(entry) == {nil, nil}
    end

    test "a half-declared pair is completed from the markup rather than guessed" do
      entry =
        "bind"
        |> form_field_entry()
        |> Map.put(:form, %{"role" => "field", "field" => "bind", "name" => "input_name"})

      assert Fields.pair_attrs(entry) == {"input_name", "input_value"}
    end
  end

  # The whole editor's answer to "is this node a form" and "is this node a field". It used to be
  # four answers in four modules, and the narrowest — Containment's — never asked the kit, which is
  # how a kit's form wrapper was allowed to nest inside another form.
  describe "form_node?/2 and field_node?/2" do
    @wrapper %{
      name: "kit-form",
      attrs: [%{"name" => "for", "type" => "any"}],
      template: ~S(<.form :let={f} for={@for}><div class="wrapper-form"></div></.form>)
    }

    @pair_field %{
      name: "kit-pair-field",
      attrs: [
        %{"name" => "input_name", "type" => "any"},
        %{"name" => "input_value", "type" => "any"}
      ],
      template: ~S(<input name={@input_name} value={@input_value} />)
    }

    defp nodes(source), do: source |> Tree.parse!() |> Tree.walk()

    defp node_named(source, tag), do: source |> nodes() |> Enum.find(&(&1.tag == tag))

    defp roles(source), do: Fields.roles(nodes(source), [@wrapper, @pair_field])

    test "a raw form element and Phoenix's own component are both forms" do
      for {source, tag} <- [{~S(<form></form>), "form"}, {~S(<.form for={%{}}></.form>), ".form"}] do
        assert Fields.form_node?(node_named(source, tag), roles(source))
      end
    end

    test "a kit wrapper is a form, which is the answer Containment never had" do
      source = ~S(<.component component_name="kit-form" site="Global" for={%{}} />)

      assert Fields.form_node?(node_named(source, ".component"), roles(source))
    end

    test "a node naming a page assign is a form whatever it is called" do
      source = ~S(<.component component_name="unknown-thing" for={assigns[:q_form]} />)

      assert Fields.form_node?(node_named(source, ".component"), roles(source))
    end

    test "an ordinary section is not a form" do
      source = ~S(<section id="band"></section>)

      refute Fields.form_node?(node_named(source, "section"), roles(source))
    end

    test "a kit field is a field, and HTML's own controls are fields" do
      source =
        ~S(<div><.component component_name="kit-pair-field" site="Global" /><input name="e" /><select name="s"></select><textarea name="t"></textarea></div>)

      roles = roles(source)

      for tag <- ~w(.component input select textarea) do
        assert Fields.field_node?(node_named(source, tag), roles), "#{tag} should be a field"
      end
    end

    test "a submit input carries no value, so it is not a field" do
      source = ~S(<input type="submit" value="Send" />)

      refute Fields.field_node?(node_named(source, "input"), roles(source))
    end

    test "however its type is written: in capitals, padded, or as a literal expression" do
      for source <- [
            ~S(<input type="Submit" />),
            ~S(<input type=" SUBMIT " />),
            ~S(<input type={"submit"} />),
            ~S(<input type={:reset} />)
          ] do
        node = node_named(source, "input")

        refute Fields.field_node?(node, roles(source)), source
        assert Fields.button_node?(node, roles(source), %{}), source
      end
    end

    test "a component the palette has never heard of is neither" do
      source = ~S(<.component component_name="mystery" site="Global" />)

      refute Fields.form_node?(node_named(source, ".component"), roles(source))
      refute Fields.field_node?(node_named(source, ".component"), roles(source))
    end
  end

  describe "against the installed kits" do
    test "the two components that own a form are wrappers", %{by_name: by_name} do
      for name <- ~w(chelekom-form-wrapper chelekom-simple-form) do
        assert Fields.wrapper?(entry(by_name[name])), "#{name} should be a wrapper"
      end
    end

    test "a label is not a wrapper just for having a `for`", %{by_name: by_name} do
      refute Fields.wrapper?(entry(by_name["chelekom-label"]))
    end

    test "the kit's form fields are fields", %{by_name: by_name} do
      for name <- ~w(chelekom-text-field chelekom-native-select chelekom-combobox) do
        assert Fields.role(entry(by_name[name])) == :field
      end
    end

    test "its button is a Send button, and its input button is not", %{by_name: by_name} do
      assert Fields.role(entry(by_name["chelekom-button"])) == :submit
      assert Fields.role(entry(by_name["chelekom-input-button"])) == :none
    end

    # FOURTEEN OTHER COMPONENTS HAVE A BUTTON INSIDE: a password field's eye, a modal's close, a
    # carousel's arrows. Only the outer element counts, so none of them becomes a Send button.
    test "the button is the kit's only Send button", %{by_name: by_name} do
      palette = kit(by_name)

      assert for(entry <- palette, Fields.role(entry, palette) == :submit, do: entry.name) ==
               ["chelekom-button"]

      assert Fields.role(entry(by_name["chelekom-password-field"]), palette) == :field
    end

    test "a placed button sends unless it says otherwise", %{by_name: by_name} do
      palette = [entry(by_name["chelekom-button"])]
      button = ~S(<.component component_name="chelekom-button" site="Global")

      assert sends?(button <> ">Send</.component>", palette)
      assert sends?(button <> ~S( type="submit">Send</.component>), palette)
      refute sends?(button <> ~S( type="button">Open</.component>), palette)
      refute sends?(button <> ~S( type="reset">Clear</.component>), palette)
    end

    # Its outer element is always a `<button>`: `navigate` goes through `@rest` onto it, and an
    # untyped button sends its form.
    test "a placed button given a link attribute still sends", %{by_name: by_name} do
      palette = [entry(by_name["chelekom-button"])]
      button = ~S(<.component component_name="chelekom-button" site="Global")

      assert sends?(button <> ~S( navigate="/pricing">Pricing</.component>), palette)
      assert explicit?(button <> ~S( type="submit" href="/pricing">Pricing</.component>), palette)
    end

    test "outside a form only a written submit counts", %{by_name: by_name} do
      palette = [entry(by_name["chelekom-button"])]
      button = ~S(<.component component_name="chelekom-button" site="Global")

      refute explicit?(button <> ">Start</.component>", palette)
      refute explicit?(button <> ~S( type="button">Start</.component>), palette)
      assert explicit?(button <> ~S( type="submit">Send</.component>), palette)
    end

    test "the form wrapper lends its form, and the simple form lends it through the wrapper", %{
      by_name: by_name
    } do
      palette = kit(by_name)

      assert Fields.lends_form?(entry(by_name["chelekom-form-wrapper"]), palette)
      assert Fields.lends_form?(entry(by_name["chelekom-simple-form"]), palette)
      refute Fields.lends_form?(entry(by_name["chelekom-simple-form"]))
    end

    test "no other component in the kit lends a form", %{by_name: by_name} do
      palette = kit(by_name)

      assert palette |> Enum.filter(&Fields.lends_form?(&1, palette)) |> Enum.map(& &1.name) ==
               ["chelekom-form-wrapper", "chelekom-simple-form"]
    end

    # THE CONCERN THIS WORK EXISTS FOR: Chelekom may be absent, its rows renamed, or another
    # developer's kit installed. A copy under another name answers exactly what the original does.
    test "a renamed copy of each answers what the original does", %{by_name: by_name} do
      palette = kit(by_name)

      for name <-
            ~w(chelekom-button chelekom-input-button chelekom-password-field chelekom-form-wrapper chelekom-simple-form) do
        copy = renamed(by_name[name], "my-kit-" <> String.replace_prefix(name, "chelekom-", ""))
        with_copy = [copy | palette]

        assert Fields.role(copy, with_copy) == Fields.role(entry(by_name[name]), palette), name

        assert Fields.lends_form?(copy, with_copy) ==
                 Fields.lends_form?(entry(by_name[name]), palette),
               name
      end
    end

    test "a renamed button sends and stays quiet exactly as the original", %{by_name: by_name} do
      palette = [renamed(by_name["chelekom-button"], "my-kit-button")]
      button = ~S(<.component component_name="my-kit-button" site="Global")

      assert sends?(button <> ">Send</.component>", palette)
      refute sends?(button <> ~S( type="button">Open</.component>), palette)
      refute explicit?(button <> ">Start</.component>", palette)
    end

    test "a renamed pair is read by structure: the simple form calling the renamed wrapper", %{
      by_name: by_name
    } do
      palette =
        Factory.renamed_form_pair([
          entry(by_name["chelekom-form-wrapper"]),
          entry(by_name["chelekom-simple-form"])
        ])

      [_wrapper, simple] = palette

      assert Fields.role(simple, palette) == :wrapper
      assert Fields.lends_form?(simple, palette)
    end

    test "a kit's own declaration wins over what its markup says", %{by_name: by_name} do
      declared = Map.put(entry(by_name["chelekom-button"]), :form, %{"role" => "error"})

      assert Fields.role(declared) == :error
    end

    test "the CMS's own button is a Send button and its input stays a field" do
      nodes =
        ~S(<div><.button>Go</.button><.input field={f[:email]} type="email" /></div>)
        |> Tree.parse!()
        |> Tree.walk()

      assert Fields.roles(nodes, []) == %{"button" => :submit, "input" => :field}
    end
  end

  defp kit(by_name), do: by_name |> Map.values() |> Enum.map(&entry/1) |> Enum.sort_by(& &1.name)

  defp renamed(component, name), do: %{entry(component) | name: name}
end
