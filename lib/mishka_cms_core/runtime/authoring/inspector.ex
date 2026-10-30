# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Inspector do
  @moduledoc """
  Decides which control a component attribute gets in the property panel, and groups the attributes
  into sections — all as pure functions, so the no-code surface is testable without a browser.

  ## Where the option lists come from

  A Chelekom attribute almost never declares its own `opts.values`: it is `"string"` with a doc
  string, and the real list of colours, sizes and variants lives in the component's
  `helpers[].discriminators` — the axis clauses extracted from the kit's `.eex` source. That is why
  the React editor could never have shown a variant dropdown: the data it needed was in a field the
  editor was never sent.

  `features/1` folds both sources the way `MishkaCmsCore.Runtime.Handlers.UiKitHandler` does
  (helper-derived values win over attr-declared ones) so `widget/2` can offer a real select for the
  ~130 of 136 components that carry discriminators.

  ## Widget resolution

      boolean                                   → :toggle
      a known value list, ≤ 5 short entries     → {:segmented, values}
      a known value list                        → {:select, values}
      integer / float                           → {:number, min, max, step}
      string named like a colour, or editor hint → :color
      a long doc, or editor hint                → :textarea
      type "global" (the `@rest` catch-all)      → :global
      type "struct"                              → {:struct, name}
      anything else                              → :text

  ## The contract a kit can write instead — `opts.editor`

  Everything above is a GUESS, and a guess reads one thing: how this kit happens to spell its
  attributes. `icon` gets the picker because the word is on a list. A kit that calls the same thing
  `glyph` gets a text box, and no amount of adding names fixes that — it moves the failure to the
  next kit.

  So a kit can say it outright. `opts["editor"]` on an attribute is read FIRST and is authoritative:

  | `opts.editor` | control | for |
  |---|---|---|
  | `"color"` | a swatch | an actual colour value — a hex, a CSS colour |
  | `"icon"` | the searchable icon picker | an icon class name |
  | `"media"` | the media library | a picture the author picks |
  | `"url"` | an address field | a link the author types |
  | `"number"` | a stepper, honouring `min`/`max`/`step` | a count or a duration, EVEN IF its type is a string |
  | `"toggle"` | a switch | a flag, even if its type is a string |
  | `"textarea"` | a box with room | prose |
  | `"select"` | a dropdown, or pills when the list is short | drawn from the attribute's own `values` |
  | `"columns"` | a row of shapes | a layout count, drawn from `values` |
  | `"text"` | a plain text box | the kit OVERRULING a guess — an attribute called `icon` that holds something else |

  Three properties make this safe for a kit nobody here has seen:

    * **A declaration always wins.** It is read before every heuristic and before the value list, so a
      kit is never argued with about its own attributes.
    * **An unknown value degrades, it does not break.** A bundle written against a later version of
      this editor — `"editor" => "colour-wheel"` — loses the refinement and falls back to inference.
      It does not raise, and it does not collapse to a text box.
    * **Declaring nothing is still supported.** The heuristics below are the fallback, not the plan,
      and they stay for exactly that reason: a kit that says nothing must still get sensible controls.

  `editors/0` is the accepted list, so a kit author can read it rather than guess at it.

  ## The two sections a form adds

  Everything above answers "what control does this attribute get". Two sections answer a different
  question — "what does this node need in order to be a working form" — and neither is derived from a
  kit's attribute list, so both are declared: `form_sections/0` returns them as ordinary
  `builder:inspector:sections` descriptors carrying their controls in `config`, which an editor
  seeds into its section registry. An extension contributing a section of its own writes the same
  shape.

  **Form** shows on a node that declares a page form (`form_node?/1`). Its one real control is the
  seed — the single word every other name on the form is derived from — so `rename_ops/3` writes all
  five of `MishkaCmsCore.Runtime.Authoring.PageForms.Naming.derived/0` as one batch of ops an
  editor applies together, with the token `rename_token/4` picks. One history entry, and the five
  can never disagree because nothing edits one of them alone.
  `seed_refusal/3` is what stops a rename landing on a name another form is already using, and
  `rename_warning/2` says what stored code a rename would stop.

  `data-success` is on the form node, so it is a Form control rather than a Validation one even
  though it is about what happens after a submit.

  ## The rest of the Form panel

  `form_state/2` says which of these a node gets. A working form also has Form · Phoenix
  (`form_names/1`, `phoenix_form_controls/2`, `address_ops/2`), a field inside one has Field options
  (`field_controls/3`) and a button inside one has Send button (`send_controls/4`). Each control is
  offered only where the node forwards its attribute (`Fields.takes?/3`), and Props and Advanced
  leave `form_panel_attrs/0` to these sections.

  **Validation** shows on a bound field inside a form (`validated_node?/2`). Every control writes one
  ordinary HTML constraint attribute — `required`, `minlength`, `maxlength`, `min`, `max`, `pattern`,
  plus `data-format` and `data-confirms` for the two things HTML has no word for. There is no rule
  store: `MishkaCmsCore.Runtime.Authoring.PageForms` reads these back off the markup at compile
  time and `MishkaCmsCore.Runtime.PageForm.Rules` executes them, so the browser and the server are
  reading one declaration and cannot disagree about it.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Builder.Descriptor
  alias MishkaCmsCore.Builder.Literal
  alias MishkaCmsCore.Runtime.Authoring.Fields
  alias MishkaCmsCore.Runtime.Authoring.PageForms
  alias MishkaCmsCore.Runtime.Authoring.PageForms.FormChecks
  alias MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.Authoring.PageForms.Naming
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  # `border` is deliberately NOT here. In this kit it is a WIDTH token — the template calls
  # `border_size(@border, @variant)` and the values are `none`/`extra_small`/…/`large` — so guessing
  # "colour" from the word drew a hex swatch for 60 of the panel's 70 colour controls. A component
  # that genuinely wants a border COLOUR names the attribute `border_color`, which still matches.
  @colour_names ~w(color colour bg background text_color border_color accent fill stroke)
  # `action` is deliberately NOT here, for the reason `border` is not in the colour list. It reads as
  # a URL only on a `<form>`, and `named?/2` matches any underscore-separated PART — so it claimed
  # `action_position` (a position), `action_wrapper_class` and `actions_class` (CSS classes) and
  # `on_action` (an event handler). Four attributes in the kit contain the word and not one of them
  # is an address. A form that genuinely has one says `editor: "url"`, which beats every guess here.
  @url_names ~w(href src url link)
  @icon_names ~w(icon start_icon end_icon leading_icon trailing_icon)
  @media_names ~w(image image_url avatar thumbnail poster)

  @segmented_limit 5
  @segmented_value_length 8
  @textarea_doc_length 90

  # The declared types a collection is held in, and the numeric ones.
  @collections ~w(list keyword_list map)
  @numbers ~w(integer float pos_integer)

  # Which attribute names fall under which heading. The ORDER of the panel is `@group_order`, not
  # this list — "Properties" is the catch-all and has no key list to match on.
  @groups [
    {gettext_noop("Content"), ~w(title label text description placeholder content value)},
    {gettext_noop("Appearance"), ~w(color variant theme shadow opacity font weight)},
    {gettext_noop("Layout"),
     ~w(size space padding gap width height rounded border position display)},
    {gettext_noop("Behavior"), ~w(disabled readonly required active open animated hidden)}
  ]

  # Content, then Appearance, then the rest. The claim: an author opens the inspector for the words
  # on the element and then for what it LOOKS like. "Properties" is everything the other headings do
  # not name — leftovers by construction, and on a kit component the leftovers are `class`, `id` and
  # `wrapper_class`: plumbing, not choices.
  #
  # APPEARANCE USED TO SIT BEHIND THAT PLUMBING. On a jumbotron — no Content attrs of its own — the
  # first thing the panel showed was Class and Id, and `variant`, the property that changes what the
  # component IS, was the third field of the second section. Reported on the editor issue as "it
  # isn't obvious or close at hand how to set a variant".
  @group_order [
    gettext_noop("Content"),
    gettext_noop("Appearance"),
    gettext_noop("Properties"),
    gettext_noop("Layout"),
    gettext_noop("Behavior")
  ]

  # Within a section, alphabetical is a TIE-BREAK and not an order. `variant` and `color` are the two
  # knobs that change a kit component's whole appearance, and sorted by name they came third and
  # first — `color`, `font_weight`, `variant` — with the one that matters most last. These four lead
  # their group; everything else keeps the alphabet, which is at least predictable.
  @lead ~w(variant color theme size)

  @doc """
  The option values available per attribute name, folded from the component's helper
  discriminators and its attributes' own `opts.values`.

  Accepts a palette entry (atom keys), a raw component row, or anything shaped like one.
  """
  @spec features(map()) :: %{optional(String.t()) => [String.t()]}
  # ANSWERED WHEN THE PALETTE WAS READ, if the caller is a palette entry. Folding the axes out of a
  # component means re-reading its whole template and every helper body, and the entry has carried
  # the result since it was built — recomputing it was both slower and the only reason the entry
  # still had to carry the source at all.
  def features(%{features: %{} = features}) when map_size(features) > 0, do: features

  def features(component) do
    MishkaCmsCore.Runtime.Handlers.UiKitHandler.component_features(%{
      "attrs" => Enum.map(attrs(component), &stringify/1),
      "helpers" => Enum.map(helpers(component), &stringify/1),
      # The template comes along because that is where the axis→attribute binding is written: a
      # helper's parameter is called `color`, and the call site says which attribute is passed into
      # it. Without it every axis stays keyed by the helper's own vocabulary.
      "template" => template(component)
    })
  end

  @doc "A component's template, however the caller happens to hold the component."
  @spec template(map()) :: String.t()
  def template(%{template: template}) when is_binary(template), do: template
  def template(%{"template" => template}) when is_binary(template), do: template
  def template(_component), do: ""

  @doc "A component's attribute definitions, however the caller happens to hold the component."
  @spec attrs(map()) :: [map()]
  def attrs(%{attrs: attrs}) when is_list(attrs), do: attrs
  def attrs(%{"attrs" => attrs}) when is_list(attrs), do: attrs
  def attrs(_component), do: []

  @doc "A component's slot definitions."
  @spec slots(map()) :: [map()]
  def slots(%{slots: slots}) when is_list(slots), do: slots
  def slots(%{"slots" => slots}) when is_list(slots), do: slots
  def slots(_component), do: []

  @doc """
  Whether a slot definition is Phoenix's `inner_block` — the content written *between* a component's
  tags rather than in a `<:name>` block of its own.

  It is the one slot that must never be offered as something to add: `<:inner_block>` is rejected by
  the HEEx compiler outright ("the slot name :inner_block is reserved"), because writing it is the
  same as writing nothing and putting the content there directly. 82 of the kit's 120 slot-bearing
  components name their only slot this way, so this is the common case, not an edge one.
  """
  @spec inner_block?(map()) :: boolean()
  def inner_block?(slot), do: name(slot) == "inner_block"

  @doc """
  The slots that can be added to a component as `<:name>` blocks — every declared slot except
  `inner_block`, for the reason given in `inner_block?/1`.
  """
  @spec addable_slots(map()) :: [map()]
  def addable_slots(component), do: component |> slots() |> Enum.reject(&inner_block?/1)

  @doc """
  Whether the component ever renders what is written INSIDE this slot.

  Declaring a slot and rendering its body are two different things, and thirteen of the kit's slots
  do only the first: `chelekom-video` declares `:source` and its markup is
  `<source :for={s <- @source} src={s.src} type={s.type} />` — it reads the slot's ATTRIBUTES and
  never calls `render_slot`. So a card dropped into `:source` is accepted, is stored, appears in the
  tree, and is drawn nowhere. The author is left looking at a slot with something in it and a canvas
  that disagrees, with nothing anywhere saying why.

  Two shapes count as rendering, because Phoenix writes multi-slots the second way:

      {render_slot(@caption)}
      <div :for={{item, i} <- Enum.with_index(@item, 1)}>{render_slot(item)}</div>

  READ OFF THE MARKUP, because nothing else knows. A slot declaration says a slot exists and what
  attributes it takes; whether its body reaches the page is a property of the template alone. That
  makes this a scan of source text rather than a lookup, with the limits that implies — a slot
  rendered by a helper this does not see, or through a binding it cannot follow, would be read as
  unrendered.

  Which is why it answers **true when it cannot tell**. Being wrong the other way would refuse drops
  into a slot that does take content, and a false "you cannot put anything here" is much worse than
  the silence this exists to end: `inner_block` (always rendered by definition), a component with no
  markup stored, and any slot this cannot make sense of are all treated as taking content.
  """
  @spec renders_slot?(map(), String.t()) :: boolean()
  def renders_slot?(component, slot_name)

  def renders_slot?(_component, "inner_block"), do: true

  def renders_slot?(component, slot_name) when is_binary(slot_name) do
    source = slot_source(component)
    binders = binders_for(source, slot_name)

    cond do
      source == "" -> true
      String.contains?(source, "render_slot(@#{slot_name}") -> true
      # NO COMPREHENSION OVER IT AT ALL is not evidence of anything. The slot may be handed to a
      # helper, or reached through a binding this cannot follow; only a comprehension that plainly
      # never renders what it binds is enough to say no.
      binders == [] -> true
      Enum.any?(binders, &String.contains?(source, "render_slot(#{&1}")) -> true
      true -> false
    end
  end

  def renders_slot?(_component, _slot_name), do: true

  # The markup AND the helpers, because a component may hand its slot to a private function it
  # defines beside the template.
  defp slot_source(component) do
    template = field(component, "template")

    helpers =
      component
      |> helpers()
      |> Enum.map_join("\n", fn helper -> to_string(field(helper, "body") || "") end)

    String.trim(to_string(template || "") <> "\n" <> helpers)
  end

  # Every name a comprehension over this slot binds. `:for={{item, i} <- Enum.with_index(@item, 1)}`
  # binds `item` and `i`; `:for={action <- @actions}` binds `action`. The binder is whatever appears
  # between `:for={` and `<-`, which covers both the plain form and the destructured one Phoenix's
  # own generators write.
  defp binders_for(source, slot_name) do
    ~r/:for=\{(?<binder>[^<]{0,90})<-[^}]{0,60}@#{Regex.escape(slot_name)}\b/
    |> Regex.scan(source, capture: :all_names)
    |> Enum.flat_map(fn [binder] ->
      ~r/[a-z_][a-zA-Z0-9_]*/ |> Regex.scan(binder) |> Enum.map(&hd/1)
    end)
    |> Enum.uniq()
  end

  @doc """
  Everything this node was told it must have and has not got — its required properties left blank
  (`{:attr, name}`), the required slots nobody added (`{:slot, name}`), and a property holding text
  where the component takes a list or a map (`{:type, name}`, read by `value_type/1`).

  READ OFF THE DECLARATION, never off a list of names. A kit this editor has never seen says which of
  its properties are required the same way Chelekom does — `opts.required` on the attribute, and
  Phoenix's own `:required` on a slot, which is the only option it allows inside one. So this asks
  the component that is actually on the page and works for a component nobody here has heard of.

  ONE ANSWER, THREE READERS. Publishing is refused when this is non-empty, the layers rail draws a
  badge from it, and the Inspector marks the field — and those three used to be two implementations
  of the same rule with the rail not implementing it at all. A gate the author cannot see until they
  press Publish is a gate that finds the problem at the worst moment; a gate that disagrees with the
  badge beside it is worse.

  A slot's properties are declared on the component that OWNS it, which is why the tree is needed to
  answer for one. `inner_block` is never counted: it is whatever is written between the tags, and
  `<:inner_block>` is not something anybody adds.
  """
  @spec unmet(Node.t(), Tree.t(), %{optional(String.t()) => map()}) :: [
          {:attr | :slot | :type, String.t()}
        ]
  def unmet(node, tree, components)

  def unmet(%Node{} = node, %Tree{} = tree, components) when is_map(components),
    do:
      unmet_attrs(node, tree, components) ++
        unmet_slots(node, tree, components) ++ mistyped(node, tree, components)

  def unmet(_node, _tree, _components), do: []

  defp unmet_attrs(node, tree, components) do
    for attr <- declared_attrs(node, tree, components),
        required?(attr),
        attr_name = name(attr),
        is_binary(attr_name),
        blank_attr?(node, attr_name),
        do: {:attr, attr_name}
  end

  defp unmet_slots(%Node{kind: :component} = node, tree, components) do
    for slot <- components |> Map.get(Node.component_name(node)) |> slots(),
        required?(slot),
        slot_name = name(slot),
        is_binary(slot_name),
        slot_name != "inner_block",
        not slot_filled?(node, tree, slot_name),
        do: {:slot, slot_name}
  end

  defp unmet_slots(_node, _tree, _components), do: []

  # TEXT WHERE THE COMPONENT TAKES A LIST OR A MAP. Typed words are a string, and a component that
  # maps over its attribute or reads a key out of it raises on one — on the canvas, and on every
  # visit to the published page.
  defp mistyped(node, tree, components) do
    for attr <- declared_attrs(node, tree, components),
        attr_name = name(attr),
        is_binary(attr_name),
        value_type(attr) in @collections,
        text?(Node.attr(node, attr_name)),
        do: {:type, attr_name}
  end

  defp text?({:string, _text}), do: true
  defp text?(:boolean), do: true
  defp text?(_expression_or_unset), do: false

  # Both kinds declare properties, in different places. A component's are its own; a SLOT's are
  # declared in the slot's block on the component that owns it.
  defp declared_attrs(%Node{kind: :component} = node, _tree, components),
    do: components |> Map.get(Node.component_name(node)) |> attrs()

  defp declared_attrs(%Node{kind: :slot} = node, tree, components) do
    with %Node{} = parent <- Tree.get(tree, node.parent_id),
         %{} = entry <- Map.get(components, Node.component_name(parent)),
         %{} = slot <- Enum.find(slots(entry), &(name(&1) == Node.slot_name(node))) do
      attrs(slot)
    else
      _undeclared -> []
    end
  end

  defp declared_attrs(_node, _tree, _components), do: []

  defp blank_attr?(node, attr_name) do
    case Node.attr_text(node, attr_name) do
      nil -> true
      value -> String.trim(value) == ""
    end
  end

  defp slot_filled?(node, tree, slot_name) do
    Enum.any?(node.children, fn id ->
      child = Tree.get(tree, id)
      child != nil and child.kind == :slot and Node.slot_name(child) == slot_name
    end)
  end

  @doc "A component's helper definitions — where the discriminator axes live."
  @spec helpers(map()) :: [map()]
  def helpers(%{helpers: helpers}) when is_list(helpers), do: helpers
  def helpers(%{"helpers" => helpers}) when is_list(helpers), do: helpers
  def helpers(_component), do: []

  # Helpers arrive as embedded structs and attributes as string-keyed maps; the fold reads string
  # keys, so both are normalized one level deep here.
  defp stringify(%_struct{} = value), do: value |> Map.from_struct() |> stringify()

  defp stringify(%{} = value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), inner} end)

  defp stringify(value), do: value

  @doc "An attribute's declared name."
  @spec name(map()) :: String.t() | nil
  def name(%{name: name}), do: name
  def name(%{"name" => name}), do: name
  def name(_attr), do: nil

  @doc "An attribute's declared type, defaulting to `\"string\"`."
  @spec type(map()) :: String.t()
  def type(attr), do: field(attr, "type") || "string"

  @doc """
  The type an attribute's VALUE has: the one it declares, or — for one declared `any` — the type of
  its default.

  `any` is a kit declining to say, and the default is the kit saying it anyway. `blog-term-row`
  declares `terms` as `any` with `default: []` and maps over it; reading only the declaration gave
  it a textarea, the typed words went in as a string, and the component raised `protocol
  Enumerable not implemented for BitString` on the published page. A list, a map, a boolean or a
  number default names the type; `nil`, a string or no default at all leaves `"any"`.
  """
  @spec value_type(map()) :: String.t()
  def value_type(attr) do
    case type(attr) do
      "any" -> attr |> default() |> default_type()
      declared -> declared
    end
  end

  defp default_type(value) when is_list(value), do: "list"
  defp default_type(value) when is_map(value), do: "map"
  defp default_type(value) when is_boolean(value), do: "boolean"
  defp default_type(value) when is_integer(value), do: "integer"
  defp default_type(value) when is_float(value), do: "float"
  defp default_type(_value), do: "any"

  @doc """
  What a value TYPED into a property's box is written as, decided by what the attribute takes —
  or why it cannot be written at all.

  `held` is what the node holds now. A box shows a binding's source, so that source posted back, or
  source typed over it that still reads something (`MishkaCmsCore.Builder.Literal.expression?/1`), is
  written as an expression again; the same box with words typed over it writes the words. `attr` is `nil` where nothing declares the
  attribute, and the words are then text.

  By the type the attribute's value has (`value_type/1`):

    * a list or a map takes only a literal of its own shape — `["a", "b"]` — because typed words are
      a string, and a component that maps over its attribute raises on one. Anything else is
      refused with a sentence that says what it takes;
    * a boolean takes `true` or `false`, a number a number and an atom one word, each written the
      way HEEx spells it — `{false}`, `{7}`, `{:danger}` — and refused otherwise;
    * anything else takes the text as it was typed.
  """
  @spec typed(map() | nil, String.t(), {:string | :expr, String.t()} | :boolean | nil) ::
          {:ok, {:string, String.t()} | {:expr, String.t()}} | {:error, String.t()}
  def typed(attr, text, held) when is_binary(text) do
    case still_bound?(held, text) do
      true -> {:ok, {:expr, text}}
      false -> typed_as(attr && value_type(attr), attr, text, held)
    end
  end

  defp still_bound?({:expr, source}, text), do: text == source or Literal.expression?(text)
  defp still_bound?(_held, _text), do: false

  defp typed_as(type, attr, text, _held) when type in ["list", "keyword_list"],
    do:
      literal_of(
        text,
        &is_list/1,
        gettext("%{label} takes a list, so typed text cannot go in it. Add its items one by one.",
          label: label(attr)
        )
      )

  defp typed_as("map", attr, text, _held),
    do:
      literal_of(
        text,
        &is_map/1,
        gettext("%{label} takes a map, so typed text cannot go in it.", label: label(attr))
      )

  defp typed_as("boolean", attr, text, _held) do
    case String.trim(text) do
      word when word in ["true", "false"] -> {:ok, {:expr, word}}
      _other -> {:error, gettext("%{label} is on or off: true or false.", label: label(attr))}
    end
  end

  defp typed_as(type, attr, text, _held) when type in @numbers do
    case number_in(type, String.trim(text)) do
      {:ok, number} -> {:ok, {:expr, number}}
      :error -> {:error, gettext("%{label} takes a number.", label: label(attr))}
    end
  end

  defp typed_as("atom", attr, text, _held) do
    word = text |> String.trim() |> String.trim_leading(":")

    case Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/, word) do
      true -> {:ok, {:expr, ":" <> word}}
      false -> {:error, gettext("%{label} takes one word, such as danger.", label: label(attr))}
    end
  end

  # A number or an atom the editor wrote is a literal expression, and the box posts it back as one.
  defp typed_as(_text_type, _attr, text, {:expr, _source}) do
    case Literal.value(text) do
      {:ok, _term} -> {:ok, {:expr, text}}
      :error -> {:ok, {:string, text}}
    end
  end

  defp typed_as(_text_type, _attr, text, _held), do: {:ok, {:string, text}}

  defp literal_of(text, shape?, refusal) do
    case Literal.value(text) do
      {:ok, value} -> (shape?.(value) && {:ok, {:expr, String.trim(text)}}) || {:error, refusal}
      :error -> {:error, refusal}
    end
  end

  defp number_in("float", text) do
    case Float.parse(text) do
      {_number, ""} -> {:ok, text}
      _other -> :error
    end
  end

  defp number_in(type, text) do
    case Integer.parse(text) do
      {number, ""} when type != "pos_integer" or number > 0 -> {:ok, text}
      _other -> :error
    end
  end

  @doc """
  Whether the attribute takes an ATOM rather than a string.

  It matters at the point of writing: `kind="danger"` and `kind={:danger}` are different values, and
  a component whose clauses match `:danger` falls through every one of them when handed the string —
  silently, to whatever its catch-all renders. Three attributes in the Chelekom kit are atoms, and
  one of them is `chelekom-alert`'s `kind`, which decides the alert's entire colour.
  """
  @spec atom?(map()) :: boolean()
  def atom?(attr), do: type(attr) == "atom"

  @doc """
  Whether this attribute carries its icon inside a MAP rather than as a bare name.

  A label is not always a word. `chelekom-pagination` declares its five arrows and its separator as
  `map`, each defaulting to `%{type: :icon, value: "hero-chevron-left"}` so an author can put either
  a glyph or a caption there. Read as a plain map attribute, every one of them drew a text box the
  author had nothing to type into — reported as "we cannot select the icon".

  The shape is asked of the DECLARED DEFAULT, which is the only thing that says what the component
  will do with the value; a kit that spells the same idea on a differently-named attribute is
  covered without being named.
  """
  @spec icon_map?(map()) :: boolean()
  def icon_map?(attr), do: type(attr) == "map" and is_binary(map_icon(default(attr)))

  @doc """
  The icon name inside a value of an `icon_map?/1` attribute, whichever shape it arrives in — the
  bundle's `__atom_map__` envelope, a real map, or the source of the map expression the editor
  itself writes. `nil` when there is no icon in it.
  """
  @spec icon_in(term()) :: String.t() | nil
  def icon_in(value) when is_binary(value) do
    case Code.string_to_quoted(value) do
      {:ok, {:%{}, _meta, pairs}} when is_list(pairs) -> map_icon(Map.new(pairs))
      _unparseable -> nil
    end
  end

  def icon_in(value), do: map_icon(value)

  # The bundle serializes an atom-keyed map as `%{"__atom_map__" => [[":type", ":icon"], …]}`, and a
  # value read back off the document is the ordinary map the editor wrote. Both say the same thing.
  defp map_icon(%{"__atom_map__" => pairs}) when is_list(pairs) do
    pairs
    |> Enum.flat_map(fn
      [key, value] -> [{key, value}]
      _other -> []
    end)
    |> Map.new()
    |> icon_pair(":type", ":icon", ":value")
  end

  defp map_icon(%{} = map), do: icon_pair(map, :type, :icon, :value)
  defp map_icon(_other), do: nil

  defp icon_pair(map, type_key, icon, value_key) do
    case {Map.get(map, type_key), Map.get(map, value_key)} do
      {^icon, value} when is_binary(value) -> value
      _other -> nil
    end
  end

  @doc "An attribute's option map (`opts`), always a map."
  @spec opts(map()) :: map()
  def opts(attr) do
    case field(attr, "opts") do
      %{} = opts -> stringify(opts)
      _other -> %{}
    end
  end

  @doc "Whether the attribute must be set. True on about 1.4% of the Chelekom kit; rendered as `*`."
  @spec required?(map()) :: boolean()
  def required?(attr), do: opts(attr)["required"] == true

  @doc "The attribute's documentation string, used as the control's tooltip."
  @spec doc(map()) :: String.t() | nil
  def doc(attr), do: field(attr, "doc") || opts(attr)["doc"]

  @doc "The value the component falls back to when the attribute is unset."
  @spec default(map()) :: term()
  def default(attr), do: opts(attr)["default"]

  @doc """
  A human label for an attribute — `start_icon` becomes "Start icon". The kit ships no labels, only
  names, so this is derived rather than looked up.
  """
  @spec label(String.t() | map()) :: String.t()
  def label(attr) when is_map(attr), do: attr |> name() |> label()
  def label(nil), do: ""

  def label(name) when is_binary(name) do
    name
    |> String.replace(["_", "-"], " ")
    |> String.trim()
    |> String.capitalize()
  end

  @doc """
  The control an attribute should get. `values` comes from `features/1`; pass `%{}` when unknown and
  the attribute falls back to a plain text input.
  """
  @spec widget(map(), %{optional(String.t()) => [String.t()]}) ::
          :toggle
          | {:segmented, [String.t()]}
          | {:select, [String.t()]}
          | {:number, term(), term(), term()}
          | :color
          | :url
          | :icon
          | :media
          | :textarea
          | :global
          | {:struct, String.t() | nil}
          | {:columns, [String.t()]}
          | {:collection, String.t()}
          | :text
  def widget(attr, features \\ %{}, component \\ nil) do
    name = name(attr)
    opts = opts(attr)

    case opts["editor"] do
      nil -> infer(attr, name, opts, Map.get(features, name, values_of(opts)), component)
      hint -> hinted(hint, attr, Map.get(features, name, values_of(opts)))
    end
  end

  # THE SAME QUESTION FOR AN ELEMENT NOBODY DECLARED. `widget/3` reads a kit's own attribute — its
  # type, its `values`, its `editor` hint. A `<img src="…">` dropped on the page has none of that:
  # it is raw HTML, so the Attributes list drew a text box for everything, and the media library the
  # editor already ships was reachable from a kit component's `image_url` and from nowhere else.
  #
  # What a raw attribute DOES carry is the tag it sits on, and that is enough to tell the two `src`
  # apart: on a picture it is a file somebody uploaded, on an `<iframe>` it is an address. Guessing
  # from the name alone cannot do that, which is why this is a separate question and not a flag.
  @media_tags ~w(img video audio source embed track)

  @media_attrs ~w(src poster srcset)

  @url_attrs ~w(href src action formaction cite data ping)

  @doc """
  The control a RAW HTML attribute deserves, decided from the tag it is written on.

  `element_widget("img", "src")` is a picture chosen from the library; `element_widget("iframe",
  "src")` is an address typed by hand. Anything this has no opinion about falls through to the name
  heuristics `widget/3` uses, and then to a text box.
  """
  @spec element_widget(String.t() | nil, String.t()) :: :media | :url | :color | :text
  def element_widget(tag, name) when is_binary(name) do
    cond do
      tag in @media_tags and name in @media_attrs -> :media
      name in @url_attrs -> :url
      named?(name, @colour_names) -> :color
      true -> :text
    end
  end

  def element_widget(_tag, _name), do: :text

  @editors ~w(color icon media url number toggle textarea select columns collection text)

  @doc """
  Every value a kit may put in `opts.editor`, so it can be read rather than guessed at.

  Anything outside this list is not an error — it degrades to inference — but it is also not doing
  anything, which is worth being able to check for.
  """
  @spec editors() :: [String.t()]
  def editors, do: @editors

  defp hinted("color", _attr, _values), do: :color
  defp hinted("url", _attr, _values), do: :url
  defp hinted("icon", _attr, _values), do: :icon
  defp hinted("media", _attr, _values), do: :media
  defp hinted("textarea", _attr, _values), do: :textarea
  defp hinted("select", _attr, values), do: select_or_segmented(values)

  # A NUMBER THE KIT DECLARES RATHER THAN ONE WE RECOGNISE. Inference only reaches `number/1` when
  # the attribute's TYPE is numeric, which leaves a kit that models a count or a delay as a string —
  # a legitimate choice, `"200"` for a duration — typing into a text box while its own bundle said
  # `min`, `max` and `step`. The hint is the kit overruling the type, which is the point of hints.
  defp hinted("number", attr, _values), do: number(opts(attr))

  # And the two booleans, for the same reason: a kit that spells its flag `"true"`/`"false"` as a
  # string still means a switch.
  defp hinted("toggle", _attr, _values), do: :toggle

  # A ROW OF SHAPES, not a word to spell. The kit says how many columns it can lay out; this says
  # draw them rather than ask for the answer in prose.
  defp hinted("columns", _attr, values) when is_list(values) and values != [],
    do: {:columns, values}

  # An explicit `text` is the kit overruling a guess this module would otherwise make — an attribute
  # called `icon` that holds something else, a `color` that is prose. Without this clause it fell to
  # the heuristics below and the override did nothing, which is the one thing a hint must never do.
  defp hinted("collection", attr, _values), do: {:collection, collection_kind(attr)}

  defp hinted("text", _attr, _values), do: :text

  # An UNKNOWN hint is not an instruction, so it degrades to inference rather than to a text box: a
  # bundle written against a later version of this editor should lose the refinement, not the widget.
  defp hinted(_hint, attr, values), do: infer(attr, name(attr), opts(attr), values, nil)

  defp infer(attr, name, opts, values, component) do
    cond do
      value_type(attr) == "boolean" -> :toggle
      type(attr) == "global" -> :global
      type(attr) == "struct" -> {:struct, field(attr, "struct_name")}
      icon_map?(attr) -> :icon
      # A LIST IS NOT A LINE OF TEXT. `chelekom-filterable-gallery` keeps its whole content in two
      # list attributes, and a one-line box wrote what was typed into it as a STRING — so the
      # component, which maps over them, raised the moment anything was entered. The one control
      # that cannot be wrong here is the one that knows it is holding a collection.
      collection?(attr) -> {:collection, collection_kind(attr)}
      columns?(name, values) -> {:columns, values}
      is_list(values) and values != [] -> select_or_segmented(values)
      value_type(attr) in @numbers -> number(opts)
      styling?(name) -> :text
      named?(name, @colour_names) -> :color
      named?(name, @icon_names) -> :icon
      icon_component?(component, name) -> :icon
      # Media before URL: `image_url` is a picture the author picks from the library, not a link
      # they type, even though both names contain "url".
      named?(name, @media_names) -> :media
      named?(name, @url_names) -> :url
      long_doc?(attr) -> :textarea
      true -> :text
    end
  end

  @doc """
  Whether an attribute holds a collection rather than one value: one declared a list, a keyword
  list or a map, or one declared `any` whose default is a list (`value_type/1`).

  A map under `any` is not offered the list editor: it is read and written as pairs, and the
  attributes holding one (a chart's options, a query's parameters) are set in code.
  """
  @spec collection?(map()) :: boolean()
  def collection?(attr), do: type(attr) in @collections or value_type(attr) == "list"

  defp collection_kind(attr) do
    case type(attr) do
      declared when declared in @collections -> declared
      _any -> value_type(attr)
    end
  end

  # A CLASS IS A CLASS, WHATEVER IT IS A CLASS FOR. `named?/2` matches on whole words, so
  # `icon_class` reads as an icon, `image_class` as a picture and `link_class` as an address — each
  # drawing a picker that would write a glyph name or a URL into a CSS class. The kit spares its own
  # top-level attributes by declaring `"editor": "text"` on them and says nothing about the ones
  # inside a slot: twenty-three of those, on a carousel's slide, an accordion's item, a blockquote's
  # caption.
  #
  # Which is a kit telling this module something it can work out for itself. The LAST segment is what
  # a compound name is about, and a name about a class is not about the thing it styles.
  defp styling?(name) when is_binary(name),
    do: name |> String.split(["_", "-"]) |> List.last() == "class"

  defp styling?(_name), do: false

  # A COLUMN COUNT IS A PICTURE. Matched on the WHOLE name, not on parts: `named?/2` splits on `_`
  # and `-`, so a bare `cols` would also catch `auto_cols`, which sets the size of implicitly created
  # tracks and has nothing to draw.
  @column_names ~w(cols columns grid_cols)

  defp columns?(name, values),
    do: name in @column_names and is_list(values) and values != []

  # The ONE component that is nothing but an icon calls its attribute `name`, so the name list above
  # cannot see it: `chelekom-icon` declares `attr :name` and its whole template is
  # `<span class={[@name, @class]} />`. That attribute got a bare text box, and the author had to
  # know `hero-exclamation-triangle` by heart — on the one control where a picker matters most.
  #
  # The right long-term answer is the kit saying so itself, and `opts["editor"] == "icon"` above is
  # how: it is checked before any of this, so a bundle that declares it never reaches these guesses.
  # This is what makes an install that has not re-exported behave correctly today.
  defp icon_component?(component, "name") when not is_nil(component) do
    component |> name() |> to_string() |> String.ends_with?("-icon")
  end

  defp icon_component?(_component, _name), do: false

  # A handful of short options reads better as a segmented control than as a dropdown — the
  # prototype's rule, and the reason `variant` gets pills while `color` (20+ values) gets a select.
  defp select_or_segmented(values) do
    short? =
      length(values) <= @segmented_limit and
        Enum.all?(values, &(String.length(to_string(&1)) <= @segmented_value_length))

    case short? do
      true -> {:segmented, values}
      false -> {:select, values}
    end
  end

  defp number(opts), do: {:number, opts["min"], opts["max"], opts["step"] || 1}

  # `nil` inside a value list means "unset", which the control already expresses with its own
  # "(default)" option — four of the kit's attrs ship a JSON `null` there, and it rendered as a
  # blank, unlabelled pill that wrote an empty string when clicked.
  defp values_of(opts) do
    case opts["values"] do
      values when is_list(values) -> Enum.reject(values, &is_nil/1)
      _other -> []
    end
  end

  # Matched on whole words so `colorful` does not read as a colour and `href` does not match `ref`.
  defp named?(nil, _names), do: false

  defp named?(name, names) do
    parts = String.split(name, ["_", "-"])
    name in names or Enum.any?(parts, &(&1 in names))
  end

  defp long_doc?(attr) do
    case doc(attr) do
      doc when is_binary(doc) -> String.length(doc) > @textarea_doc_length
      _other -> false
    end
  end

  @doc """
  The `@rest` keys a component's own body actually reads, as offerable attributes.

  ## Why these are invisible otherwise

  A kit declares the switch it supports through `attr :rest, :global, include: ~w(animated)`, and
  two things drop it on the way here: the bundle exporter does not carry an `include:` list, and
  `grouped/1` pulls `global` attributes out entirely — they are the collapsed "HTML attributes"
  editor, not properties. So a skeleton's `animated` had nowhere to appear, and neither did fifteen
  other components' switches: `pinging` and `circle` on a badge and three buttons, `disabled` on six
  field components, four on the pagination.

  ## Derived from the body, not from a list

  What the component CONSULTS is the honest answer to "what does it support", and it needs no kit
  change and no re-export: `@rest[:animated]` in the template is the component saying it reads that
  key. A name the body never mentions is not offered, so this cannot invent a control that does
  nothing.

  The TYPE comes from the use site for the same reason. `@rest[:x] && "class"` is a flag and gets a
  toggle; `@rest[:x] || "fallback"` or `attr={@rest[:x]}` is a value and gets a text box — which is
  what keeps a blockquote's `cite` a URL and a card's `role` a word rather than two switches.

  Anything the component also declares properly wins: those are subtracted, so nothing appears
  twice.
  """
  @spec rest_attrs(map()) :: [map()]
  def rest_attrs(component) do
    declared = component |> attrs() |> Enum.map(&name/1) |> MapSet.new()
    body = template_of(component)

    ~r/@rest\[:([a-z_][a-z0-9_]*)\]/
    |> Regex.scan(body)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> Enum.map(&%{"name" => &1, "type" => rest_type(body, &1), "opts" => %{"rest?" => true}})
  end

  # A VALUE IS ONE THAT REACHES THE PAGE. `cite={@rest[:cite] && @rest[:cite]}` puts the thing itself
  # into an attribute, so it needs a box to type in. Everything else only ever asks whether the key
  # is THERE — `:if={@rest[:show_edges]}`, `is_nil(@rest[:hide_icon])`,
  # `default_classes(@rest[:pinging])` — and a switch is the honest control for that.
  #
  # The `&&` is not the tell: `cite` uses one to guard its own value and `grouped` uses one to turn a
  # class on. What separates them is whether an ATTRIBUTE is assigned straight from the read. `:if=`
  # is excluded by the lookbehind — it is a condition wearing an attribute's shape.
  # AND HTML'S OWN BOOLEAN ATTRIBUTES ARE BOOLEAN WHEREVER THEY LAND. A field writes
  # `disabled={@rest[:disabled]}`, which is an assignment by the rule above and a switch by every
  # other measure — the attribute is present or it is not, and there is no string to type into it.
  @boolean_attributes ~w(disabled checked readonly required hidden open selected multiple autofocus)

  defp rest_type(_body, key) when key in @boolean_attributes, do: "boolean"

  defp rest_type(body, key) do
    assigned = ~r/(?<![:\w])[a-z][a-z0-9_-]*=\{\s*@rest\[:#{Regex.escape(key)}\]/

    case Regex.match?(assigned, body) do
      true -> "string"
      false -> "boolean"
    end
  end

  defp template_of(%{template: template}) when is_binary(template), do: template
  defp template_of(%{"template" => template}) when is_binary(template), do: template
  defp template_of(_component), do: ""

  @doc """
  Groups a component's attributes into the panel's sections. Anything that matches no group heading
  lands in "Properties", and `global` attributes are pulled out entirely — they are the collapsed
  "HTML attributes" editor, not a property.
  """
  @spec grouped(map()) :: [{String.t(), [map()]}]
  def grouped(component) do
    (attrs(component) ++ rest_attrs(component))
    |> Enum.reject(&(type(&1) == "global"))
    |> Enum.group_by(&group_of/1)
    |> Enum.sort_by(fn {group, _attrs} -> group_order(group) end)
    |> Enum.map(fn {group, attrs} -> {group, Enum.sort_by(attrs, &rank/1)} end)
  end

  defp group_of(attr) do
    name = name(attr) || ""

    Enum.find_value(@groups, gettext_noop("Properties"), fn {group, keys} ->
      named?(name, keys) && group
    end)
  end

  # Exact names only: `font_weight` is not `weight`, and a prefix match would drag half a component's
  # surface to the top of its section.
  defp rank(attr) do
    name = name(attr) || ""
    {Enum.find_index(@lead, &(&1 == name)) || length(@lead), name}
  end

  defp group_order(group) do
    Enum.find_index(@group_order, &(&1 == group)) || length(@group_order)
  end

  @doc "The section headings, in panel order."
  @spec groups() :: [String.t()]
  def groups, do: @group_order

  @type control :: %{
          key: String.t(),
          attr: String.t() | nil,
          label: String.t(),
          widget: term(),
          help: String.t()
        }

  @form_controls [
    %{
      key: "seed",
      attr: nil,
      label: gettext_noop("Form name"),
      widget: :text,
      help: gettext_noop("What this form is called.")
    },
    %{
      key: "success",
      attr: "data-success",
      label: gettext_noop("Success message"),
      widget: :text,
      placeholder: gettext_noop("Sent. Thank you."),
      help: gettext_noop("What the visitor is told once it sends.")
    }
  ]

  @validation_controls [
    %{
      key: "required",
      attr: "required",
      label: gettext_noop("Required"),
      widget: :toggle,
      help: gettext_noop("It cannot be left blank.")
    },
    %{
      key: "minlength",
      attr: "minlength",
      label: gettext_noop("Min length"),
      widget: {:number, 0, nil, 1},
      help: gettext_noop("Fewest characters accepted.")
    },
    %{
      key: "maxlength",
      attr: "maxlength",
      label: gettext_noop("Max length"),
      widget: {:number, 0, nil, 1},
      help: gettext_noop("Most characters accepted.")
    },
    %{
      key: "min",
      attr: "min",
      label: gettext_noop("Min"),
      widget: {:number, nil, nil, 1},
      help: gettext_noop("Lowest number accepted.")
    },
    %{
      key: "max",
      attr: "max",
      label: gettext_noop("Max"),
      widget: {:number, nil, nil, 1},
      help: gettext_noop("Highest number accepted.")
    },
    %{
      key: "pattern",
      attr: "pattern",
      label: gettext_noop("Pattern"),
      widget: :text,
      help: gettext_noop("A regular expression the value has to match.")
    },
    %{
      key: "format",
      attr: "data-format",
      label: gettext_noop("Format"),
      widget: {:segmented, ~w(email url)},
      help: gettext_noop("A shape HTML has no attribute for. Neither pill means no format check.")
    },
    %{
      key: "confirms",
      attr: "data-confirms",
      label: gettext_noop("Confirms"),
      widget: :text,
      help: gettext_noop("The key of the field this one has to match.")
    }
  ]

  # The form's own options a Phoenix form tag takes, each offered only where the form node forwards
  # its attribute (`phoenix_form_controls/2`).
  @phoenix_form_controls [
    %{
      key: "novalidate",
      attr: "novalidate",
      label: gettext_noop("Skip the browser's checks"),
      widget: :toggle,
      help:
        gettext_noop(
          "Off: the browser checks each field before it sends, and the server checks again. On: only the server checks."
        )
    },
    %{
      key: "autocomplete",
      attr: "autocomplete",
      label: gettext_noop("Autofill"),
      widget: {:choices, [{"on", gettext_noop("On")}, {"off", gettext_noop("Off")}]},
      default: "on",
      help: gettext_noop("Whether the browser may fill in what it remembers.")
    },
    %{
      key: "auto_recover",
      attr: "phx-auto-recover",
      label: gettext_noop("Keep typed values after reconnect"),
      widget: :toggle,
      off: "ignore",
      help: gettext_noop("If the connection drops for a moment, what they typed is put back.")
    },
    %{
      key: "target",
      attr: "target",
      label: gettext_noop("Open result in"),
      widget: {:choices, [{"", gettext_noop("Same tab")}, {"_blank", gettext_noop("New tab")}]},
      default: "",
      help: gettext_noop("Where the page it sends to opens.")
    }
  ]

  # A field's own options inside a form, each offered where the field forwards its attribute
  # (`field_controls/3`).
  @field_controls [
    %{
      key: "debounce",
      attr: "phx-debounce",
      id: "pb-field-debounce",
      label: gettext_noop("Check while typing"),
      widget:
        {:choices_or_number,
         [
           {"blur", gettext_noop("When they leave the field")},
           {"300", gettext_noop("As they type")}
         ]},
      shown: "300",
      help:
        gettext_noop(
          "When what they type is checked. A number waits that many thousandths of a second after they stop typing."
        )
    },
    %{
      key: "throttle",
      attr: "phx-throttle",
      label: gettext_noop("Limit how often it checks"),
      widget: {:number, 0, nil, 50},
      help:
        gettext_noop(
          "Empty means no limit. A number checks at most once in that many thousandths of a second."
        )
    },
    %{
      key: "field_autocomplete",
      attr: "autocomplete",
      label: gettext_noop("Autofill"),
      widget: :text,
      help:
        gettext_noop(
          "What the browser may fill in from what it remembers. Empty uses the default shown."
        )
    },
    %{
      key: "placeholder",
      attr: "placeholder",
      label: gettext_noop("Placeholder"),
      widget: :text,
      help: gettext_noop("Grey words shown in the field while it is empty.")
    },
    %{
      key: "readonly",
      attr: "readonly",
      label: gettext_noop("Read only"),
      widget: :toggle,
      help: gettext_noop("They can see what is in it but not change it.")
    },
    %{
      key: "disabled",
      attr: "disabled",
      label: gettext_noop("Disabled"),
      widget: :toggle,
      help: gettext_noop("Greyed out, and not sent with the form.")
    },
    %{
      key: "autofocus",
      attr: "autofocus",
      label: gettext_noop("Focus first"),
      widget: :toggle,
      help: gettext_noop("The cursor starts in this field when the page opens.")
    }
  ]

  # The field bindings that name an event, for authors who write the code that answers it.
  @field_code_controls [
    %{
      key: "on_focus",
      attr: "phx-focus",
      label: gettext_noop("When it gets focus"),
      widget: :text,
      help: gettext_noop("phx-focus: the event name your code answers.")
    },
    %{
      key: "on_blur",
      attr: "phx-blur",
      label: gettext_noop("When it loses focus"),
      widget: :text,
      help: gettext_noop("phx-blur: the event name your code answers.")
    },
    %{
      key: "on_keyup",
      attr: "phx-keyup",
      label: gettext_noop("When a key is released"),
      widget: :text,
      help: gettext_noop("phx-keyup: the event name your code answers.")
    }
  ]

  # A Send button's own options (`send_controls/3`).
  @send_controls [
    %{
      key: "disable_with",
      attr: "phx-disable-with",
      id: "pb-send-disable-with",
      label: gettext_noop("Text while sending"),
      widget: :text,
      help:
        gettext_noop(
          "What the button says while the form is being sent. Empty keeps its own words."
        )
    },
    %{
      key: "button_type",
      attr: "type",
      label: gettext_noop("Button type"),
      widget:
        {:choices,
         [{"submit", gettext_noop("Sends the form")}, {"button", gettext_noop("Does not send")}]},
      help: gettext_noop("A button that does not send is for something else on the page.")
    }
  ]

  # The autofill a field gets when it names none, by the kind of field it is.
  @autofill %{
    "email" => "email",
    "tel" => "tel",
    "url" => "url",
    "password" => "current-password"
  }

  # What "Send to another address" writes, all four together.
  @address_attrs ~w(action method csrf_token phx-trigger-action)

  # The names a working form carries that only Form name changes.
  @form_names ~w(id as for phx-change phx-submit :let)

  @doc """
  The two form sections, as `builder:inspector:sections` descriptors carrying their controls.

  Sorted ahead of the styling groups, so a form's own name is near the top of the panel rather than
  under the styling an author reaches for later. The panel draws them above the breakpoint strip:
  every control here writes a plain attribute, which has one value for the whole page.
  """
  @spec form_sections() :: [Descriptor.t()]
  def form_sections do
    [
      section("form", gettext_noop("Form"), 35, form_controls()),
      section("validation", gettext_noop("Validation"), 45, validation_controls())
    ]
  end

  defp section(key, label, priority, controls) do
    {:ok, built} =
      Descriptor.builder(%{
        key: key,
        kind: :inspector_section,
        label: label,
        priority: priority,
        config: %{"controls" => controls}
      })

    built
  end

  @doc "The Form section's controls, in the order the panel draws them."
  @spec form_controls() :: [control()]
  def form_controls, do: @form_controls

  @doc """
  The Form section's controls for the working form `node`: `form_controls/0`, then How it works
  where the form can work as they type (`FormPlacement.as_typed_offered?/2`). `session` is the
  editing session.
  """
  @spec form_controls(Node.t(), map()) :: [control()]
  def form_controls(node, session) do
    case FormPlacement.as_typed_offered?(session, node) do
      true -> @form_controls ++ [how_control(PageForms.as_typed?(node))]
      false -> @form_controls
    end
  end

  # How a working form sends; its words follow the choice the form carries now.
  defp how_control(typing?),
    do: %{
      key: "how",
      attr: nil,
      id: "pb-form-how",
      label: gettext("How it works"),
      widget:
        {:choices,
         [
           {"send", gettext("When they press Send")},
           {"typing", gettext("As they type (no Send button)")}
         ]},
      stacked: true,
      help: how_help(typing?)
    }

  defp how_help(true),
    do:
      gettext(
        "There is no Send button. What they type is checked as they type. Pressing Enter never reloads the page, and in a form with a single box it still sends."
      )

  defp how_help(false),
    do: gettext("What they type is checked as they type, and sent when they press Send.")

  @doc """
  The Form · Phoenix section's options for the form `node`: the ones whose attribute it forwards to
  the form it renders (`Fields.takes?/3`). Open result in is left out while the form sends to
  another address, which opens the result in the same tab. Every one of them with no node.
  """
  @spec phoenix_form_controls(Node.t() | nil, [map()]) :: [control()]
  def phoenix_form_controls(node \\ nil, components \\ [])

  def phoenix_form_controls(nil, _components), do: @phoenix_form_controls

  def phoenix_form_controls(node, components),
    do: Enum.filter(@phoenix_form_controls, &form_control_offered?(&1, node, components))

  defp form_control_offered?(%{key: "target"} = control, node, components),
    do: PageForms.address(node) == nil and Fields.takes?(node, control.attr, components)

  defp form_control_offered?(control, node, components),
    do: Fields.takes?(node, control.attr, components)

  @doc """
  The options of a field inside a form, each where the field forwards its attribute
  (`Fields.takes?/3`). Autofill shows its default for the field's kind (`field_autofill/2`), or
  `off` when the form it is in (`form:`) turns Autofill off. With `code_allowed?: true` the three
  field bindings that name an event come last; nobody else sees them. Every control with no node.
  """
  @spec field_controls(Node.t() | nil, [map()], keyword()) :: [control()]
  def field_controls(node \\ nil, components \\ [], opts \\ [])

  def field_controls(nil, _components, _opts), do: @field_controls ++ @field_code_controls

  def field_controls(node, components, opts) do
    (@field_controls ++ coded(Keyword.get(opts, :code_allowed?, false)))
    |> Enum.filter(&Fields.takes?(node, &1.attr, components))
    |> Enum.map(&autofilled(&1, node, components, Keyword.get(opts, :form)))
  end

  @doc "The field bindings that name an event, offered only to authors who may write its code."
  @spec field_code_controls() :: [control()]
  def field_code_controls, do: @field_code_controls

  defp coded(true), do: @field_code_controls
  defp coded(_other), do: []

  # An empty box follows the form's own Autofill when that is off.
  defp autofilled(%{key: "field_autocomplete"} = control, node, components, form) do
    default =
      case form && Node.attr_text(form, "autocomplete") do
        "off" -> "off"
        _on -> field_autofill(node, components)
      end

    Map.put(control, :placeholder, gettext("Default: %{value}", value: default))
  end

  defp autofilled(control, _node, _components, _form), do: control

  @doc """
  The autofill a field has when it names none, from the kind of field it is: `email` for an email
  field, `tel`, `url`, `current-password`, and `on` for anything else.
  """
  @spec field_autofill(Node.t(), [map()]) :: String.t()
  def field_autofill(node, components),
    do: Map.get(@autofill, field_type(node, components), "on")

  defp field_type(%Node{kind: :component} = node, components) do
    PageForms.type_word(Node.attr_text(node, "type")) ||
      node |> Fields.entry(components) |> declared_type()
  end

  defp field_type(node, _components), do: PageForms.type_word(Node.attr_text(node, "type"))

  defp declared_type(nil), do: nil

  defp declared_type(entry) do
    entry
    |> attrs()
    |> Enum.find(&(name(&1) == "type"))
    |> declared_default()
  end

  defp declared_default(nil), do: nil
  defp declared_default(attr), do: attr |> default() |> PageForms.type_word()

  @doc """
  The options of a Send button: Text while sending where the button forwards it, and Button type
  where its type is written through `type` (`type_attr`, from `Fields.type_attr/3`). `send?` is
  whether it sends its form now, what Button type shows when no type is written.
  """
  @spec send_controls(Node.t() | nil, [map()], boolean(), String.t() | nil) :: [control()]
  def send_controls(node \\ nil, components \\ [], send? \\ true, type_attr \\ "type")

  def send_controls(nil, _components, _send?, _type_attr), do: @send_controls

  def send_controls(node, components, send?, type_attr) do
    @send_controls
    |> Enum.filter(&offered?(&1, node, components, type_attr))
    |> Enum.map(&sending(&1, send?))
  end

  defp offered?(%{key: "button_type"}, _node, _components, type_attr), do: type_attr == "type"

  defp offered?(control, node, components, _type_attr),
    do: Fields.takes?(node, control.attr, components)

  defp sending(%{key: "button_type"} = control, true), do: Map.put(control, :shown, "submit")
  defp sending(%{key: "button_type"} = control, false), do: Map.put(control, :shown, "button")
  defp sending(control, _send?), do: control

  @doc """
  The names this working form carries that only Form name changes, as `{name, text}`, with `nil`
  for one it does not carry.
  """
  @spec form_names(Node.t()) :: [{String.t(), String.t() | nil}]
  def form_names(node), do: Enum.map(@form_names, &{&1, Node.attr_text(node, &1)})

  @doc """
  Every attribute the Form panel writes on a working form, so Props and Advanced leave them to it:
  the five names and `:let`, the Success message, How it works, the Form · Phoenix options, the
  four "Send to another address" writes and `multipart`.
  """
  @spec form_panel_attrs() :: [String.t()]
  def form_panel_attrs,
    do:
      @form_names ++
        ["data-success", PageForms.as_typed_attr()] ++
        Enum.map(@phoenix_form_controls, & &1.attr) ++ @address_attrs ++ ["multipart"]

  @doc "Whether the form `node` forwards all four attributes \"Send to another address\" writes."
  @spec address_takes?(Node.t(), [map()]) :: boolean()
  def address_takes?(node, components),
    do: Enum.all?(@address_attrs, &Fields.takes?(node, &1, components))

  @doc """
  The ops "Send to another address" issues for what was typed: an `https` address writes `action`,
  `method="post"`, `csrf_token={false}` and the form's `phx-trigger-action` (`Naming.trigger/1`)
  together, and removes a `target`, so the result opens in the tab it was sent from. It also turns
  `multipart` on when a file field sits inside the form in `tree` (`FormPlacement.files_ops/3`). An
  empty one removes the four. Anything else is refused with a sentence.
  """
  @spec address_ops(Tree.t(), Node.t(), String.t() | nil, [map()]) ::
          {:ok, [map()]} | {:error, String.t()}
  def address_ops(tree, %Node{id: id} = node, typed, components) do
    case address(typed) do
      :none ->
        {:ok, Enum.map(@address_attrs, &%{kind: :delete_attr, node_id: id, name: &1})}

      {:ok, url} ->
        {:ok,
         Enum.map(
           [
             {"action", {:string, url}},
             {"method", {:string, "post"}},
             {"csrf_token", {:expr, "false"}},
             node |> form_seed() |> Naming.trigger()
           ],
           &op(id, &1)
         ) ++ untargeted(node) ++ FormPlacement.files_ops(tree, node, components)}

      :error ->
        {:error, gettext("Use a full web address that starts with https://")}
    end
  end

  # LiveView leaves the page it posts from, so a result opened in a new tab would leave this one
  # dead.
  defp untargeted(%Node{id: id} = node) do
    case Node.attr(node, "target") do
      nil -> []
      _set -> [%{kind: :delete_attr, node_id: id, name: "target"}]
    end
  end

  defp address(typed) when is_binary(typed), do: typed |> String.trim() |> checked_address()
  defp address(_typed), do: :none

  defp checked_address(""), do: :none

  defp checked_address(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, url}
      _other -> :error
    end
  end

  @doc """
  Whether a file field sits inside `form`: an `<input type="file">`, a `live_file_input`, or a
  component whose markup renders one.
  """
  @spec holds_file_field?(Tree.t(), Node.t(), [map()]) :: boolean()
  def holds_file_field?(tree, %Node{id: id}, components) do
    tree
    |> Tree.descendant_ids(id)
    |> Enum.any?(&(tree |> Tree.get(&1) |> file_field?(components)))
  end

  defp file_field?(%Node{kind: :tag, tag: "input"} = node, _components),
    do: PageForms.type_word(Node.attr_text(node, "type")) == "file"

  defp file_field?(%Node{kind: :component} = node, components) do
    Node.component_name(node) == "live_file_input" or
      node |> Fields.entry(components) |> renders_file?()
  end

  defp file_field?(_node, _components), do: false

  defp renders_file?(nil), do: false

  defp renders_file?(entry) do
    markup = template(entry)
    String.contains?(markup, "live_file_input") or Regex.match?(~r/type=["']file["']/i, markup)
  end

  @doc "The Validation section's controls, in the order the panel draws them."
  @spec validation_controls() :: [control()]
  def validation_controls, do: @validation_controls

  @doc """
  What this node is as a form, for the Inspector:

    * `:page_form` - a working form (`PageForms.form?/1`): Phoenix's `<.form>` or a kit wrapper
      wired to the page;
    * `{:idle, hands?}` - a form that does not work yet; `hands?` is whether it can be made one
      where it stands (`Fields.hands_form?/2`), which a raw `<form>` cannot;
    * `:none` - not a form.
  """
  @spec form_state(Node.t() | nil, [map()]) :: :page_form | {:idle, boolean()} | :none
  def form_state(%Node{} = node, components) do
    cond do
      PageForms.form?(node) ->
        :page_form

      Fields.form_node?(node, Fields.roles([node], components)) ->
        {:idle, hands?(node, components)}

      true ->
        :none
    end
  end

  def form_state(_node, _components), do: :none

  defp hands?(node, components), do: Fields.hands_form?(node, components)

  @doc "Whether the Form section applies to this node — it names a page assign to keep its state in."
  @spec form_node?(Node.t()) :: boolean()
  def form_node?(node), do: PageForms.form?(node)

  @doc """
  Whether the Validation section applies — a node bound to a key of the form it sits inside.

  An unbound node in a form has no rules to carry, and a bound node with no form above it has nothing
  to validate it: `MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacement` wraps that one on the
  way in and the audit rail reports the ones that arrived some other way.
  """
  @spec validated_node?(Tree.t(), Node.t()) :: boolean()
  def validated_node?(tree, node), do: bound_key(tree, node) != nil

  @doc "The key this node binds in the form it sits inside, or `nil`."
  @spec bound_key(Tree.t(), Node.t()) :: atom() | nil
  def bound_key(tree, node), do: tree |> owning_form(node) |> key_of(node)

  defp key_of(nil, _node), do: nil
  defp key_of(form, node), do: PageForms.bound_key(node, PageForms.let_var(form))

  @doc """
  The part this node plays in a form, for the Inspector's header: `:form`, `:field`, `:submit` (a
  button that sends the form it is in), `:not_submit` (a button in a form that does not send it),
  `:button` (a button outside every form, or one whose computed type cannot say) or `nil`.

  `editor` is anything carrying the document's `tree` and the palette's `components`.
  """
  @spec form_part(map(), Node.t() | nil) ::
          :form | :field | :submit | :not_submit | :button | nil
  def form_part(%{tree: %Tree{} = tree, components: components}, %Node{} = node) do
    ancestors = Tree.ancestors(tree, node.id)
    roles = Fields.roles([node | ancestors], components)
    rules = Fields.submit_rules(roles, components)

    cond do
      Fields.form_node?(node, roles) -> :form
      Fields.field_node?(node, roles) -> :field
      not Fields.button_node?(node, roles, rules) -> nil
      not Enum.any?(ancestors, &Fields.form_node?(&1, roles)) -> :button
      Fields.submit_node?(node, roles, rules) -> :submit
      Fields.type_unread?(node, roles, rules) -> :button
      true -> :not_submit
    end
  end

  def form_part(_editor, _node), do: nil

  @doc "The nearest form above this node, or `nil`."
  @spec owning_form(Tree.t(), Node.t()) :: Node.t() | nil
  def owning_form(tree, %{id: id}), do: tree |> Tree.ancestors(id) |> Enum.find(&form_node?/1)
  def owning_form(_tree, _node), do: nil

  @doc "The seed this form is currently using, or `nil` when it names no params."
  @spec form_seed(Node.t()) :: String.t() | nil
  def form_seed(node), do: PageForms.param_name(node)

  @doc """
  The ops a rename issues, ready for an editor to apply as one batch,
  with `token` inside both event names (`nil` writes the untagged names).

  All five in one batch, because five separate ops would be five undo steps and four of them would
  leave the page in a state where the form's id, params, assign and events disagree.
  """
  @spec rename_ops(Node.t(), String.t() | nil, String.t() | nil) :: [map()]
  def rename_ops(%{id: id} = node, seed, token),
    do: node |> Naming.names_for(seed, token) |> Enum.map(&op(id, &1))

  @doc """
  The token a rename of this form writes.

    * a tagged form keeps its token, so its stored handlers are still found by it;
    * an untagged form whose stored handlers answered the `:origin` form's event names by exact name
      gets `nil`, the untagged names, so typing the old name back reattaches them. With
      `code_allowed?: true` it gets a fresh token instead, and `retagged/3` names the handlers that
      move to it;
    * any other untagged form gets a fresh token.

  `events` are the page's Events-tab entries.

  ## Options

    * `:origin` - the form as it was when this rename began. Defaults to `node`.
    * `:code_allowed?` - whether the author may write the page's code. Defaults to `false`.
  """
  @spec rename_token(Tree.t(), Node.t(), [map()], keyword()) :: String.t() | nil
  def rename_token(tree, node, events, opts \\ []) do
    origin = Keyword.get(opts, :origin) || node

    node
    |> Naming.form_token()
    |> renamed(tree, bound_handlers(origin, events), Keyword.get(opts, :code_allowed?, false))
  end

  defp renamed(nil, tree, bound, code_allowed?),
    do: untagged(bound != [] and code_allowed? != true, tree)

  defp renamed(token, _tree, _bound, _code_allowed?), do: token

  defp untagged(true, _tree), do: nil
  defp untagged(false, tree), do: Naming.mint_token(tree)

  @doc """
  The stored handler names a rename moves onto `token`: each untagged event name of `origin` that a
  stored handler answers by exact name, mapped to the tagged name of the same kind. Empty for a
  `nil` token. `MishkaCmsCore.Runtime.Authoring.PageForms.follow/3` applies it.
  """
  @spec retagged(Node.t(), String.t() | nil, [map()]) :: %{String.t() => String.t()}
  def retagged(_origin, nil, _events), do: %{}

  def retagged(origin, token, events) do
    bound = bound_handlers(origin, events)
    seed = origin |> form_seed() |> Naming.seed()

    for {attr, kind} <- [{"phx-change", :validate}, {"phx-submit", :submit}],
        name = Node.attr_text(origin, attr),
        name in bound and Naming.event_key(name) == nil,
        into: %{},
        do: {name, Naming.event(seed, token, kind)}
  end

  defp op(id, {name, {kind, value}}),
    do: %{kind: :set_attr, node_id: id, name: name, value: value, value_kind: kind}

  @doc """
  Why this seed cannot be used on this form, or `nil`.

  Answered against the MINTED name rather than the typed one, so `My Form` and `my_form` are refused
  as the same answer they would both become.
  """
  @spec seed_refusal(Tree.t(), Node.t(), String.t() | nil) :: String.t() | nil
  def seed_refusal(tree, %{id: id}, typed), do: refusal(tree, id, Naming.seed(typed))

  defp refusal(tree, id, minted) do
    tree
    |> Naming.seeds()
    |> Enum.find(fn {other, seed} -> other != id and Naming.seed(seed) == minted end)
    |> taken(minted)
  end

  defp taken(nil, _minted), do: nil

  defp taken(_found, minted),
    do: gettext("Another form on this page is already called \"%{name}\".", name: minted)

  @doc """
  What a rename would break, or `nil`.

  `node` is the form as it was when the rename began, and `code` is the page's stored code,
  `%{events: [...], infos: [...], helpers: [...]}`.

    * An untagged form names the handlers that answer its event names exactly: they stop. With
      `code_allowed?` they move with the form instead (`retagged/3`), so they raise nothing.
    * Any form: when a stored entry mentions the form's seed (`:contact_form`, `:contact` or
      `"contact"`), a rename changes `as` and `for` under it.
    * A tagged form's own handlers follow it by token, so they alone raise nothing.
  """
  @spec rename_warning(Node.t(), map(), boolean()) :: String.t() | nil
  def rename_warning(node, code, code_allowed? \\ false) do
    node
    |> Naming.form_token()
    |> exact_handlers(node, Map.get(code, :events, []), code_allowed?)
    |> warning(mentions_seed?(node, code))
  end

  defp exact_handlers(nil, node, events, false), do: bound_handlers(node, events)
  defp exact_handlers(_token, _node, _events, _code_allowed?), do: []

  defp mentions_seed?(node, code) do
    node
    |> form_seed()
    |> seed_pattern()
    |> mentioned?(code)
  end

  defp seed_pattern(nil), do: nil

  defp seed_pattern(seed) do
    escaped = Regex.escape(seed)
    Regex.compile!(~s/:#{escaped}(_form)?(?![A-Za-z0-9_?!@])|"#{escaped}"/)
  end

  defp mentioned?(nil, _code), do: false

  defp mentioned?(pattern, code) do
    [:events, :infos, :state, :helpers]
    |> Enum.flat_map(&Map.get(code, &1, []))
    |> Enum.any?(&Regex.match?(pattern, to_string(entry_code(&1))))
  end

  defp entry_code(%{code: code}), do: code
  defp entry_code(%{"code" => code}), do: code
  defp entry_code(_entry), do: nil

  @doc """
  What a form does, in two sentences for someone who does not write code: what happens while a
  visitor types, and where it goes when they press Send, or as they type when the form has no Send
  button (`PageForms.as_typed?/1`). The second reads the audit's own check
  (`FormChecks.receiver/2`), so it never says more than `form-no-destination` does. `record` is the
  page, read for its stored handlers. No event name is in either sentence.
  """
  @spec form_story(Node.t(), map() | nil) :: {String.t(), String.t()}
  def form_story(node, record) do
    typing =
      node
      |> PageForms.handlers(stored_events(record))
      |> Enum.find(&(&1.kind == :validate))
      |> typing()

    {typing, story_sending(PageForms.as_typed?(node), FormChecks.receiver(node, record))}
  end

  defp stored_events(%{events: events}) when is_list(events), do: events
  defp stored_events(_record), do: []

  defp typing(nil),
    do: gettext("While a visitor types: nothing is checked until they press Send.")

  defp typing(%{custom?: true}), do: gettext("While a visitor types: your own code runs.")
  defp typing(%{custom?: false}), do: gettext("While a visitor types: the fields are checked.")

  defp story_sending(true, :code), do: gettext("What they type: your own code receives it.")

  defp story_sending(true, :plugin),
    do: gettext("What they type: an installed plugin receives it.")

  defp story_sending(true, :action),
    do: gettext("What they type: it goes to the web address the form names.")

  defp story_sending(true, :none),
    do: gettext("What they type: nothing stores or sends what visitors type yet.")

  defp story_sending(false, :code),
    do: gettext("When they press Send: your own code receives it.")

  defp story_sending(false, :plugin),
    do: gettext("When they press Send: an installed plugin receives it.")

  defp story_sending(false, :action),
    do: gettext("When they press Send: it goes to the web address the form names.")

  defp story_sending(false, :none),
    do: gettext("When they press Send: nothing stores or sends what visitors type yet.")

  @doc "The Events-tab handlers this form's `phx-change` and `phx-submit` currently point at."
  @spec bound_handlers(Node.t(), [map()]) :: [String.t()]
  def bound_handlers(node, events) do
    declared = events |> Enum.map(&event_name/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    ~w(phx-change phx-submit)
    |> Enum.map(&Node.attr_text(node, &1))
    |> Enum.filter(&MapSet.member?(declared, &1))
  end

  defp event_name(%{name: name}), do: name
  defp event_name(%{"name" => name}), do: name
  defp event_name(_event), do: nil

  defp warning([], false), do: nil

  defp warning([], true),
    do:
      gettext("Code someone wrote for this form stops running if you rename it. Ask them first.")

  defp warning([first, second], _mentioned?),
    do:
      gettext("%{first} and %{second} on the Handlers tab will stop being called.",
        first: first,
        second: second
      )

  defp warning(names, _mentioned?),
    do:
      gettext("%{names} on the Handlers tab will stop being called.",
        names: Enum.join(names, " and ")
      )

  @doc """
  What a control currently reads on this node — `true`/`false` for a switch, the attribute's text
  otherwise, and the seed for the one control that is not an attribute.
  """
  @spec rule_value(Node.t(), control()) :: String.t() | boolean() | nil
  def rule_value(node, %{widget: :toggle, attr: attr, off: off}),
    do: Node.attr_text(node, attr) != off

  def rule_value(node, %{widget: :toggle, attr: attr}), do: Node.attr(node, attr) != nil

  def rule_value(node, %{attr: attr, default: default}) when is_binary(attr),
    do: Node.attr_text(node, attr) || default

  def rule_value(node, %{attr: attr, shown: shown}) when is_binary(attr),
    do: Node.attr_text(node, attr) || shown

  def rule_value(node, %{attr: attr}) when is_binary(attr), do: Node.attr_text(node, attr)
  def rule_value(node, %{key: "seed"}), do: form_seed(node)
  def rule_value(node, %{key: "how"}), do: (PageForms.as_typed?(node) && "typing") || "send"
  def rule_value(_node, _control), do: nil

  @doc """
  The op (`MishkaCmsCore.Runtime.Authoring.Op`) a control issues for `value`, ready for an editor
  to apply.

  Turning a rule off DELETES its attribute rather than writing an empty one: `required=""` is still
  required to a browser, and `minlength=""` reads back as no rule on the server, so an emptied
  control that only wrote would leave the two disagreeing.

  Every control here writes one attribute, so the Form section's seed is not one of them: it writes
  five at once and goes through `rename_ops/2` instead. A caller that dispatches the whole of
  `form_controls/0` through here has to send the seed the other way, and gets a `FunctionClauseError`
  naming the control if it does not.
  """
  @spec rule_op(Node.t(), control(), String.t() | boolean() | nil) :: map()
  def rule_op(%{id: id}, %{widget: :toggle, attr: attr, off: off}, value),
    do: kept(id, attr, on?(value), off)

  def rule_op(%{id: id}, %{widget: :toggle, attr: attr}, value),
    do: switched(id, attr, on?(value))

  def rule_op(%{id: id}, %{attr: attr, default: default}, value) when is_binary(attr),
    do: written(id, attr, value |> presence() |> unless_default(default))

  def rule_op(%{id: id}, %{attr: attr}, value) when is_binary(attr),
    do: written(id, attr, presence(value))

  defp switched(id, attr, true),
    do: %{kind: :set_attr, node_id: id, name: attr, value: "", value_kind: :boolean}

  defp switched(id, attr, false), do: %{kind: :delete_attr, node_id: id, name: attr}

  # A switch that is on by default: on removes the attribute, off writes the value that turns it off.
  defp kept(id, attr, true, _off), do: %{kind: :delete_attr, node_id: id, name: attr}
  defp kept(id, attr, false, off), do: written(id, attr, off)

  # The default is what an absent attribute already means, so choosing it removes the attribute.
  defp unless_default(value, value), do: nil
  defp unless_default(value, _default), do: value

  defp written(id, attr, nil), do: %{kind: :delete_attr, node_id: id, name: attr}

  defp written(id, attr, value),
    do: %{kind: :set_attr, node_id: id, name: attr, value: value, value_kind: :string}

  defp on?(value) when is_boolean(value), do: value
  defp on?(value), do: value in ["true", "on", "1"]

  defp presence(value) when is_binary(value), do: value |> String.trim() |> filled()
  defp presence(_other), do: nil

  defp filled(""), do: nil
  defp filled(value), do: value

  defp field(attr, key) do
    case attr do
      %{^key => value} -> value
      %{} = map -> Map.get(map, safe_key(key))
      _other -> nil
    end
  end

  defp safe_key("type"), do: :type
  defp safe_key("opts"), do: :opts
  defp safe_key("doc"), do: :doc
  defp safe_key("struct_name"), do: :struct_name
  defp safe_key("name"), do: :name

  # Read by `renders_slot?/2`, which scans a component's own markup. Both are fixed literals in this
  # module, so neither mints an atom from anything a template said.
  defp safe_key("template"), do: :template
  defp safe_key("body"), do: :body
  defp safe_key(_key), do: nil
end
