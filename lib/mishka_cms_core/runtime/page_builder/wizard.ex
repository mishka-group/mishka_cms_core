defmodule MishkaCmsCore.Runtime.PageBuilder.Wizard do
  @moduledoc """
  Composing a component from its own option lists, before anything is placed.

  ## What it is for

  The examples modal answers "show me one the kit already wrote". This answers the other question —
  "give me *this* one" — by turning the component's declared options into a form and the chosen
  values into the HEEx an insert places. The two share the modal, the preview pane and the insert
  path; only the source of the markup differs.

  It exists because an example is a fixed point. A kit ships twelve alerts and none of them is a
  small outline alert in the warning colour with an icon, so the author inserts the nearest one and
  then edits four properties in the inspector — which is the wizard, done by hand, without the
  preview.

  ## Where the options come from

  `Inspector.features/1`, the same fold the property panel uses, keyed by attribute after the
  axis→attribute binding (`UiKitHandler.axis_bindings/1`). So the wizard offers exactly the options
  the inspector will offer afterwards; a value that can be chosen here can be changed there.

  Only attributes with a real option list are offered — a picker over a free-text attribute would be
  an empty dropdown. `title`, `class` and friends are the inspector's job once the element is on the
  page.

  ## What it emits

  `compose/3` builds the same `<.component component_name=… site=…>` invocation the palette emits, so
  the result is an ordinary node: parsed by `Tree.parse/1`, containment-checked, undoable, and
  editable afterwards like anything else. Values equal to the component's own default are left out —
  writing `variant="default"` says nothing the component does not already say, and every one of them
  is another attribute the author has to read past later.
  """

  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.PageBuilder.CodeReads
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.Markup
  alias MishkaCmsCore.Runtime.PageBuilder.Starter

  @doc """
  The axes a wizard can offer: `[%{name:, label:, values:, default:, atom?:}]`.

  Ordered the way the panel orders properties, so the wizard and the inspector read the same way
  round. An attribute the component declares but has no option list for is skipped. `atom?` rides
  along because it changes how the value must be WRITTEN, not how it is chosen.
  """
  @spec axes(map()) :: [
          %{
            name: String.t(),
            label: String.t(),
            values: [String.t()],
            default: String.t() | nil,
            atom?: boolean()
          }
        ]
  def axes(entry) do
    features = features_of(entry)
    read = readable_assigns(entry)

    entry
    |> Inspector.grouped()
    |> Enum.flat_map(fn {_group, attrs} -> attrs end)
    |> Enum.filter(&(values_for(&1, features) != []))
    |> Enum.filter(&reads?(read, Inspector.name(&1)))
    |> Enum.map(fn attr ->
      %{
        name: Inspector.name(attr),
        label: Inspector.label(attr),
        values: values_for(attr, features),
        default: stringify(Inspector.default(attr)),
        atom?: Inspector.atom?(attr)
      }
    end)
  end

  # Every assign the component can actually read: its own template plus each helper body. An
  # attribute it declares but never reads is a control that provably cannot do anything —
  # `chelekom-banner` declares `size` and its template reads `@vertical_size`, `@position_size` and
  # `@dismiss_size` but never `@size`, so the Size row moved nothing however it was clicked. Offering
  # it is worse than omitting it: the reader cannot tell "this does nothing" from "this is broken".
  #
  # `nil` when the entry carries no source at all — a hand-built entry in a test, a plugin's own
  # render function — and then nothing is filtered, because "no source" is not evidence of absence.
  @spec readable_assigns(map()) :: MapSet.t() | nil
  # SCANNED WHEN THE PALETTE WAS READ. A palette entry carries the answer, which is what lets it stop
  # carrying the helper source — see `MishkaCmsCore.Builder.PaletteEntry.reads/1`. The scan below
  # stays for everything else: a plugin's descriptor, a hand-built entry in a test, a raw component.
  defp readable_assigns(%{reads: %MapSet{} = reads}), do: reads

  # THE TEMPLATE IS MARKUP AND A HELPER IS CODE, and joining the two into one string to run a pattern
  # over lost that distinction along with the answer. `~r/@(\w+)/` found `@size` written out in a
  # sentence the component renders, inside a string it builds, or behind the `#` of a comment — and
  # every one of those made an option look readable that the component never reads, so the wizard
  # offered a picker that changes nothing.
  #
  # Each half is parsed as what it is: the template's EXPRESSIONS, and the helper's code.
  defp readable_assigns(entry) do
    helpers =
      entry |> helpers_of() |> Enum.map(&helper_code/1) |> Enum.reject(&(&1 in [nil, ""]))

    # NOTHING TO READ AND NOTHING THAT READS ARE DIFFERENT ANSWERS. An entry carrying neither a
    # template nor a helper tells us nothing, and `reads?/2` offers everything for a `nil`; one whose
    # template is plain markup tells us it reads no assign at all, and that is an empty set.
    case {Inspector.template(entry), helpers} do
      {blank, []} when blank in [nil, ""] -> nil
      {template, helpers} -> named(template, helpers)
    end
  end

  defp named(template, helpers) do
    template
    |> Markup.expressions()
    |> Enum.concat(helpers)
    |> Enum.map(&CodeReads.assigns/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp reads?(nil, _name), do: true
  defp reads?(_read, nil), do: true
  defp reads?(read, name), do: MapSet.member?(read, name)

  defp helpers_of(%{helpers: helpers}) when is_list(helpers), do: helpers
  defp helpers_of(%{"helpers" => helpers}) when is_list(helpers), do: helpers
  defp helpers_of(_entry), do: []

  defp helper_code(%{code: code}) when is_binary(code), do: code
  defp helper_code(%{"code" => code}) when is_binary(code), do: code
  defp helper_code(_helper), do: ""

  @doc """
  Whether a component has anything for the wizard to offer.

  A component with no option lists — an icon, a plain wrapper — gets no Wizard tab rather than an
  empty one. `chelekom-alert` answers true with five axes; `chelekom-icon` answers false.
  """
  @spec offers?(map()) :: boolean()
  def offers?(entry), do: axes(entry) != []

  @doc """
  The HEEx for a component with these choices.

  `choices` is a plain map of attribute name to value, as the form posts it. A value that is blank,
  unknown to the attribute, or equal to the component's own default is dropped — the first two
  because a wizard must not invent markup the kit cannot render, the third because it is noise.

  `components` is the palette, which decides whether a component calling another owns a form.
  """
  # WHAT IS PREVIEWED IS NOT WHAT IS PLACED, and this seeded both the same way. A required attribute
  # under `:preview` becomes a 1×1 GIF, the literal word "Example", a `#` href or a fake flash map —
  # every one of them non-empty, so `missing_required/1` waved the node through and publishing shipped
  # it. Dragging the same card off the palette lands `src=""` and publish is correctly refused, so
  # the two doors into the document disagreed about what an incomplete component looks like.
  #
  # `:blank` is the DEFAULT because it is the conservative one: a caller that forgets gets a node the
  # save refuses, not placeholder content on a live page. See `PaletteEntry.string_seed/2`.
  @spec compose(map(), map(), String.t() | nil, :blank | :preview, [map()]) :: String.t()
  def compose(entry, choices, site_name, style \\ :blank, components \\ []) do
    chosen =
      entry
      |> axes()
      |> Enum.map(fn axis -> {axis, chosen(choices[axis.name], axis.values, axis.default)} end)
      |> Enum.reject(fn {_axis, value} -> is_nil(value) end)

    attributes = Enum.map_join(chosen, "", fn {axis, value} -> written(axis, value) end)

    # The REQUIRED attributes too, or there is nothing to preview. A component whose template reads
    # an assign nobody supplies renders as "needs id — set it in the inspector" instead of itself,
    # and every option in the wizard then appears to do nothing: the reader changes a colour, the
    # preview refreshes, and the same placeholder comes back. `PaletteEntry` already answers "what
    # does this component need to render at all", so the wizard asks it rather than guessing.
    seeded =
      PaletteEntry.seeded(
        entry,
        Enum.map(chosen, fn {axis, _value} -> axis.name end),
        style,
        components
      )

    open =
      ~s(<.component component_name="#{entry.name}" site="#{site(entry, site_name)}"#{attributes}#{seeded})

    # SELF-CLOSING when there is nothing to put inside, exactly as `PaletteEntry.template/2` writes
    # it. A component that declares no `inner_block` — `chelekom-tel-field` and most form fields —
    # is handed one by `<.component …></.component>`, and Phoenix raises on a slot the component
    # never declared. That took the preview LiveView down with it, so the modal showed an empty
    # frame with no canvas at all rather than the field.
    case PaletteEntry.seeded_slots(entry, style) <> body(entry) do
      "" -> open <> " />"
      inside -> open <> ">" <> inside <> "</.component>"
    end
  end

  # An ATOM attribute is written as an expression, exactly as the kit's own examples write it —
  # `kind={:danger}`. Written as the string `kind="danger"` it matches none of the component's
  # clauses and falls through to whatever the catch-all renders, so every colour looked identical.
  defp written(%{name: name, atom?: true}, value), do: ~s( #{name}={:#{value}})
  defp written(%{name: name}, value), do: ~s( #{name}="#{value}")

  # A global component is compiled under "Global" whatever page it lands on — the same rule
  # `PaletteEntry` and `Tree.rewrite_site/3` follow, restated here because the wizard emits the
  # invocation itself rather than going through the palette's template.
  defp site(%{global?: true}, _site_name), do: "Global"
  defp site(_entry, site_name), do: site_name || "Global"

  # The SAME starter the palette places, so the preview is the component the insert will produce
  # rather than a differently-worded stand-in. A container previews as a container rather than as an
  # empty rectangle, which is most of why the kit's own empty examples preview as nothing.
  defp body(entry), do: Starter.body(entry)

  defp chosen(nil, _values, _default), do: nil
  defp chosen("", _values, _default), do: nil
  defp chosen(value, _values, default) when value == default, do: nil

  defp chosen(value, values, _default) do
    case value in values do
      true -> value
      false -> nil
    end
  end

  defp values_for(attr, features) do
    case Map.get(features, Inspector.name(attr)) do
      values when is_list(values) ->
        Enum.filter(values, &scalar?/1)

      _none ->
        Inspector.opts(attr) |> Map.get("values", []) |> List.wrap() |> Enum.filter(&scalar?/1)
    end
  end

  # A radio row carries a string, so a value with no string form is not an option — and a bundle is
  # free to put a map in `values` or `default`, because nothing validates the shape of a JSON file an
  # operator pasted a URL for. It used to reach `to_string/1` and raise. That was survivable while
  # `axes/1` ran only when the wizard opened; now that `offers_options?/1` asks EVERY palette entry
  # whether it has any, one such component takes down the whole palette load.
  defp scalar?(nil), do: false
  defp scalar?(value), do: is_binary(value) or is_atom(value) or is_number(value)

  defp features_of(%{features: features}) when is_map(features), do: features
  defp features_of(entry), do: Inspector.features(entry)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value) and not is_nil(value), do: to_string(value)
  defp stringify(value) when is_number(value), do: to_string(value)
  defp stringify(_value), do: nil
end
