defmodule MishkaCmsCore.Runtime.PageBuilder.Fields do
  @moduledoc """
  What part of a form a palette component plays, what part a node in the document plays, and how a
  field is staged for preview.

  ## One answer, four callers

  `form_node?/2` and `field_node?/2` are the whole editor's answer to "is this node a form" and "is
  this node a field". `MishkaCmsCore.Runtime.PageBuilder.Containment` refuses a form dropped inside
  one, `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement` binds a field to the form it lands
  in, `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecks` reports what is wrong with each, and
  the compiled page reads the same markup back through
  `MishkaCmsCore.Runtime.PageBuilder.PageForms`. They had four implementations and the narrowest one
  — Containment's — never asked the kit at all, so a kit's own form wrapper was allowed to nest
  inside another form and the audit then reported the nesting the drop was supposed to refuse.

  Deciding a component's role parses that component's markup, and a page holds hundreds of copies of
  one card, so both questions take the memo `roles/2` builds: one answer per distinct component
  name, not one per node.

  ## The catalog is not the whole palette

  A name with no catalog row is asked of the CMS's own function components — `local_modules/0`, the
  same two modules the canvas resolves a dotted tag from — and their `__components__/0` metadata is
  translated into the shape a catalog row carries, so everything downstream reads one dialect.

  Without that, `<.input>` answered `:none`. It is `MishkaCmsCore.CoreComponents.input/1` rather than
  a database row, and it is what every shipped Forms block and every Forms element is built out of —
  so the drop never bound one to the form it landed in, and no field-level check ever fired on one.
  Dragging a field out of its form left a page that renders on the canvas, raises nothing in the
  audit rail, and then fails to compile on publish, because `field={f[:email]}` with no `:let` in
  scope is an undefined variable.

  ## Declaration first, inference second

  `role/1` asks `MishkaCmsCore.Builder.FormRole` what the component's own kit declared in its
  `extra.form`. A kit that declares nothing — which is every kit that shipped before the key
  existed — falls to inference over the component's attributes and its own markup.

  An inferred role then passes through the `builder:form:role` transform
  (`MishkaCmsCore.Builder.Events.form_role/2`); a declared one never does.

  ## `:error` is never inferred

  An error component renders ordinary markup and declares the same `errors` list a field does, so
  nothing in its structure says what it is. A kit that wants the role declares it.

  ## Detecting a Send button

  A component is `:submit` when its template's one OUTER element is a `<button>` whose type can be
  `submit`, or an `<input>` whose type can be `submit` or `image` — through its literal, the default
  of the attribute it is bound to, or that attribute's values. Buttons inside the markup never count.
  A row with no markup (the CMS's own `<.button>`) is asked of its declared `type` attribute.

  Whether a placed node sends its form is decided per node by `submit_node?/3`: the node's own
  literal type, else the component's default, else HTML's own default. A component that renders a
  link in place of its button (one with no markup that declares `href`, `navigate` or `patch`)
  never sends when given one; an outer `<button>` is rendered whatever the node carries, so it
  still sends. A type the node computes (`type={@kind}`) cannot be read: `type_unread?/3`.

  ## Passing its form inside

  `lends_form?/2` is true when the markup has `render_slot(@inner_block, v)` under a `:let={v}` on
  something that hands out a form (`hands_form?/2`): Phoenix's `<.form>`, or a component that itself
  lends one, followed through the called component's markup. A raw `<form>` hands out nothing,
  because HEEx refuses `:let` on an HTML tag.

  ## Detecting a field

  The load-bearing signal is an attribute typed as a `Phoenix.HTML.FormField` struct — 23 of the
  installed kit's 136 components declare one, and it is exactly the set that renders a
  value-carrying control. The attribute may be called anything at all: `binding_attr/1` answers with
  its name rather than assuming the name `field`.

  **Only Phoenix's own struct is inferred**, because only Phoenix's own struct is what the editor
  can write. What goes into that attribute is `f[:email]`, and `Phoenix.Component.to_form/2` produces
  nothing but a `%Phoenix.HTML.FormField{}`. Matching on the last dot-segment recognised a vendor's
  `Acme.FormField` as well — and then wrote a Phoenix struct into it, which the kit's own
  `%Acme.FormField{} = field` clause head cannot match, so the call fell through to the rendering
  clause and raised `KeyError :name` on the published page. A kit with its own struct declares
  `extra.form` instead, which is the kit saying what to write and where.

  A kit that binds fields some other way falls to `structural?/1`: the component's markup is PARSED,
  and a control it renders whose `name` and `value` (or `checked`) are bound to assigns the
  component declares is a field. Reading that as text called a kit's submit button a field — the
  same markup appears in `<input type="submit" name={@name} value={@value} />` — and called a
  component that merely quotes an input inside a comment one too. The parse answers both: a control
  whose `type` submits carries no value, and a comment is not a control.

  Neither branch reads `helpers`. Helper clauses are bundled per source MODULE, so
  `chelekom-select-option-group` carries `native_select`'s `%Phoenix.HTML.FormField{}` clause head
  while rendering nothing but `<option>` — a detector that trusted them would call it a field.

  ## Detecting a wrapper

  A wrapper is a component that renders a form of its own. Its template is PARSED and walked for a
  `form` or `.form` node, so a wrapper emitting a raw `<form>` element is found and a template that
  merely names one in a comment or a code sample is not.

  `chelekom-simple-form` renders neither: it forwards everything to `chelekom-form-wrapper` through
  an `{assigns}` splat, so its own markup never mentions a form. A `for` attribute the component
  declares REQUIRED counts as well, because required is the component saying the form's data is its
  own to hand on. So does a template whose one outer element is a component that is itself a
  wrapper, read from that component's own markup.

  ## Which attributes a binding supersedes

  `pair_attrs/1` names the two attributes a kit derives from the form field, so the drop can clear
  the blanks a palette card is seeded with — leave `name=""` beside the binding that replaces it and
  the blank wins, because a kit fills it with `assign_new/3`, which only fills an ABSENT key.

  The kit's declaration wins; the kit's own markup answers next, read by the same parse that decides
  `structural?/1`; and `nil` is the honest answer when neither says. It used to fall back to the
  literal names `"name"` and `"value"`, which are Phoenix's spelling rather than the kit's — so a kit
  calling them `input_name` and `input_value` had two attributes it does not have dropped and its two
  real blanks left in place, which is exactly the failure the drop exists to prevent.

  `bindings/1` answers the binding attribute and the pair together, for the caller that needs both —
  which is every caller that writes one, because writing the binding and clearing what it supersedes
  is one decision made once.

  ## Where the author's own word comes from

  `field_label/2` is the read side of the same doctrine, and it was the half still written in
  Phoenix's spelling: a two-word vocabulary of `name` then `label`, so a kit that calls them
  something else contributed nothing an author had typed. It asks `pair_attrs/1` for the kit's name
  attribute instead. See the function for what is left hardcoded and why.

  ## Why the previews need a field

  A text field previewed on its own is a box with a label. It is not wrong — the kit's own docs
  render all 589 field examples unwrapped, and no field template depends on a form ancestor — but it
  is not what the reader is being asked about either. The modal exists to answer "what does this
  look like", and a field's answer includes the form it lives in.

  So `stage/2` wraps the preview source, and only the preview source.

  ## Why a dropped field IS wrapped, elsewhere

  HTML forbids a nested `<form>`, and the failure is silent rather than loud: the parser's
  form-element pointer discards the inner start tag — `data-node-id` and all — and lets the inner
  `</form>` close the OUTER one, ejecting every later sibling from submission.

  So the wrapping a dropped field needs is conditional, and it does not belong here. The insert
  funnel wraps a field that lands with no form ancestor, in one undoable step, and `Containment`
  refuses a form dropped inside a form.
  """

  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Builder.FormRole
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @forms [".form", "form"]

  # The tag whose `:let` hands out a form. A raw `<form>` cannot carry `:let`.
  @lending_tag ".form"

  # The two outer elements a Send button can be, and HTML's type for each when none is written.
  @send_tags %{"button" => "submit", "input" => "text"}

  @links ~w(href navigate patch)

  # What a component's `:global` attribute takes without an `include` list, as Phoenix reads it.
  @global_prefixes ~w(phx- data- aria-)

  @global_names ~w(autofocus class hidden id lang role style tabindex title)

  # How a `:submit` component with nothing readable in its markup sends: as its role says, and a
  # link attribute on it may make it a link.
  @trusted %{fixed: nil, attr: "type", default: nil, values: [], base: "submit", links: @links}

  @name "name"

  @label "label"

  @form_field "Phoenix.HTML.FormField"

  # `<.form>` and `<.input>` are the CMS's own function components, imported into every compiled
  # page and resolved by the canvas from these two modules in this order.
  @local_component_modules [MishkaCmsCore.CoreComponents, Phoenix.Component]

  @role_atoms Map.new(FormRole.roles(), &{&1, String.to_atom(&1)})

  @doc """
  The modules a dotted tag with no catalog row is asked of, in the order a compiled page imports
  them — `MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive` resolves a component the same way, and
  `MishkaCmsCore.Runtime.PageBuilder.Containment` asks them what declares a slot.
  """
  @spec local_modules() :: [module()]
  def local_modules, do: @local_component_modules

  @doc """
  This component's part in a form: `:wrapper`, `:field`, `:error`, `:fieldset`, `:submit` or
  `:none`.

  A declaration wins; otherwise it is inferred and passed through `builder:form:role`. `:error` is
  never inferred. `components` is the palette, read when the template's outer element is another
  component.

  Accepts a palette entry or anything shaped like a component row.
  """
  @spec role(map(), [map()]) :: atom()
  def role(entry, components \\ []), do: role_in(entry, components, MapSet.new())

  defp role_in(entry, components, seen) do
    case declared_role(entry) do
      {:ok, %{role: role}} ->
        Map.fetch!(@role_atoms, role)

      :none ->
        entry
        |> inferred(components, MapSet.put(seen, entry_name(entry)))
        |> Events.form_role(entry)
    end
  end

  @doc "Whether this component is a form field."
  @spec field?(map()) :: boolean()
  def field?(entry), do: role(entry) == :field

  @doc """
  Whether this component renders a form of its own, so the author placed the form themselves.
  `components` is the palette, read when the template's outer element is another component.
  """
  @spec wrapper?(map(), [map()]) :: boolean()
  def wrapper?(entry, components \\ []), do: role(entry, components) == :wrapper

  @doc """
  The part each component named in `nodes` plays, keyed by component name — the memo both node
  questions take.

  Asked once per distinct component in the document rather than once per node: deciding a role
  parses the component's own template, and a page can hold hundreds of copies of one card.
  """
  @spec roles([map()], [map()]) :: %{String.t() => atom()}
  def roles(nodes, components) do
    nodes
    |> Enum.map(&component_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(&{&1, played(entry(&1, components), components)})
  end

  @doc """
  How each `:submit` component in `roles` sends, keyed by name — the memo `submit_node?/3`,
  `explicit_submit?/3`, `button_node?/3` and `type_unread?/3` read. Built once per component, not
  per node.
  """
  @spec submit_rules(%{String.t() => atom()}, [map()]) :: %{String.t() => map()}
  def submit_rules(roles, components) do
    for {name, :submit} <- roles, into: %{}, do: {name, name |> entry(components) |> send_rule()}
  end

  @doc """
  Whether this placed node sends the form it is in: its own literal type, else its component's
  default, else HTML's default. A component that renders a link in its place never sends.

  `roles` and `rules` are the memos `roles/2` and `submit_rules/2` build.
  """
  @spec submit_node?(map(), %{optional(String.t()) => atom()}, %{optional(String.t()) => map()}) ::
          boolean()
  def submit_node?(%Node{kind: :tag, tag: tag} = node, _roles, _rules)
      when is_map_key(@send_tags, tag),
      do: sends?(node, tag_rule(tag))

  def submit_node?(%Node{kind: :component} = node, roles, rules),
    do: component_role(node, roles) == :submit and sends?(node, rule_for(node, rules))

  def submit_node?(_node, _roles, _rules), do: false

  @doc """
  Whether this placed button computes its type (`type={@kind}`), so whether it sends its form cannot
  be read. A link, and a component whose markup fixes its type, are read. An `<input>` computing its
  type is a field (`PageForms.control?/1`), not a button.

  `roles` and `rules` are the memos `roles/2` and `submit_rules/2` build.
  """
  @spec type_unread?(map(), %{optional(String.t()) => atom()}, %{optional(String.t()) => map()}) ::
          boolean()
  def type_unread?(%Node{kind: :tag, tag: "button"} = node, _roles, _rules),
    do: unread?(node, tag_rule("button"))

  def type_unread?(%Node{kind: :component} = node, roles, rules),
    do: component_role(node, roles) == :submit and unread?(node, rule_for(node, rules))

  def type_unread?(_node, _roles, _rules), do: false

  @doc """
  The attribute this placed button's type is written on: `type` on a `<button>` or an `<input>`,
  the kit's own on a `:submit` component, and `nil` when the component's markup fixes the type or
  the node renders a link, which reads no type.

  `roles` and `rules` are the memos `roles/2` and `submit_rules/2` build.
  """
  @spec type_attr(map(), %{optional(String.t()) => atom()}, %{optional(String.t()) => map()}) ::
          String.t() | nil
  def type_attr(%Node{kind: :tag, tag: tag}, _roles, _rules) when is_map_key(@send_tags, tag),
    do: "type"

  def type_attr(%Node{kind: :component} = node, roles, rules) do
    rule = rule_for(node, rules)

    case component_role(node, roles) == :submit and not link?(node, rule.links) and rule do
      %{fixed: nil, attr: attr} -> attr
      _fixed_link_or_none -> nil
    end
  end

  def type_attr(_node, _roles, _rules), do: nil

  defp unread?(node, rule),
    do:
      rule.fixed == nil and not link?(node, rule.links) and computed?(Node.attr(node, rule.attr))

  defp computed?({:expr, _source} = bound), do: PageForms.written_type(bound) == nil
  defp computed?(_written_or_unset), do: false

  @doc """
  Whether this node says in writing that it submits: `type="submit"` or `"image"` (or a literal
  such as `{:submit}`) on the node, or on its component's outer element. A button left to a default
  does not.
  """
  @spec explicit_submit?(map(), %{optional(String.t()) => atom()}, %{
          optional(String.t()) => map()
        }) :: boolean()
  def explicit_submit?(%Node{kind: :tag, tag: tag} = node, _roles, _rules)
      when is_map_key(@send_tags, tag),
      do: PageForms.sending_type?(written_type(node, "type"))

  def explicit_submit?(%Node{kind: :component} = node, roles, rules) do
    rule = rule_for(node, rules)

    component_role(node, roles) == :submit and not link?(node, rule.links) and
      PageForms.sending_type?(rule.fixed || written_type(node, rule.attr))
  end

  def explicit_submit?(_node, _roles, _rules), do: false

  @doc """
  Whether this placed node is a button of any kind: a `<button>`, an `<input>` typed as one, or a
  `:submit` component placed as one. A component whose outer element is an `<input>` is a button
  only when this node's type (else its default) is a button's; a computed type counts.

  `roles` and `rules` are the memos `roles/2` and `submit_rules/2` build.
  """
  @spec button_node?(map(), %{optional(String.t()) => atom()}, %{optional(String.t()) => map()}) ::
          boolean()
  def button_node?(%Node{kind: :tag, tag: "button"}, _roles, _rules), do: true

  def button_node?(%Node{kind: :tag, tag: "input"} = node, _roles, _rules),
    do: not PageForms.control?(node)

  def button_node?(%Node{kind: :component} = node, roles, rules),
    do: component_role(node, roles) == :submit and placed_button?(node, rule_for(node, rules))

  def button_node?(_node, _roles, _rules), do: false

  # An outer `<button>` (HTML's type `submit` when none is written) is a button whatever type it is
  # given; an outer `<input>` is one only when typed as one.
  defp placed_button?(_node, %{base: "submit"}), do: true
  defp placed_button?(node, rule), do: node |> sent_as(rule) |> button_typed?()

  defp button_typed?(nil), do: true
  defp button_typed?(type), do: PageForms.button_type?(type)

  @doc """
  Whether this component's markup passes a form to what is written inside it:
  `render_slot(@inner_block, v)` under a `:let={v}` on something `hands_form?/2` answers yes for.

  `components` is the palette, read when the `:let` sits on another component.
  """
  @spec lends_form?(map() | nil, [map()]) :: boolean()
  def lends_form?(entry, components \\ []),
    do: lends?(entry, components, MapSet.new([entry_name(entry)]))

  @doc """
  Whether a `:let` on this node receives a form: Phoenix's `<.form>`, or a component whose markup
  lends its form. A raw `<form>` does not.
  """
  @spec hands_form?(map(), [map()]) :: boolean()
  def hands_form?(node, components), do: hands?(node, components, MapSet.new())

  defp hands?(%Node{kind: :component, tag: @lending_tag}, _components, _seen), do: true

  defp hands?(%Node{kind: :component} = node, components, seen) do
    name = Node.component_name(node)

    not MapSet.member?(seen, name) and
      lends?(entry(name, components), components, MapSet.put(seen, name))
  end

  defp hands?(_node, _components, _seen), do: false

  defp lends?(nil, _components, _seen), do: false

  defp lends?(entry, components, seen) do
    case markup(entry) do
      nil -> false
      tree -> tree |> Tree.walk() |> Enum.any?(&yields?(tree, &1, components, seen))
    end
  end

  defp yields?(tree, node, components, seen) do
    with var when is_atom(var) and not is_nil(var) <- PageForms.let_var(node),
         true <- hands?(node, components, seen) do
      tree
      |> Tree.descendant_ids(node.id)
      |> Enum.any?(&(tree |> Tree.get(&1) |> yielded?(var)))
    else
      _no_form -> false
    end
  end

  defp yielded?(%Node{kind: :eex, text: text}, var) when is_binary(text),
    do: text |> String.trim() |> Code.string_to_quoted() |> inner_block_with?(var)

  defp yielded?(_node, _var), do: false

  defp inner_block_with?(
         {:ok, {:render_slot, _meta, [{:@, _at, [{:inner_block, _ib, nil}]}, {var, _v, nil}]}},
         var
       ),
       do: true

  defp inner_block_with?(_other, _var), do: false

  @doc """
  The declaration behind a node: its palette row, or the CMS-local function component's own
  metadata translated into the same shape, or `nil` when neither has heard of the name.

  What a binding is written onto is read off it, so a caller holding a node and the palette asks
  here rather than searching the catalog itself — searching the catalog alone is what left every
  `<.input>` on every shipped Forms block unbound.
  """
  @spec entry(Node.t() | String.t() | nil, [map()]) :: map() | nil
  def entry(nil, _components), do: nil

  def entry(name, components) when is_binary(name),
    do: Enum.find(components, &(entry_name(&1) == name)) || local(name)

  def entry(node, components), do: node |> component_name() |> entry(components)

  @doc """
  Whether this node is a form: HTML's own `<form>`, Phoenix's `<.form>`, a component the kit calls a
  wrapper, or any node that names a page assign with `for=`.

  `roles` is the memo `roles/2` builds. The last answer is `PageForms.form?/1`, and it is why a kit
  wrapper still counts when the palette is not to hand: a wrapper the author has already given a
  page assign declares itself in the markup.
  """
  @spec form_node?(map(), %{optional(String.t()) => atom()}) :: boolean()
  def form_node?(node, roles \\ %{}) do
    form_tag?(tag_of(node)) or component_role(node, roles) == :wrapper or declares_form?(node)
  end

  @doc """
  Whether this node is a field: a component the kit calls one, or one of HTML's own value-carrying
  controls.

  Those control names are the one vocabulary in this work, and they are HTML's rather than a kit's.
  They are written down in `MishkaCmsCore.Runtime.PageBuilder.PageForms.control?/1` and nowhere else,
  because the compiled page's own reader has to agree with what the editor calls a field.
  """
  @spec field_node?(map(), %{optional(String.t()) => atom()}) :: boolean()
  def field_node?(node, roles \\ %{})

  def field_node?(%Node{kind: :component} = node, roles),
    do: component_role(node, roles) == :field

  def field_node?(%Node{kind: :tag} = node, _roles), do: PageForms.control?(node)

  def field_node?(_node, _roles), do: false

  @doc """
  Whether an attribute `name` written on this node reaches what it renders: any attribute on an
  HTML tag; on a component, one it declares, or one its catch-all `:global` attribute takes (a
  `phx-`, `data-` or `aria-` name, one of HTML's global names, or one its `include` list names) when
  its markup spreads that attribute. A component with no declaration takes nothing.
  """
  @spec takes?(map(), String.t(), [map()]) :: boolean()
  def takes?(%Node{kind: :tag}, _name, _components), do: true

  def takes?(%Node{kind: :component} = node, name, components),
    do: node |> entry(components) |> takes_attr?(name)

  def takes?(_node, _name, _components), do: false

  defp takes_attr?(nil, _name), do: false

  defp takes_attr?(entry, name) do
    attrs = Inspector.attrs(entry)

    Enum.any?(attrs, &(Inspector.name(&1) == name)) or
      Enum.any?(attrs, &global_takes?(&1, name, entry))
  end

  defp global_takes?(attr, name, entry) do
    Inspector.type(attr) == "global" and
      (global_name?(name) or name in List.wrap(Inspector.opts(attr)["include"])) and
      spreads?(entry, Inspector.name(attr))
  end

  defp global_name?(name),
    do: String.starts_with?(name, @global_prefixes) or name in @global_names

  # A row with no markup (the CMS's own components) renders its catch-all as declared; a kit's
  # markup has to spread it onto an element, as `{@rest}` or through a helper, `{drop_rest(@rest)}`.
  defp spreads?(entry, attr_name) do
    case entry |> Inspector.template() |> String.trim() do
      "" -> true
      template -> spread_in?(template, attr_name)
    end
  end

  # `{@rest}` or `{drop_rest(@rest)}` in `markup`, not a read of one key like `{@rest[:disabled]}`
  # written as an attribute's value.
  defp spread_in?(markup, attr_name),
    do: Regex.match?(~r/(?<![=\w%])\{[^{}]*@#{attr_name}\b[^{}]*\}/, markup)

  @doc """
  The literal `type` a component's markup writes on the `<input>` its catch-all `:global` attribute
  is spread onto, lowercased, or `nil` when it spreads it onto no `<input>` or the type is not
  written as text.
  """
  @spec forwarded_type(map() | nil) :: String.t() | nil
  def forwarded_type(nil), do: nil

  def forwarded_type(entry) do
    globals =
      for attr <- Inspector.attrs(entry),
          Inspector.type(attr) == "global",
          do: Inspector.name(attr)

    ~r/<input\b(?:[^>{}]|\{[^{}]*\})*>/s
    |> Regex.scan(Inspector.template(entry))
    |> Enum.map(&hd/1)
    |> Enum.find(fn tag -> Enum.any?(globals, &spread_in?(tag, &1)) end)
    |> input_type()
  end

  defp input_type(nil), do: nil

  defp input_type(tag) do
    case Regex.run(~r/(?<![\w-])type=["']([^"']+)["']/, tag) do
      [_all, type] -> PageForms.type_word(type)
      nil -> nil
    end
  end

  @doc """
  Whether this node carries a value the author wrote rather than one it reads off the form: a radio
  option's `one`, a checkbox's `true`, the hidden `false` beside it.

  It is what separates several controls that are ONE field — a group answering to one name — from
  several fields that would write over each other, and it is why a binding leaves such a value where
  it is. A palette card's seeded blank is not a value.
  """
  @spec written_value?(map()) :: boolean()
  def written_value?(node), do: Node.literal(node, "value") != nil

  @doc """
  The attribute name to write a `%Phoenix.HTML.FormField{}` binding on, or `nil` when this component
  cannot take one — in which case the editor writes the kit's `name` and `value` pair instead.
  """
  @spec binding_attr(map()) :: String.t() | nil
  def binding_attr(entry), do: entry |> declared_role() |> field_attr(entry)

  @doc """
  The `name` and `value` attribute names a binding supersedes, either of which is `nil` when this
  component has no such attribute.

  Declared first, read off the component's own markup second, `nil` last — never guessed. See the
  moduledoc for what guessing cost.
  """
  @spec pair_attrs(map()) :: {String.t() | nil, String.t() | nil}
  def pair_attrs(entry), do: entry |> declared_role() |> declared_pair() |> completed(entry)

  @doc """
  Both of the above at once: `{binding attribute, {name attribute, value attribute}}`.

  For the caller that needs both, which is the insert funnel — writing a binding and clearing the
  pair it supersedes is one decision. Asked separately it rebuilt the kit's declaration twice and
  could parse the component's own markup twice with it, and `chelekom-combobox`'s markup is 6.7 KB.
  """
  @spec bindings(map()) ::
          {String.t() | nil, {String.t() | nil, String.t() | nil}}
  def bindings(entry) do
    declared = declared_role(entry)

    {field_attr(declared, entry), declared |> declared_pair() |> completed(entry)}
  end

  defp declared_role(entry), do: FormRole.build(declared_form(entry), entry)

  defp field_attr({:ok, %{bindings: %{"field" => attr}}}, _entry), do: attr
  defp field_attr(_undeclared, entry), do: form_field_attr_name(entry)

  defp declared_pair({:ok, %{bindings: bindings}}),
    do: {Map.get(bindings, "name"), Map.get(bindings, "value")}

  defp declared_pair(:none), do: {nil, nil}

  defp completed({name, value}, _entry) when is_binary(name) and is_binary(value),
    do: {name, value}

  defp completed({name, value}, entry) do
    {rendered_name, rendered_value} = rendered_pair(entry) || {nil, nil}

    {name || rendered_name, value || rendered_value}
  end

  defp inferred(entry, components, seen),
    do: entry |> form_field_attr_name() |> typed(entry, components, seen)

  defp typed(attr, _entry, _components, _seen) when is_binary(attr), do: :field

  defp typed(nil, entry, components, seen),
    do: entry |> markup() |> inferred_from(entry, components, seen)

  # The component's template as a tree, or `nil` when it does not parse. `inferred_from/4` asks
  # every structural question of this one tree; `calls_wrapper?/3` parses the called component too.
  defp markup(entry) do
    case entry |> Inspector.template() |> Tree.parse() do
      {:ok, tree} -> tree
      {:error, _unparseable} -> nil
    end
  end

  defp inferred_from(tree, entry, components, seen) do
    cond do
      carrier_pair(tree, entry) != nil -> :field
      owns_form?(tree) -> :wrapper
      required_for?(entry) -> :wrapper
      calls_wrapper?(tree, components, seen) -> :wrapper
      markup_rule(tree, entry) != nil -> :submit
      true -> :none
    end
  end

  # The template's one outer element when it is another component that is itself a wrapper.
  defp calls_wrapper?(tree, components, seen) do
    with %Node{kind: :component} = node <- outer(tree),
         name when is_binary(name) <- Node.component_name(node),
         false <- MapSet.member?(seen, name),
         %{} = called <- entry(name, components) do
      role_in(called, components, seen) == :wrapper
    else
      _not_a_wrapper -> false
    end
  end

  # The template's one element at the top, ignoring text and comments; `nil` for none or several.
  defp outer(nil), do: nil

  defp outer(tree) do
    case tree.roots |> Enum.map(&Tree.get(tree, &1)) |> Enum.filter(&element?/1) do
      [only] -> only
      _none_or_several -> nil
    end
  end

  defp element?(%Node{kind: kind}), do: kind in [:tag, :component]
  defp element?(_node), do: false

  # How a component sends, read off its markup: its outer `<button>`/`<input>`, or, with no markup
  # at all, its declared `type` attribute. `nil` when it cannot send.
  defp markup_rule(tree, entry) do
    tree
    |> outer_rule(entry)
    |> sending()
  end

  defp outer_rule(tree, entry) do
    case outer(tree) do
      %Node{kind: :tag, tag: tag} = node when is_map_key(@send_tags, tag) ->
        node |> Node.attr("type") |> typed_by(entry, Map.fetch!(@send_tags, tag))

      nil ->
        bare_rule(tree, entry)

      _other ->
        nil
    end
  end

  defp bare_rule(nil, _entry), do: nil
  defp bare_rule(_tree, entry), do: entry |> Inspector.template() |> String.trim() |> bare(entry)

  defp bare("", entry), do: %{rule_on("type", entry, nil) | links: linked_by(entry)}
  defp bare(_markup, _entry), do: nil

  # A component with no markup to read (the CMS's `<.button>`) renders a link in place of its button
  # when given a link attribute it declares, itself or through its global `include:`.
  defp linked_by(entry) do
    offered =
      entry
      |> Inspector.attrs()
      |> Enum.flat_map(
        &[to_string(Inspector.name(&1)) | List.wrap(Inspector.opts(&1)["include"])]
      )

    Enum.filter(@links, &(&1 in offered))
  end

  # The outer element's own `type`: unset reads the component's `type` attribute, a literal fixes
  # it, an assign reads that attribute, and anything computed is not guessed.
  defp typed_by(nil, entry, base), do: rule_on("type", entry, base)

  defp typed_by({:expr, _source} = bound, entry, base),
    do: bound |> PageForms.written_type() |> bound_type(assign_name(bound), entry, base)

  defp typed_by(written, _entry, base), do: fixed(PageForms.written_type(written) || base, base)

  defp bound_type(word, _name, _entry, base) when is_binary(word), do: fixed(word, base)
  defp bound_type(nil, name, entry, base) when is_binary(name), do: rule_on(name, entry, base)
  defp bound_type(nil, nil, _entry, _base), do: nil

  defp fixed(type, base),
    do: %{fixed: type, attr: "type", default: nil, values: [], base: base, links: []}

  defp rule_on(attr_name, entry, base) do
    declared = Enum.find(Inspector.attrs(entry), &(to_string(Inspector.name(&1)) == attr_name))

    %{
      fixed: nil,
      attr: attr_name,
      default: declared |> declared_default() |> PageForms.type_word(),
      values: declared |> declared_values() |> Enum.map(&PageForms.type_word/1),
      base: base,
      links: []
    }
  end

  defp declared_default(nil), do: nil
  defp declared_default(attr), do: Inspector.default(attr)

  defp declared_values(nil), do: []

  defp declared_values(attr) do
    case Inspector.opts(attr)["values"] do
      values when is_list(values) -> values
      _none -> []
    end
  end

  defp sending(nil), do: nil

  defp sending(%{fixed: fixed} = rule) when is_binary(fixed),
    do: fixed |> PageForms.sending_type?() |> sent(rule)

  defp sending(rule) do
    [rule.default | rule.values]
    |> Enum.any?(&PageForms.sending_type?(&1 || rule.base))
    |> sent(rule)
  end

  defp sent(true, rule), do: rule
  defp sent(false, _rule), do: nil

  defp send_rule(nil), do: @trusted
  defp send_rule(entry), do: entry |> markup() |> markup_rule(entry) || @trusted

  # HTML's own element is rendered as written, so a link attribute on it changes nothing.
  defp tag_rule(tag),
    do: %{
      fixed: nil,
      attr: "type",
      default: nil,
      values: [],
      base: Map.fetch!(@send_tags, tag),
      links: []
    }

  defp rule_for(node, rules), do: Map.get(rules, Node.component_name(node), @trusted)

  defp sends?(node, rule),
    do: not link?(node, rule.links) and node |> sent_as(rule) |> PageForms.sending_type?()

  # The type a placed node sends with: a literal on the node (`type="submit"`, `type={:submit}`),
  # else its component's default, else HTML's. `nil` when the node computes it.
  defp sent_as(_node, %{fixed: fixed}) when is_binary(fixed), do: fixed
  defp sent_as(node, rule), do: node |> Node.attr(rule.attr) |> sent_with(rule)

  defp sent_with({:expr, _source} = bound, _rule), do: PageForms.written_type(bound)
  defp sent_with(written, rule), do: PageForms.written_type(written) || rule.default || rule.base

  defp written_type(node, attr), do: node |> Node.attr(attr) |> PageForms.written_type()

  defp link?(node, links), do: Enum.any?(links, &(Node.attr(node, &1) != nil))

  defp owns_form?(nil), do: false

  defp owns_form?(tree), do: tree |> Tree.walk() |> Enum.any?(&(&1.tag in @forms))

  defp required_for?(entry) do
    Enum.any?(Inspector.attrs(entry), &(Inspector.name(&1) == "for" and Inspector.required?(&1)))
  end

  # An attribute the kit typed as Phoenix's own form field struct, whatever it named it.
  # `chelekom-input-button` renders a real `<input>` and declares none, which is what keeps a submit
  # button out of the set.
  defp form_field_attr_name(entry) do
    Enum.find_value(Inspector.attrs(entry), fn attr ->
      with "struct" <- Inspector.type(attr),
           @form_field <- attr |> struct_name() |> module_name() do
        Inspector.name(attr)
      else
        _other -> nil
      end
    end)
  end

  defp module_name(name), do: name |> to_string() |> String.replace_prefix("Elixir.", "")

  @doc """
  The fallback signal, for a kit that carries no form-field struct: a control the component renders
  whose `name` and value are both bound to assigns it declares.

  Public because it is the half a second kit is judged on, and worth being able to check directly.
  """
  @spec structural?(map()) :: boolean()
  def structural?(entry), do: rendered_pair(entry) != nil

  defp rendered_pair(entry), do: entry |> markup() |> carrier_pair(entry)

  defp carrier_pair(nil, _entry), do: nil

  defp carrier_pair(tree, entry) do
    declared = declared_names(entry)

    tree
    |> Tree.walk()
    |> Enum.filter(&PageForms.control?/1)
    |> Enum.find_value(&bound_pair(&1, declared))
  end

  defp bound_pair(node, declared) do
    with name when is_binary(name) <- assign_bound(node, "name", declared),
         value when is_binary(value) <-
           assign_bound(node, "value", declared) || assign_bound(node, "checked", declared) do
      {name, value}
    else
      _unbound -> nil
    end
  end

  # `name={@input_name}` names `input_name`; a literal `name="q"` names nothing the editor can
  # write, and an assign the component never declared is not an attribute at all.
  defp assign_bound(node, attr, declared) do
    node |> Node.attr(attr) |> assign_name() |> known(declared)
  end

  defp assign_name({:expr, source}),
    do: source |> String.trim() |> Code.string_to_quoted() |> assign_var()

  defp assign_name(_other), do: nil

  defp assign_var({:ok, {:@, _meta, [{name, _var_meta, nil}]}}) when is_atom(name),
    do: Atom.to_string(name)

  defp assign_var(_other), do: nil

  defp known(name, declared) when is_binary(name) do
    case MapSet.member?(declared, name) do
      true -> name
      false -> nil
    end
  end

  defp known(_absent, _declared), do: nil

  defp declared_names(entry) do
    entry
    |> Inspector.attrs()
    |> Enum.map(&Inspector.name/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new(&to_string/1)
  end

  @doc """
  The author's own word for this control, which is what a field key is minted from.

  The attributes are tried in this order, and the first one carrying a word the author actually
  wrote wins; a blank is not a word, because the palette seeds a card with one so it renders standing
  alone.

    1. The kit's OWN name attribute — `pair_attrs/1` answers what the kit called it, so a component
       spelling it `input_name` contributes what was typed into it. Reading only the literal `name`
       meant a kit with its own spelling contributed nothing and the key fell through to the
       component's name: a dropped `acme-text` came out `f[:acme_text]` while its `input_name`
       carried the word the author had just written.
    2. HTML's own `name`, which is what a raw `<input>` from the Elements library carries and what a
       component taking `name=` directly still means.
    3. The attribute the kit declares as its caption in `extra.form`, or one the component itself
       declares called `label`. The literal `label` is checked against the component's own
       declarations rather than written blind — a kit that spells it otherwise says so beside the
       rest of its bindings.

  The node's own label last, which is the component's name and is the answer of last resort rather
  than a choice anybody made.

  Used by the insert funnel and by the audit's Fix, which had a copy of the two-word version each.
  """
  @spec field_label(Node.t(), [map()]) :: String.t()
  def field_label(node, components) do
    node
    |> entry(components)
    |> word_attrs()
    |> Enum.find_value(&Node.literal(node, &1)) || Node.label(node)
  end

  defp word_attrs(nil), do: [@name, @label]

  defp word_attrs(entry) do
    [named_attr(entry), @name, label_attr(entry)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp named_attr(entry), do: entry |> pair_attrs() |> elem(0)

  defp label_attr(entry) do
    case declared_role(entry) do
      {:ok, %{bindings: %{"label" => attr}}} -> attr
      _undeclared -> own_label_attr(entry)
    end
  end

  defp own_label_attr(entry) do
    entry
    |> Inspector.attrs()
    |> Enum.find_value(&matching(Inspector.name(&1)))
  end

  defp matching(@label), do: @label
  defp matching(_other), do: nil

  @doc """
  The preview source for a component, wrapped in a form when it is a field.

  `phx-submit` is not decoration: a `<form>` with no handler still submits implicitly, so pressing
  Enter in a previewed text field navigates the preview iframe and the LiveView is gone. With the
  binding present LiveView intercepts the submit and the canvas's own catch-all `handle_event/3`
  swallows it.
  """
  @spec stage(String.t(), map() | nil) :: String.t()
  def stage(source, entry) when is_binary(source) and is_map(entry),
    do: staged(field?(entry), source)

  def stage(source, _entry) when is_binary(source), do: source

  defp staged(true, source), do: ~s(<form phx-submit="noop" class="space-y-4">#{source}</form>)
  defp staged(false, source), do: source

  defp declared_form(%{form: form}) when is_map(form), do: form
  defp declared_form(%{"form" => form}) when is_map(form), do: form
  defp declared_form(_entry), do: %{}

  defp struct_name(%{"struct_name" => name}), do: name
  defp struct_name(%{struct_name: name}), do: name
  defp struct_name(_attr), do: nil

  defp form_tag?(tag) when is_binary(tag), do: String.downcase(tag) in @forms
  defp form_tag?(_tag), do: false

  defp tag_of(%{tag: tag}), do: tag
  defp tag_of(%{"tag" => tag}), do: tag
  defp tag_of(_dragged), do: nil

  defp declares_form?(%{attrs: attrs} = node) when is_list(attrs), do: PageForms.form?(node)
  defp declares_form?(_dragged), do: false

  defp component_role(node, roles), do: Map.get(roles, component_name(node), :none)

  defp component_name(%{kind: _kind} = node), do: Node.component_name(node)
  defp component_name(_other), do: nil

  defp played(nil, _components), do: :none
  defp played(entry, components), do: role(entry, components)

  defp entry_name(%{name: name}), do: name
  defp entry_name(%{"name" => name}), do: name
  defp entry_name(_entry), do: nil

  # A CMS-LOCAL FUNCTION COMPONENT IS NOT IN THE KIT CATALOG, and `<.input>` is the field every
  # shipped Forms block and every Forms element is built out of. Looked up in the catalog alone it
  # answered `:none`, so the drop never bound it to the form it landed in and no field-level check
  # ever fired on it — and a field dragged out of its form produced a page that raises `CompileError`
  # on publish with an empty audit rail behind it.
  defp local(name) do
    Enum.find_value(@local_component_modules, &declared(&1, name))
  end

  # Read off the module's own metadata rather than a list kept here, and matched as TEXT so a name
  # arriving in a template never mints an atom: an undeclared one simply does not match.
  defp declared(module, name) do
    case exports_components?(module) do
      true -> module.__components__() |> Enum.find_value(&named(&1, name)) |> row(name)
      false -> nil
    end
  end

  defp exports_components?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__components__, 0)

  defp named({fun, meta}, name), do: matched(Atom.to_string(fun) == name, meta)

  defp matched(true, meta), do: meta
  defp matched(false, _meta), do: nil

  defp row(nil, _name), do: nil

  defp row(meta, name),
    do: %{
      "name" => name,
      "attrs" => meta |> Map.get(:attrs, []) |> Enum.map(&declaration/1),
      "slots" => meta |> Map.get(:slots, []) |> Enum.map(&named_slot/1),
      "template" => ""
    }

  # Translated into the shape the catalog rows carry, so everything downstream reads one dialect.
  # A declared type arrives as an atom or a `{:struct, Module}` pair; the catalog spells the second
  # one out as the string `MishkaCmsCore.Runtime.PageBuilder.Inspector.type/1` matches.
  defp declaration(attr) do
    opts = attr |> Map.get(:opts, []) |> List.wrap()

    %{
      "name" => attr |> Map.get(:name) |> to_string(),
      "type" => attr |> Map.get(:type) |> type_name(),
      "struct_name" => attr |> Map.get(:type) |> struct_module(),
      "opts" => %{
        "required" => Map.get(attr, :required) == true,
        "default" => Keyword.get(opts, :default),
        "values" => Keyword.get(opts, :values),
        "include" => Keyword.get(opts, :include)
      }
    }
  end

  defp named_slot(slot), do: %{"name" => slot |> Map.get(:name) |> to_string()}

  defp type_name({:struct, _module}), do: "struct"
  defp type_name(type) when is_atom(type), do: Atom.to_string(type)
  defp type_name(_other), do: "any"

  defp struct_module({:struct, module}), do: inspect(module)
  defp struct_module(_other), do: nil
end
