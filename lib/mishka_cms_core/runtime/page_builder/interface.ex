defmodule MishkaCmsCore.Runtime.PageBuilder.Interface do
  @moduledoc """
  A component's INTERFACE — the attributes and slots it declares — as data the editor can edit and
  check.

  ## Why this exists

  A runtime component is markup plus a declaration, and until now the builder could only edit the
  markup. The declaration lives in the `attrs` and `slots` columns of
  `MishkaCmsCore.Runtime.Resources.Component`, and the only way to touch it was the Components table
  form, where a slot's options are a raw JSON textarea. Meanwhile that same declaration drives almost
  everything the page builder does with the component: which controls the Inspector offers, what
  `.properties` and `.slots` list, which properties are marked required, whether a drop into a slot
  is allowed at all.

  So an author could build a component visually and had no way to say what it takes — and a template
  that reads `@size` without `attr :size` does not fail at save time. It compiles, and then raises
  `KeyError` the first time the component renders on a page, which is the same shape as the
  `key :src not found` an empty required slot attribute used to produce.

  ## What it checks

  `validate/2` refuses the declaration itself: a name that is not a valid Elixir identifier, a
  duplicate, an unknown type, a struct attribute with no module, and the one combination Phoenix
  rejects outright — `required: true` together with a default.

  `undeclared/3` is the other direction, and the one that catches the KeyError before it happens: it
  reads the template for assigns and slots the declaration does not mention. `site` and
  `component_name` are never reported, because
  `MishkaCmsCore.Runtime.Compilers.ComponentCompiler` declares both on every runtime component.

  Reading a template with a regex has the limits `MishkaCmsCore.Runtime.PageBuilder.Inspector`'s
  `renders_slot?/2` documents, and the same rule applies here: this is ADVICE, shown beside a button
  that writes the declaration for you. It never refuses a save, so a false positive costs a line of
  text and never a blocked author.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @typedoc "One declared attribute, as it is stored on the resource."
  @type attr :: %{String.t() => term()}

  @typedoc "One declared slot, as it is stored on the resource."
  @type slot :: %{String.t() => term()}

  # The list Phoenix accepts, in the order the Components form already offers them, so the two
  # surfaces cannot drift into offering different vocabularies for one column.
  @types ~w(string integer float boolean atom list map any global struct)

  # Declared for every runtime component by the compiler itself — the kit rewriter emits
  # `site={@site}` and `component_name={…}` in parent-to-child dispatches, so both are always
  # readable and neither is ever the author's to declare.
  @implicit ~w(site component_name)

  # `@inner_block` is what `render_slot(@inner_block)` reads and it is declared as a SLOT, never as
  # an attribute, so it must not be offered as a missing one.
  @slot_like ~w(inner_block)

  @doc "Every attribute type this editor will write, in the order it offers them."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The attributes a record declares, always a list."
  @spec attrs(map() | nil) :: [attr()]
  def attrs(%{attrs: attrs}) when is_list(attrs), do: Enum.map(attrs, &stringify/1)
  def attrs(%{"attrs" => attrs}) when is_list(attrs), do: Enum.map(attrs, &stringify/1)
  def attrs(_record), do: []

  @doc "The slots a record declares, always a list."
  @spec slots(map() | nil) :: [slot()]
  def slots(%{slots: slots}) when is_list(slots), do: Enum.map(slots, &stringify/1)
  def slots(%{"slots" => slots}) when is_list(slots), do: Enum.map(slots, &stringify/1)
  def slots(_record), do: []

  @doc """
  What is wrong with this declaration, as `{kind, index, sentence}` for the row it belongs to.

  Empty means it can be written. The sentences are meant to be read by whoever is filling the form,
  so they say what to do rather than what rule was broken.
  """
  @spec validate([attr()], [slot()]) :: [{:attr | :slot, non_neg_integer(), String.t()}]
  def validate(attrs, slots) when is_list(attrs) and is_list(slots) do
    Enum.concat([
      named(attrs, :attr),
      named(slots, :slot),
      reserved(attrs),
      typed(attrs),
      defaulted(attrs),
      structured(attrs),
      slotted(slots)
    ])
  end

  def validate(_attrs, _slots), do: []

  defp named(rows, kind, rule \\ :identifier) do
    seen =
      rows
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), []}, fn {row, index}, {names, faults} ->
        name = value(row, "name")

        cond do
          name == "" ->
            {names, [{kind, index, gettext("Give this one a name.")} | faults]}

          not name?(rule, name) ->
            {names, [{kind, index, unnamed(name, rule)} | faults]}

          MapSet.member?(names, name) ->
            {names, [{kind, index, gettext("“%{name}” is declared twice.", name: name)} | faults]}

          true ->
            {MapSet.put(names, name), faults}
        end
      end)

    seen |> elem(1) |> Enum.reverse()
  end

  # A name reaches the compiler as `String.to_atom/1` and is written into a `def`, so anything that
  # is not an identifier is not a mistake to report later.
  defp name?(:identifier, name), do: Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*$/, name)

  # A SLOT'S ATTRIBUTE IS NEVER WRITTEN INTO A `def`: the compiler emits slots without their
  # attributes, and the entry reaches the template as a map read by `item[:"aria-label"]`. So an
  # HTML name is one, as Phoenix allows in a slot block — Chelekom's headless `toggle-group` declares
  # `aria-label` on its `item`.
  defp name?(:slot_attr, name), do: Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*(-[a-zA-Z0-9_]+)*$/, name)

  defp unnamed(name, :identifier),
    do:
      gettext(
        "“%{name}” cannot be a name — start with a lowercase letter and use letters, numbers and _ only.",
        name: name
      )

  defp unnamed(name, :slot_attr),
    do:
      gettext(
        "“%{name}” cannot be a name — start with a lowercase letter and use letters, numbers, _ and - between them only.",
        name: name
      )

  # Phoenix's own: "cannot define attribute called :inner_block. Maybe you wanted to use `slot`
  # instead?" — which is exactly the mistake, because `inner_block` is the slot name everybody knows
  # and declaring it as an attribute is the plausible wrong turn. A compile error either way; this
  # one says what to do about it.
  defp reserved(attrs) do
    for {attr, index} <- Enum.with_index(attrs),
        value(attr, "name") == "inner_block",
        do:
          {:attr, index,
           gettext("“inner_block” is a slot, not an attribute — declare it under Slots instead.")}
  end

  defp typed(attrs) do
    for {attr, index} <- Enum.with_index(attrs),
        type = value(attr, "type"),
        type != "",
        type not in @types,
        do: {:attr, index, gettext("“%{type}” is not a type this can declare.", type: type)}
  end

  # Phoenix's own rule, and it raises at compile time rather than reporting: "attributes should not
  # have a default value if they are required".
  defp defaulted(attrs) do
    for {attr, index} <- Enum.with_index(attrs),
        required?(attr),
        declared_default(attr) != "",
        do:
          {:attr, index,
           gettext("A required attribute cannot also have a default — it is one or the other.")}
  end

  defp structured(attrs) do
    for {attr, index} <- Enum.with_index(attrs),
        value(attr, "type") == "struct",
        value(attr, "struct_name") == "",
        do:
          {:attr, index,
           gettext("A struct attribute needs the module it holds, like Phoenix.HTML.FormField.")}
  end

  # A SLOT'S OWN ATTRIBUTES ARE CHECKED BY A SHORTER LIST THAN THE TOP-LEVEL ONES, and the reason is
  # in `MishkaCmsCore.Runtime.Compilers.ComponentCompiler.build_slots/1`: a runtime component's
  # slots are emitted WITHOUT their nested attr declarations, because the compiler builds them with
  # a function rather than Phoenix's macro and any `attr` inside the block would register at top
  # level and collide. So a slot attribute never reaches `__attr__!` and Phoenix's rules for one do
  # not apply to it — including the one that refuses `:default` inside a slot outright.
  #
  # What DOES apply is this editor's own use of them: the name is written into the markup as
  # `<:item kind="…">`, the type picks the control, and `default` is what seeds a required slot
  # attribute when a slot is inserted. So the name has to be a name, it may not be declared twice in
  # one slot, the type has to be one this editor can draw, and a struct still has to say which
  # struct. Required-with-a-default is not a fault here — it is the feature.
  #
  # Reported against the slot that holds them, with the offending attribute named by position,
  # because the slot is the row somebody can see and put right.
  defp slotted(slots) do
    for {slot, index} <- Enum.with_index(slots),
        attrs = held_attrs(slot),
        attrs != [],
        {_kind, inner, message} <- inner_faults(attrs),
        do:
          {:slot, index,
           gettext("attribute #%{number}: %{message}", number: inner + 1, message: message)}
  end

  defp inner_faults(attrs) do
    Enum.concat([named(attrs, :attr, :slot_attr), typed(attrs), structured(attrs)])
  end

  defp held_attrs(slot) do
    case slot |> stringify() |> Map.get("attrs") do
      rows when is_list(rows) -> Enum.map(rows, &stringify/1)
      _none -> []
    end
  end

  @doc """
  What the template reads and the declaration never mentions.

  `%{attrs: [names], slots: [names]}`, in the order they first appear, so the list reads the way the
  markup does. A name that is declared as a slot is never reported as a missing attribute, and the
  two the compiler always provides are never reported at all.
  """
  @spec undeclared(String.t() | nil, [attr()], [slot()]) :: %{
          attrs: [String.t()],
          slots: [String.t()]
        }
  def undeclared(template, attrs, slots) do
    source = to_string(template || "")
    declared_attrs = names(attrs)
    declared_slots = names(slots)

    used_slots = slot_reads(source)
    used_attrs = assign_reads(source)

    %{
      slots: Enum.reject(used_slots, &(&1 in declared_slots)),
      attrs:
        used_attrs
        |> Enum.reject(&(&1 in declared_attrs))
        |> Enum.reject(&(&1 in declared_slots))
        |> Enum.reject(&(&1 in used_slots))
        |> Enum.reject(&(&1 in @implicit))
        |> Enum.reject(&(&1 in @slot_like))
    }
  end

  # `render_slot(@name)` and the comprehension form Phoenix writes for a multi-slot. Both are read
  # here rather than in `Inspector.renders_slot?/2` because that one answers about a slot that IS
  # declared; this one is looking for the ones that are not.
  defp slot_reads(source) do
    direct = scan(source, ~r/render_slot\(\s*@([a-z_][a-zA-Z0-9_]*)/)
    looped = scan(source, ~r/:for=\{[^<]{0,90}<-[^}]{0,60}@([a-z_][a-zA-Z0-9_]*)/)

    rendered =
      Enum.filter(looped, fn name ->
        source
        |> scan(~r/:for=\{([^<]{0,90})<-[^}]{0,60}@#{Regex.escape(name)}\b/)
        |> Enum.any?(fn binder ->
          binder
          |> String.split(~r/[^a-z_0-9]/)
          |> Enum.any?(&String.contains?(source, "render_slot(#{&1})"))
        end)
      end)

    Enum.uniq(direct ++ rendered)
  end

  # Every `@name` the markup reads. HEEx has no other way to reach an assign, so this is the whole
  # surface — and an over-reading is a line of advice, never a refused save.
  defp assign_reads(source) do
    source
    |> scan(~r/@([a-z_][a-zA-Z0-9_]*)/)
    |> Enum.uniq()
  end

  defp scan(source, regex) do
    regex |> Regex.scan(source, capture: :all_but_first) |> Enum.map(&hd/1)
  end

  defp names(rows), do: Enum.map(rows, &value(&1, "name"))

  # THE SAME FACT, WRITTEN TWO WAYS. A row on its way out of the form carries `default` at the top
  # level; a row read back off the record carries it under `opts`, which is where the compiler and
  # `Inspector.default/1` look. Reading only the first meant the rule Phoenix enforces at compile
  # time was checked for a form submission and not for anything already stored.
  defp declared_default(row) do
    case row |> stringify() |> Map.get("opts") do
      %{} = opts -> opts |> Map.get("default") |> to_string() |> String.trim()
      _none -> ""
    end
    |> case do
      "" -> value(row, "default")
      found -> found
    end
  end

  @doc """
  Whether this row says it is required, whichever of the two shapes it is in.

  A row on its way out of the form carries `required` at the top level; a row read back off the
  record carries it under `opts`, which is where the compiler looks. Public because reading a
  declaration is not only this module's business — the layers rail draws the same rows.
  """
  @spec required?(attr() | slot()) :: boolean()
  def required?(row) do
    case row |> stringify() |> Map.get("opts") do
      %{} = opts -> Map.get(opts, "required") in [true, "true"]
      _none -> value(row, "required") in ["true", true, "on"]
    end
  end

  @doc """
  One field of a row as trimmed text, atom keys and string keys alike, `""` when it is not there.
  """
  @spec value(attr() | slot(), String.t()) :: String.t()
  def value(row, key) do
    row
    |> stringify()
    |> Map.get(key)
    |> to_string()
    |> String.trim()
  end

  defp stringify(%_struct{} = row), do: row |> Map.from_struct() |> stringify()

  defp stringify(%{} = row),
    do: Map.new(row, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify(row), do: row

  defp stringify_value(%{} = value) when not is_struct(value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), inner} end)

  defp stringify_value(value), do: value
end
