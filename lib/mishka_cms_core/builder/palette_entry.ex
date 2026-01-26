defmodule MishkaCmsCore.Builder.PaletteEntry do
  @moduledoc """
  A component in the builder's palette — from the database, or contributed by an extension.

  ## The two paths, one shape

  Most palette entries are `Component` rows: an extension that ships template-shaped components
  (a post card, a hero) installs them as ordinary rows and everything downstream — compile,
  resolution, palette, inspector, examples — already works with no editor changes at all.

  Some components cannot be a stored HEEx template: "Latest posts", streaming live data, is a real
  LiveView component in the extension's own code. Those register on the `builder:components` hook as
  descriptors carrying a `render` ref, and are inserted as a module call rather than a
  `<.component component_name=…>` wrapper.

  Both arrive here as the same struct, so the palette, the search, the categories and the property
  panel are written once.

  ## `render` is never a closure

  A descriptor travels through a `MishkaInstaller` hook payload, which is plain-map only — the same
  rule `MishkaCmsCore.Dashboard.Widget` follows. `render` is `{module, function}`, and the template
  the editor emits for it is a fully-qualified module call.

  ## Serialization is whitelisted

  A module call in a template is arbitrary code at compile time. `template/2` will only emit a call
  for a module that a registered descriptor actually named, so the editor cannot be talked into
  emitting a call to anything else — defence in depth, since templates are admin-authored anyway.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageBuilder.Starter
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  use GuardedStruct

  guardedstruct do
    field(:key, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
    field(:name, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
    field(:label, :string, derives: "sanitize(trim)")
    field(:type, :string, default: "general")
    field(:description, :string, derives: "sanitize(trim)")
    # The component's own markup. The layers tree parses it to show what is inside a component
    # in place, rather than making the author open the component's editor to find out.
    field(:template, :string)
    field(:attrs, list(), default: [])
    field(:slots, list(), default: [])
    field(:helpers, list(), default: [])
    field(:examples, list(), default: [])
    field(:features, :map, default: %{})
    field(:priority, :integer, default: 50)
    field(:global?, :boolean, default: true)
    # What this component declares it should look like on a fresh drop. Validated by
    # `MishkaCmsCore.Builder.Furnishing` at the point of use rather than here, because it arrives
    # from a third party's `extra` and a malformed one must cost the furnishing, not the palette.
    field(:furnishing, :map)

    # What part of a form this component plays. Validated by `MishkaCmsCore.Builder.FormRole` at the
    # point of use, not here: it arrives from a third party's `extra` and a malformed one must cost
    # the declaration, not the palette.
    field(:form, :map)
    # The glyph the palette draws for this component. Authored in the component's own `extra.icon`
    # when someone has set one; otherwise `nil`, and the panel suggests one from the name and type.
    field(:icon, :string, derives: "sanitize(trim)")

    # The kit's own documentation page for this component. Carried on the entry because both places
    # that would offer it — the inspector's header and the examples modal's — read the entry, not the
    # row.
    field(:doc_url, :string, derives: "sanitize(trim)")
    field(:render, any())
    # Every assign this component's own markup and helpers read, scanned once when the entry is
    # built. It is derived from `template` and `helpers` and nothing else, so it cannot go stale
    # while the entry lives — and the scan is over the component's whole source, which is why it
    # must not run per render. `seeded/3` used to call it on every palette card, several times each:
    # ~180 cards × the join and the regex, on every event that touched the chrome.
    field(:reads, any())

    # Whether this entry's component keeps state, and therefore whether a drop of it has to carry an
    # `id`. A `Phoenix.LiveComponent` cannot exist without one, so this is not decoration: it is what
    # `EditorSession` asks before it mints.
    field(:stateful?, :boolean, default: false)
  end

  @doc """
  Builds a descriptor, raising on an invalid one.

  Extensions declare these in module attributes, so a malformed descriptor fails the build rather
  than the page — the `Dashboard.Widget` precedent.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case builder(defaults(attrs)) do
      {:ok, entry} -> entry
      error -> raise ArgumentError, "invalid palette entry #{inspect(attrs)}: #{inspect(error)}"
    end
  end

  @doc "Builds a descriptor, returning `{:error, _}` instead of raising — for untrusted input."
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(attrs), do: builder(defaults(attrs))

  defp defaults(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> then(fn attrs ->
      name = attrs["name"]

      attrs
      |> Map.put_new("key", name)
      |> Map.put_new("label", humanize(name))
      |> Map.put_new("reads", scan_reads(attrs))
    end)
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp humanize(nil), do: nil

  defp humanize(name) do
    name
    |> String.replace(["-", "_"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  The HEEx this entry inserts.

  A database component becomes the wrapper form every stored template already uses; a descriptor
  with a `render` ref becomes a module call.

  A TENANT component is bound to the page's own site; a GLOBAL one is bound to `"Global"` whatever
  page it lands on. That distinction is not cosmetic: the compiled module's name is hashed from this
  attribute, so binding a global component to the page's site named a module nobody ever built and
  the canvas showed the runtime's red "failed to render" the moment it was dropped.

  `components` is the palette, which decides whether a component calling another owns a form.
  """
  @spec template(t() | map(), String.t() | nil, [map()]) :: String.t()
  def template(entry, site, components \\ [])

  def template(%{render: {module, function}}, _site, _components),
    do: "<#{inspect(module)}.#{function} />"

  def template(%{name: name} = entry, site, components) do
    # WHAT THE COMPONENT ARRIVES AS. A furnishing may say more than what goes inside — a gallery is a
    # grid, and one dropped without a column count is a vertical stack. Written before the seeds and
    # named in their `skip`, so the two cannot both emit the same attribute.
    furnished = Starter.attrs(entry)

    written =
      Enum.map_join(furnished, fn {name, value} -> " #{name}=#{furnished_value(value)}" end)

    open =
      ~s(<.component component_name="#{name}" site="#{scope(entry, site)}"#{written}#{seeded(entry, Map.keys(furnished), :blank, components)})

    # FURNISHED. A component dropped with nothing inside is a blank strip the author has to open the
    # inspector to identify — see `MishkaCmsCore.Runtime.PageBuilder.Starter`.
    case seeded_slots(entry) <> Starter.body(entry) do
      "" -> open <> " />"
      inside -> open <> ">" <> inside <> "</.component>"
    end
  end

  # A WORD IS AN ATTRIBUTE; A LIST IS AN EXPRESSION. `cols="three"` and `media={[%{src: …}]}` are the
  # same declaration in the furnishing and two different things in HEEx.
  defp furnished_value({:expr, term}),
    do: "{" <> inspect(term, limit: :infinity, printable_limit: :infinity) <> "}"

  defp furnished_value(value), do: ~s("#{value}")

  defp scope(%{global?: false}, site), do: site || "Global"
  defp scope(_global, _site), do: "Global"

  @doc """
  The required attributes a component cannot render without, written as HEEx attribute text.

  A REQUIRED attribute with no default is an assign the component's own template reads and nothing
  supplies — `@source` on `chelekom-video`, `@id` on `chelekom-banner` — and reading a missing assign
  raises `KeyError`, which takes the whole canvas LiveView down with it the instant the component is
  dropped. Seeding those attributes is what makes dropping one survivable; the value is a placeholder
  the author then edits in the inspector, and every other attribute is left alone so the component's
  own defaults keep applying.

  `style` is `:blank` for PLACEMENT and `:preview` for the wizard. Placement leaves a required value
  empty on purpose — the inspector marks it "Required" and the save refuses until the author fills
  it, which is the guard against publishing an incomplete page. A preview has no author to wait for,
  so it uses a real placeholder: an empty `src` renders as "needs src" rather than as an image.

  Public because the palette is not the only place that has to produce a RENDERABLE component:
  `MishkaCmsCore.Runtime.PageBuilder.Wizard` composes one too, and without the same seeding its
  preview showed "needs id" instead of the component, which made every option in the wizard look
  broken.

  `skip` names attributes the caller is writing itself, so the two cannot both emit one.
  `components` is the palette, which decides whether a component calling another owns a form.
  """
  @spec seeded(map(), [String.t()], :blank | :preview, [map()]) :: String.t()
  def seeded(entry, skip \\ [], style \\ :blank, components \\ [])

  def seeded(%{attrs: attrs} = entry, skip, style, components) when is_list(attrs) do
    reads = assign_reads(entry)

    attrs
    |> Enum.filter(&(seed?(&1, entry, reads) and attr_name(&1) not in skip))
    |> Enum.map_join(&~s( #{attr_name(&1)}=#{seed_value(&1, entry, style, components)}))
  end

  def seeded(_entry, _skip, _style, _components), do: ""

  # A REQUIRED SLOT is the same trap wearing different clothes: Phoenix assigns `[]` for an omitted
  # optional slot but nothing at all for a required one, so `<source :for={s <- @source}>` in
  # `chelekom-video` raised the moment the component was dropped and took the canvas with it. An
  # empty entry is enough to make the assign exist; its own required attributes are seeded the same
  # way the component's are.
  @doc """
  The required slots a component cannot render without, written as HEEx slot text.

  A REQUIRED SLOT is the same trap wearing different clothes — see `seeded/2`. Public for the same
  reason.
  """
  @spec seeded_slots(map(), :blank | :preview) :: String.t()
  def seeded_slots(entry, style \\ :blank)

  def seeded_slots(%{slots: slots} = entry, style) when is_list(slots) do
    furnished = sample_slots(entry, style)

    slots
    |> Enum.filter(&(required_slot?(&1) and attr_name(&1) not in furnished_names(entry)))
    |> Enum.map_join(fn slot ->
      name = attr_name(slot)

      ~s(<:#{name}#{seeded(%{attrs: field(slot, "attrs") || [], template: ""}, [], style)}></:#{name}>)
    end)
    |> Kernel.<>(furnished)
  end

  def seeded_slots(_entry, _style), do: ""

  # A component whose content is a LIST — an accordion's sections, a select's options — arrives with
  # a couple of them, or it drops as an empty box. `Starter` owns the copy; this owns the markup, so
  # a sample entry still gets its slot's own required attributes seeded exactly as an empty one does.
  defp sample_slots(entry, style) do
    Enum.map_join(Starter.slot_samples(entry), fn {name, attrs, body} ->
      declared = Enum.find(slots_of(entry), &(attr_name(&1) == name))
      written = Enum.map_join(attrs, fn {key, value} -> ~s( #{key}="#{value}") end)

      seeded =
        seeded(%{attrs: field(declared, "attrs") || [], template: ""}, Map.keys(attrs), style)

      ~s(<:#{name}#{written}#{seeded}>#{body}</:#{name}>)
    end)
  end

  defp furnished_names(entry) do
    for {name, _attrs, _body} <- Starter.slot_samples(entry), uniq: true, do: name
  end

  defp slots_of(entry) do
    case field(entry, "slots") do
      slots when is_list(slots) -> slots
      _other -> []
    end
  end

  # `inner_block` is content, not a slot anyone writes: the HEEx compiler refuses the name outright.
  defp required_slot?(slot) do
    truthy?(field(attr_opts(slot), "required")) and attr_name(slot) not in ["inner_block", nil]
  end

  # An attribute with NO DEFAULT is not merely optional — Phoenix sets no assign for it at all, so
  # the component's own `@name` raises `KeyError` and the render dies. `chelekom-tel-field` declares
  # `name` and `value` that way and reads both, which is why its preview answered HTTP 500 rather
  # than a phone field.
  #
  # So `required` is not the test; "the template reads it and nothing supplies it" is. A required
  # attribute still seeds even when the template never mentions it directly, because a required one
  # is a promise the caller is expected to keep.
  defp seed?(attr, entry, reads) do
    opts = attr_opts(attr)

    (identity?(attr_name(attr)) or not defaulted?(opts)) and
      attr_type(attr) not in ["global", "struct"] and
      (truthy?(field(opts, "required")) or read_without_default?(attr_name(attr), reads) or
         control_value?(attr_name(attr), entry))
  end

  # AN ID IS THE ONE ATTRIBUTE A DECLARED `nil` DEFAULT DOES NOT SETTLE, and it is the same reason
  # `string_seed/2` mints one whatever the style: a component builds its own handlers out of it —
  # `chelekom-banner`'s dismiss is `JS.push(…) |> hide_banner("##{@id}")` — and `nil` there makes the
  # selector `"#"`, which matches nothing. The component renders, and its one control does nothing,
  # silently. So an id seeds even where the kit declares `default: nil`, which is where all of them
  # declare it.
  defp identity?("id"), do: true
  defp identity?(name) when is_binary(name), do: String.ends_with?(name, "_id")
  defp identity?(_name), do: false

  # `default: nil` IS A DEFAULT. Asking `is_nil(opts["default"])` cannot tell an attribute DECLARED
  # with a nil default from one that declares no default at all, and the kit is mostly the first
  # kind: 584 of its attributes say `"default": null` against 249 that say nothing. Phoenix's own
  # wrapper merges a declared default in whatever its value — `attr_defaults` in
  # `Phoenix.Component.Declarative` collects every non-required attr whose opts HAVE the key — so
  # `@icon` on a component that declares `default: nil` always exists and can never raise.
  #
  # Seeding it anyway is what broke ten components. Every one of them declares
  # `icon` as `default: nil, editor: "icon"`, guards it as `:if={@icon}`, and forwards it to
  # `chelekom-icon`; seeded `icon=""` the guard passes, because `""` is truthy in Elixir, and the
  # icon is asked to render a name it refuses. Left alone, `@icon` is `nil`, the guard does its job,
  # and the component renders exactly as its author meant it to.
  #
  # Key presence, not value, is therefore the question — and it is asked of both shapes, because an
  # entry reaches here as a decoded JSON map with string keys or as a struct-built one with atoms.
  defp defaulted?(opts) when is_map(opts),
    do: Map.has_key?(opts, "default") or Map.has_key?(opts, :default)

  defp defaulted?(_opts), do: false

  # AND THE SCAN CANNOT SEE EVERYTHING. A component that hands its assigns to another one through an
  # `{assigns}` splat reads nothing itself, so the assign that raises belongs to a delegate the scan
  # never visits — `chelekom-input` needs a `value` its own markup never mentions.
  #
  # An element that renders a form control needs the two attributes every form control has. That is
  # the HTML, not a guess about naming.
  @controls ~w(<input <textarea <select)
  @control_values ~w(name value)

  defp control_value?(name, entry) do
    name in @control_values and String.contains?(body_of(entry), @controls)
  end

  defp body_of(entry) do
    [field(entry, "template") | Enum.map(helpers_of(entry), &helper_code/1)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # THE RULE IS THE ONE STATED ABOVE, not a list of names. It was `~w(name value)`, which is the pair
  # that happened to be found first — and five of the kit's own form components read something else
  # the same way and crashed on being dropped: `chelekom-date-time-field` on `@label`,
  # `chelekom-form-wrapper` on `@for`, and three more.
  #
  # Hard-coding the vocabulary meant the next one would crash too. What is seeded is what the
  # template READS and nothing supplies, whatever it is called.
  #
  # Seeding is blank, not "Example", so a component that was rendering perfectly well gains an empty
  # attribute and looks exactly as it did.
  defp read_without_default?(name, reads), do: MapSet.member?(reads, name)

  # Every assign the component can read: its own template plus each helper body.
  #
  # Taken off the entry when it is there, because `new!/1` scanned it once at build time. The ad-hoc
  # maps this module builds for slot seeding carry no `reads`, and neither does a plain map passed
  # in by a caller, so the scan stays as the fallback rather than a requirement.
  defp assign_reads(%{reads: %MapSet{} = reads}), do: reads
  defp assign_reads(entry), do: scan_reads(entry)

  # WHAT A COMPONENT HIDES FROM ITS OWN AUTHOR. A dialog, an off-canvas panel and a collapsible all
  # render closed, and they do it in their MARKUP rather than through an attribute — the kit writes
  # `class={["relative z-50 hidden", @class]}` on the modal, so nothing the editor can set will open
  # it. Everything the author drops inside one is invisible from the moment it lands: measured on a
  # real canvas, a dropped `chelekom-modal` has a full subtree and a height of zero.
  #
  # Eight of the kit's components do it to content the author owns. This is what puts the third glyph
  # on their layers row, beside the eye and the lock.
  #
  # Read off the template the same way `reads/1` is, and for the same reason: the palette carries the
  # ANSWER rather than the source, because the source is the heaviest thing a component owns.
  @concealers ~w(hidden invisible opacity-0 max-h-0 -translate-x-full -translate-y-full
                 translate-x-full translate-y-full)

  @doc """
  Whether this component renders its own content closed — a dialog, a drawer, a collapsible.

  A DECLARATION FIRST, a guess only when there is none. `opens/1` reads what the component itself
  says; the markup scan below is what answers for the hundred and thirty-six that were written
  before there was anything to say it with. Same contract as `opts["editor"]` on an attribute and
  `extra.furnishing` on a row: what the author declared wins, and inference is the fallback.

  The guess is deliberately a generous one: the cost of a wrong yes is a glyph on a row that did not
  need it, and the cost of a wrong no is content the author cannot see at all.
  """
  @spec concealed?(map()) :: boolean()
  def concealed?(entry) do
    case field(entry, "template") do
      template when is_binary(template) -> opens(entry) != %{} or conceals?(template)
      _nothing -> false
    end
  end

  # A SELECTOR THAT WOULD MATCH THE EDITOR'S OWN BOX. `[&>*]:rounded-none` and
  # `[&>*:not(:last-child)]:border-r` reach for whatever element is immediately inside, which on the
  # canvas is the wrapper rather than the button. `[&>li]`, `[&>img]`, `[&>.quote-icon]` cannot match
  # a bare `<div>`, so they are not this — and a kit's `li` is stamped anyway for being an `li`.
  #
  # The kit writes these in its template AND in its helper bodies, which is where
  # `chelekom-button-group`'s own `[&>*]:rounded-none [&>*]:border-0` lives.
  @child_selectors ~r/\[&\s*>\s*(?:\*|div)(?![\w-])/

  @doc """
  Whether this component styles the children an author puts inside it.

  A component that writes `[&>*]:rounded-none` means the element immediately inside it, and the
  editor's own wrapper around each of those children is what the rule lands on instead. That is why
  a `chelekom-button-group` drew three separately rounded buttons on the canvas and one joined
  control on the page: the CSS was never reaching the buttons at all.

  Read off the TEMPLATE AND THE HELPER BODIES, once, where the source is still in hand — see the
  note on `reads/1` in `palette_entry/1`'s caller for why it cannot be asked again later.

  A bare string is asked the same question: `<div class="[&>*]:rounded-none">` is an author making
  the same promise by hand, and the canvas has to keep it the same way.
  """
  @spec shapes_children?(map() | String.t() | nil) :: boolean()
  def shapes_children?(source) when is_binary(source),
    do: Regex.match?(@child_selectors, source)

  def shapes_children?(entry) when is_map(entry) do
    [field(entry, "template"), field(entry, "body")]
    |> Enum.concat(helper_bodies(entry))
    |> Enum.any?(&shapes_children?/1)
  end

  def shapes_children?(_nothing), do: false

  defp helper_bodies(entry) do
    case field(entry, "helpers") do
      helpers when is_list(helpers) -> Enum.map(helpers, &field(&1, "code"))
      _nothing -> []
    end
  end

  @doc """
  The open/close commands this component declares on its own root element.

  ## Why a component has to say it

  Because "open it" is not one thing. A dialog is `display:none` on the root AND `display:none` again
  on the panel inside it, so revealing the root paints the backdrop over a page and shows no dialog.
  A drawer is fully displayed and held off-screen by `-translate-x-full`. A dropdown is opened by a
  JavaScript hook that removes a boolean attribute and adds three classes. A navbar wants one class
  toggled on the very element the editor is already pointing at. One generic `JS.show` is right for
  exactly one of those shapes and silently does nothing for the rest — which is what it did.

  The component is the only thing that knows which of those it is, so it is the thing that says:

      <div id={@id} data-pb-open={show_modal(@id)} data-pb-close={hide_modal(@id)} class={[…]}>

  The value is an ordinary `Phoenix.LiveView.JS` command — the same shape as the `data-cancel` the
  kit's own dialogs already carry, and `chelekom-mega-menu` already ships this exact pattern under
  its own name (`phx-open-mega`, run with `JS.exec/2` from its trigger). A button aimed at the
  component compiles to `JS.exec("data-pb-open", to: ".pb-xxxxxxxx")`, so what runs is the
  component's own sequence — every transition, the body scroll lock, the focus trap — rather than
  the editor's guess at it.

  Declaring nothing still works: a component that renders closed with no declaration keeps the
  layers glyph on inference, and a click aimed at it keeps compiling to the plain `JS` verb.

  Returns `%{verb => attribute}` for the verbs actually declared, `%{}` for none.
  """
  @spec opens(map()) :: %{optional(String.t()) => String.t()}
  def opens(entry) do
    case field(entry, "template") do
      template when is_binary(template) -> declared_openers(template)
      _nothing -> %{}
    end
  end

  # ON THE ROOT, not anywhere in the markup. `JS.exec(attr, to: ".pb-xxxxxxxx")` runs the command
  # held by the element carrying the scope class, and the scope class lands on the component's own
  # outermost element — so a declaration on a descendant is one the click could never reach, and
  # reporting it would trade a command that does nothing for a command that does nothing loudly.
  #
  # The cheap test first: parsing a template is real work and 136 of them go past here on every
  # palette build, while `data-pb-` appears in none of the ones that declare nothing.
  defp declared_openers(template) do
    case String.contains?(template, "data-pb-") do
      false -> %{}
      true -> root_openers(template)
    end
  end

  # EVERY ROOT, NOT THE FIRST ONE. A component may be written as two alternative roots —
  # `<span :if={@inline}>` and `<div :if={!@inline}>` — and exactly one of them renders. Reading the
  # first meant the editor promised an Open button off a branch that was switched off by default:
  # `chelekom-tooltip` and `chelekom-popover` both declared their three commands on the inline root
  # (twice over) and none on the one their `inline` default actually draws, so the button was there
  # and nothing happened. What the editor can promise is what every root agrees on.
  defp root_openers(template) do
    case Tree.parse(template) do
      {:ok, tree} -> tree |> Tree.children(:root) |> Enum.filter(&element?/1) |> agreed_openers()
      {:error, _unparseable} -> %{}
    end
  end

  defp element?(%Node{kind: kind}), do: kind in [:tag, :component]
  defp element?(_node), do: false

  defp agreed_openers([]), do: %{}

  defp agreed_openers([root | rest]) do
    Enum.reduce(rest, openers_on(root), fn node, agreed ->
      node |> openers_on() |> Map.take(Map.keys(agreed))
    end)
  end

  defp openers_on(%Node{} = node) do
    for {verb, attribute} <- Interactions.openers(),
        Node.attr(node, attribute),
        into: %{},
        do: {verb, attribute}
  end

  defp openers_on(_nothing), do: %{}

  # A HIDING CLASS IS NOT ENOUGH ON ITS OWN. Half the kit carries one: a checkbox hides its real
  # `<input>` behind a drawn box, a timeline hides a rule below `sm:`, a scroll area hides its idle
  # scrollbar. Counting those put the glyph on twenty-six components and meant nothing on twenty of
  # them. What separates the ones this is for is the SECOND signal — the thing an overlay or a
  # collapsible has and a hidden input never does.
  # `data-floating-content` IS THE KIT'S OWN WORD FOR THE PANEL. A dropdown's content, a popover's
  # and a tooltip's are each a separate component the author drops on its own, and each hides itself
  # with a bare `hidden` and nothing else from this list — no dialog role, no click-away, those live
  # on the PARENT. So none of them counted as concealed, none got the `data-pb-overlay` wrapper the
  # canvas reveals through, and an author who selected one saw the trigger and no panel: "we cannot
  # add any content inside the dropdown content".
  @overlay_signals [
    "aria-modal",
    ~s(role="dialog"),
    ~s(role="tooltip"),
    "phx-click-away",
    "phx-window-keydown",
    "max-h-0",
    "data-floating-content"
  ]

  # TWO SHAPES, AND THE KIT USES BOTH. `chelekom-modal` writes the plain utility —
  # `class={["relative z-50 hidden", @class]}` — while `chelekom-drawer`, `chelekom-dropdown` and
  # `chelekom-speed-dial` hide a CHILD through an arbitrary variant:
  # `[&.drawer-overlay]:opacity-0`, `[&>.dropdown-content]:invisible`. Reading only the first shape
  # found the modal and missed the drawer, which is the other component this exists for.
  #
  # The second shape needs no corroboration: a component that toggles its own child's visibility by
  # class is an overlay, and a hidden `<input>` behind a drawn checkbox never does it. The first does,
  # because a bare `hidden` is also how a form control hides its real input.
  defp conceals?(template) do
    variant_hider?(template) or
      (bare_hider?(template) and Enum.any?(@overlay_signals, &String.contains?(template, &1)))
  end

  defp variant_hider?(template),
    do: Enum.any?(@concealers, &Regex.match?(~r/\]:#{Regex.escape(&1)}(?![-\w])/, template))

  defp bare_hider?(template) do
    String.contains?(template, "display:none") or String.contains?(template, "display: none") or
      Enum.any?(@concealers, &class_token?(template, &1))
  end

  # A CLASS, NOT A SUBSTRING, and not a condition on one. `hidden` sits inside `aria-hidden` on
  # nearly every component with a decorative element and inside `overflow-hidden` on most of the
  # rest, while `sm:hidden` and `peer-checked:hidden` describe a state the component enters rather
  # than the one it rests in.
  defp class_token?(template, token) do
    Regex.match?(~r/(?<![-:\w])#{Regex.escape(token)}(?![-\w])/, template)
  end

  @doc """
  Every assign a component's own markup and helpers read.

  Public because the palette builds its entries as plain maps rather than through `new!/1`, and this
  is what lets it carry the answer instead of the source: `helpers` is 87% of a palette's weight and
  the only runtime questions asked of it are this scan and `Inspector.features/1`, both of which are
  computed once when the palette is read.
  """
  @spec reads(map()) :: MapSet.t()
  def reads(component), do: scan_reads(component)

  defp scan_reads(entry) do
    [field(entry, "template") | Enum.map(helpers_of(entry), &helper_code/1)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> then(&Regex.scan(~r/@([a-zA-Z_][a-zA-Z_0-9]*)/, &1))
    |> MapSet.new(&Enum.at(&1, 1))
  end

  defp helpers_of(entry) do
    case field(entry, "helpers") do
      helpers when is_list(helpers) -> helpers
      _other -> []
    end
  end

  defp helper_code(helper) do
    case field(helper, "code") do
      code when is_binary(code) -> code
      _other -> ""
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_other), do: false

  # The first declared option when there is one — a value the component actually handles beats a
  # neutral literal it may have no clause for. Otherwise the type's own empty value.
  #
  # `id` is the exception, and it earns it: an empty one is not a neutral placeholder but a broken
  # component. `chelekom-banner` builds its dismiss handler as `JS.push(…) |> hide_banner("##{@id}")`
  # — with `id=""` that selector is `"#"`, which matches nothing, so the control renders and does
  # nothing. Minting one costs nothing and the author can still rename it.
  @scalars ["boolean", "integer", "float", "pos_integer", "atom"]
  @containers ["map", "list", "keyword_list"]

  # A FORM'S DATA STRUCTURE IS NOT A STRING. `Phoenix.Component.form/1` hands `for` to `to_form/2`,
  # and `Phoenix.HTML.FormData` has no implementation for `""` — so a dropped `chelekom-simple-form`,
  # which REQUIRES one, raised a protocol error where every other seed was harmless text. An empty
  # map is the one value `to_form/2` takes, and it means "no data yet".
  #
  # Only where the component requires it: `for` on a `<label>` is an element id, and a map there is
  # simply a different crash. Required is the component saying the value is its own to hand on.
  # Which components own a form is `MishkaCmsCore.Runtime.PageBuilder.Fields`' question, and it has
  # one answer for the whole editor: a declared role, a template that parses to a form node, a
  # `for` the component declares required, or a template whose one outer element is a component
  # that owns one, read from `components`. `chelekom-simple-form` is the third of those — it hands
  # `for` straight on to `chelekom-form-wrapper` through an `{assigns}` splat, so its own template
  # never mentions a form at all.
  defp seed_value(attr, entry, style, components) do
    case attr_name(attr) == "for" and Fields.wrapper?(entry, components) do
      true -> "{%{}}"
      false -> scalar_seed(attr, style)
    end
  end

  # ZERO IS THE ONE NUMBER THAT CAN RENDER AS NOTHING. Placement leaves a required STRING empty on
  # purpose — the inspector marks it Required and the save refuses until it is filled. A number has
  # no empty: `blank_attr?/2` reads the text "0" as filled, so a numeric seed is a value the author
  # is never told to replace, and it had better be one the component can draw. `chelekom-pagination`
  # builds `range(1, total)`, which for zero is the empty list, so a dropped pagination rendered two
  # disabled arrows and no page at all — reported as "the color of text is just white and wont show".
  #
  # Small rather than typical: the three required numerics in the kit are a page count and two
  # percentages, and a low number reads as a sample in all three while a high one reads as a page
  # with two hundred pages on it.
  @sample_number 3

  defp scalar_seed(attr, style) do
    case {attr_name(attr), attr_values(attr), attr_type(attr)} do
      {name, [], type} when type in @containers ->
        container_seed(name, type, style)

      {_name, [], "string"} = signature ->
        icon_or_string(icon_attr?(attr), signature, style)

      {name, [], type} when type not in @scalars ->
        ~s("#{string_seed(name, style)}")

      {_name, [first | _rest], "atom"} ->
        "{:#{first}}"

      {_name, [first | _rest], _type} ->
        ~s("#{first}")

      {_name, [], "boolean"} ->
        "{false}"

      {_name, [], type} when type in ["integer", "float", "pos_integer"] ->
        "{#{@sample_number}}"

      {_name, [], "atom"} ->
        "{nil}"
    end
  end

  # A MAP OR LIST ATTRIBUTE MUST BE SEEDED WITH ONE. Every non-scalar type used to fall through to
  # the string clause, so a required `flash` map was written `flash="example"` and the component's
  # own `Phoenix.Flash.get(@flash, :info)` called `Map.get/2` on a binary — a BadMapError that took
  # the whole preview LiveView down, and the reader saw the wizard tab return a 500. The type is
  # declared on the attribute; nothing had to be guessed, it was simply never read.
  #
  # `flash` is named because it is a PHOENIX convention rather than a kit's: `Phoenix.Flash.get/2`
  # reads string keys, and every flash component in every kit will take the same shape. An empty map
  # is valid but renders nothing at all, which is indistinguishable from the crash it replaced.
  defp container_seed("flash", "map", :preview),
    do: ~s({%{"info" => "Your changes have been saved.", "error" => "Something went wrong."}})

  defp container_seed(_name, "map", _style), do: "{%{}}"
  defp container_seed(_name, _list, _style), do: "{[]}"

  # A 1x1 transparent GIF. It resolves without a network round trip and without depending on any
  # asset this install may not have, which is what a placeholder has to do.
  @placeholder_image "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

  # AN ICON IS A NAME THE COMPONENT PARSES, not free text. `chelekom-icon` renders
  # `<span class={[@name, @class]}>` and gates on the name's shape — its body is
  # `%{name: "hero-" <> _} = assigns`, a function head the kit exporter turned into an assertion — so
  # a blank one is not "not filled in yet", it is a MatchError that took the render down. Dropped
  # from the palette, that was `chelekom-icon` itself and, through the icon each forwards, nine more:
  # badge, button, button-link, card-title, content-item, li, mega-menu, speed-dial and
  # stepper-section.
  #
  # The kit already says which attributes these are — `"editor": "icon"`, the same key the inspector
  # reads to offer its icon picker — so the seed is chosen from what the component declared rather
  # than from its name. A real icon renders, and the picker is one click from changing it.
  @placeholder_icon "hero-star"

  # BLANK ON PLACEMENT, A REAL ICON EVERYWHERE ELSE — the same split the rest of this module makes,
  # and it took a wrong turn to see why. Seeding a real icon on placement did stop the crash, and it
  # did it by switching OFF the editor's own answer for the one component that most needs it: a blank
  # required value is what makes the canvas draw "chelekom-icon needs name", what marks the row
  # Required in the Inspector, and what refuses the publish. An author got a star they had not
  # chosen, and every guard that would have asked them to choose one was satisfied.
  #
  # The crash it was avoiding is answered where it belongs now: `ComponentCompiler` catches a body
  # that refuses its assigns, so a name the kit rejects renders without it instead of taking a
  # published page down.
  #
  # `:preview` keeps the real icon, because a preview has nobody to wait for: the wizard and the
  # palette's hover card have to show the component, and "needs name" is not the component.
  defp icon_or_string(true, _signature, :preview), do: ~s("#{@placeholder_icon}")

  defp icon_or_string(true, {name, _values, _type}, style),
    do: ~s("#{string_seed(name, style)}")

  defp icon_or_string(false, {name, _values, _type}, style),
    do: ~s("#{string_seed(name, style)}")

  defp icon_attr?(attr), do: field(attr_opts(attr), "editor") == "icon"

  # A required string attribute is one the component cannot render without, so an EMPTY placeholder
  # is no placeholder at all: the editor reads a blank required value as "still missing" and draws
  # "needs src" instead of the component — which is what `chelekom-image` and `chelekom-card-media`
  # showed in the wizard. Each of these gives the component something it can actually use.
  # An id is minted whatever the style: `""` is not a neutral placeholder but a broken component,
  # because components build their own handlers as `hide("##{@id}")` and `"#"` matches nothing.
  defp string_seed("id", _style), do: Phoenix.LiveView.Utils.random_id()

  defp string_seed(name, style) when is_binary(name) do
    cond do
      String.ends_with?(name, "_id") -> Phoenix.LiveView.Utils.random_id()
      style == :blank -> ""
      name in ~w(src image poster) -> @placeholder_image
      name in ~w(href navigate patch link url) -> "#"
      name in ~w(alt title label text name) -> "Example"
      true -> "example"
    end
  end

  defp string_seed(_name, _style), do: ""

  defp attr_name(%{"name" => name}), do: name
  defp attr_name(%{name: name}), do: name
  defp attr_name(_attr), do: nil

  defp attr_type(attr), do: field(attr, "type") || "string"
  defp attr_opts(attr), do: field(attr, "opts") || %{}

  defp attr_values(attr) do
    case field(attr_opts(attr), "values") do
      values when is_list(values) -> Enum.reject(values, &is_nil/1)
      _other -> []
    end
  end

  # An attribute reaches here two ways and they do not agree on key type: a database component row
  # carries string keys, and a descriptor built through `new!/1` has been through GuardedStruct,
  # which atomises nested maps. Reading only one shape is why the seeding silently did nothing for
  # every kit component.
  defp field(map, key) when is_map(map) do
    case map do
      %{^key => value} -> value
      %{} -> Map.get(map, String.to_existing_atom(key))
    end
  end

  defp field(_map, _key), do: nil

  @doc """
  Reads an optional field off an entry, whichever shape it arrived in.

  THE PALETTE HOLDS TWO SHAPES AND ALWAYS WILL. The core builds a plain map with everything it
  learned in the read that filled the palette; a plugin contributes a `%PaletteEntry{}`, which is
  the documented way to add one and carries only the fields this struct declares. Asking a struct
  for `entry[:has_examples?]` raises — structs have no `Access` — so a single contributed component
  took the whole palette down, and with it the editor.

  Answers `nil` for a field the entry does not carry, which for every optional field is the honest
  answer: a contributed component has no examples to browse until it says it does.
  """
  @spec optional(t() | map(), atom()) :: term()
  def optional(entry, key) when is_map(entry) and is_atom(key), do: Map.get(entry, key)
  def optional(_entry, _key), do: nil

  @doc "Whether this entry renders through an extension module rather than a stored template."
  @spec module_component?(t() | map()) :: boolean()
  def module_component?(%{render: {_module, _function}}), do: true
  def module_component?(_entry), do: false

  @doc """
  The set of modules the editor is permitted to emit a call to — every module a registered
  descriptor named, and nothing else.
  """
  @spec whitelist([t() | map()]) :: MapSet.t(module())
  def whitelist(entries) do
    for %{render: {module, _function}} <- entries, into: MapSet.new(), do: module
  end

  @doc """
  Whether `template` only calls modules in `whitelist`. A template naming an unregistered module is
  refused rather than compiled.
  """
  @spec permitted?(String.t(), MapSet.t(module())) :: boolean()
  def permitted?(template, whitelist) when is_binary(template) do
    ~r/<([A-Z][A-Za-z0-9_.]*)\./
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.all?(fn [name] -> MapSet.member?(whitelist, Module.concat([name])) end)
  end
end
