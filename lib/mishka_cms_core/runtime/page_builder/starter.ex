defmodule MishkaCmsCore.Runtime.PageBuilder.Starter do
  @moduledoc """
  What a component should SAY the moment it is placed.

  Dropping `chelekom-banner` used to put `<.component component_name="chelekom-banner" … />` on the
  canvas — a component with nothing inside it. A banner with no message is a blank strip, an alert
  with no text is an empty rounded box, and a card with no content is a border. The author drags
  something, sees almost nothing, and has to open the inspector to discover what they placed.

  So a placed component arrives furnished. The text is deliberately ordinary and obviously
  replaceable — the point is that the shape is visible and the words are already selected for
  editing, which is what a page builder is for.

  ## Why a table and not the component's own examples

  The examples are better copy, but curating them costs a parse of every example the component
  ships — 7.8 seconds across the palette, to answer a question asked once per drag. The palette
  builds its drop template for all 177 entries on every render, so this has to be a lookup.

  ## What gets nothing

  A component with no `inner_block` has nowhere to put content, and one that composes its own
  children — a table row, an accordion — would only be given text in the wrong place. Those stay
  self-closing, which is what `MishkaCmsCore.Builder.PaletteEntry.template/2` emits.
  """

  alias MishkaCmsCore.Builder.Furnishing
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector

  # Matched longest-first, so `chelekom-card-title` never picks up `chelekom-card`'s copy. The names
  # are the kit's own, minus the vendor prefix, so a second kit shipping `foo-alert` gets the same
  # treatment without an entry of its own.
  @starters [
    {~w(alert flash toast banner notification),
     "Heads up — this is worth reading before you continue."},
    {~w(blockquote quote), "Design is not just what it looks like. Design is how it works."},
    {~w(button), "Get started"},
    {~w(badge chip tag), "New"},
    {~w(card-title title heading h1 h2 h3 h4 h5 h6), "A heading that earns the scroll"},
    {~w(card-content content paragraph p text), "A sentence or two that says why this matters."},
    {~w(breadcrumb), "Home"},
    {~w(tooltip popover), "A short explanation"},
    {~w(footer-section footer), "© Your company. All rights reserved."},
    {~w(header-section header navbar nav), "Your site"},
    {~w(drawer modal dialog sidebar), "Put anything in here."},
    {~w(tab tabs accordion collapse), "Panel content"},
    {~w(stat), "1,284"},
    {~w(progress spinner skeleton), ""},
    {~w(list li menu), "First item"},
    {~w(table td th tr), "Cell"}
  ]

  @fallback "Your content here"

  # A component whose content is a LIST of things does not hold it between its tags — an accordion's
  # sections, a select's options and a carousel's slides are each written as a `<:slot>` entry, and a
  # component dropped without them is the empty box this module exists to prevent. `chelekom-tabs`
  # with no `<:tab>` is a bare rounded rectangle; with two it is recognisably a tab strip.
  #
  # Keyed by the slot's own name, which is Phoenix convention rather than this kit's vocabulary, so
  # another package's `<:item>` is furnished on the same terms.
  @slot_samples %{
    "item" => [
      {%{"title" => "First section"}, "What this section covers."},
      {%{"title" => "Second section"}, "And what this one covers."}
    ],
    "option" => [
      {%{"value" => "one"}, "First choice"},
      {%{"value" => "two"}, "Second choice"},
      {%{"value" => "three"}, "Third choice"}
    ],
    "radio" => [{%{"value" => "one"}, "First option"}, {%{"value" => "two"}, "Second option"}],
    "checkbox" => [{%{"value" => "one"}, "First option"}, {%{"value" => "two"}, "Second option"}],
    "tab" => [{%{}, "Overview"}, {%{}, "Details"}],
    "panel" => [{%{}, "What the Overview tab shows."}, {%{}, "And what Details shows."}],
    "slide" => [{%{}, "First slide"}, {%{}, "Second slide"}],
    "control" => [{%{}, "A field goes here."}],
    "trigger" => [{%{}, "Open"}],
    "content" => [{%{}, "Anything can go in here."}]
  }

  # The one component that wants BOTH, and the reason the slot table above is keyed by name alone
  # cannot cover it: `<:header>` names a table's columns, but a drawer's `<:header>` is its title bar
  # and "Name"/"Status" in it would be nonsense. So this is keyed by the COMPONENT.
  #
  # The rows are plain HTML on purpose — `<.component component_name="chelekom-tr">` would be a
  # second component this install may not have shipped, and a missing one renders as an error message
  # where the sample row should be.
  @composite %{
    "table" => %{
      slots: [{"header", %{}, "Name"}, {"header", %{}, "Status"}],
      body: "<tr><td>Ada Lovelace</td><td>Active</td></tr>"
    }
  }

  @doc """
  The markup to place inside a freshly dropped component, or `""` when it takes no content.

  Accepts anything shaped like a palette entry — the component's `name` and its `slots` are all this
  reads.
  """
  @spec body(map()) :: String.t()
  def body(entry) do
    case declared(entry) do
      {:ok, furnishing} -> furnishing.body
      :none -> inferred_body(entry)
    end
  end

  @doc """
  The attributes a freshly dropped component arrives SET to, or `%{}` when it declares none.

  A body says what goes inside; this says what the thing itself is. Only a declaration — there is
  nothing to infer here, and a component that says nothing keeps its own defaults.
  """
  @spec attrs(map()) :: %{optional(String.t()) => String.t()}
  def attrs(entry) do
    case declared(entry) do
      {:ok, furnishing} -> furnishing.attrs
      :none -> %{}
    end
  end

  defp inferred_body(entry) do
    cond do
      not takes_content?(entry) -> ""
      composite(entry) -> composite(entry).body
      slot_samples(entry) != [] -> ""
      true -> starter(name(entry))
    end
  end

  # A component that declares its own furnishing is answering the question itself, and its answer
  # wins outright — including when it answers "nothing", which the inference could not express.
  # `MishkaCmsCore.Builder.Furnishing` says why this is the shape a third party declares.
  defp declared(entry) do
    case entry |> furnishing() |> Furnishing.build() do
      {:ok, furnishing} -> (Furnishing.empty?(furnishing) && :none) || {:ok, furnishing}
      :none -> :none
    end
  end

  defp furnishing(%{furnishing: furnishing}), do: furnishing
  defp furnishing(%{"furnishing" => furnishing}), do: furnishing
  defp furnishing(_entry), do: nil

  @doc """
  Whether a freshly dropped component arrives with something to look at — content between its tags,
  sample slot entries, or both.

  The predicate the kit-wide contract is written against: `chelekom-accordion` has nothing to say
  between its tags and is furnished all the same, by two `<:item>` entries.
  """
  @spec furnished?(map()) :: boolean()
  def furnished?(entry), do: body(entry) != "" or slot_samples(entry) != []

  defp composite(entry) do
    entry
    |> name()
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> List.last()
    |> then(&Map.get(@composite, &1))
  end

  @doc """
  Sample entries for a component's named slots: `[{slot_name, attrs, body}]`.

  The COPY only — writing it as HEEx belongs to `MishkaCmsCore.Builder.PaletteEntry`, which already
  owns how a slot's own required attributes are seeded. `attrs` carries the values the sample needs
  to make sense of itself: an `<:option>` without a `value` is a choice that cannot be chosen.

  Entries are dropped for slots the component does not declare, so a composite's `<:header>` is only
  written where there is one to write.
  """
  @spec slot_samples(map()) :: [{String.t(), map(), String.t()}]
  def slot_samples(entry) do
    case declared(entry) do
      {:ok, furnishing} -> for s <- furnishing.slots, do: {s.name, s.attrs, s.body}
      :none -> inferred_slot_samples(entry)
    end
  end

  defp inferred_slot_samples(entry) do
    declared = MapSet.new(Inspector.slots(entry), &Inspector.name/1)

    generic =
      for slot <- Inspector.slots(entry),
          {attrs, body} <- Map.get(@slot_samples, Inspector.name(slot), []),
          do: {Inspector.name(slot), attrs, body}

    composed =
      case composite(entry) do
        nil -> []
        %{slots: slots} -> Enum.filter(slots, fn {name, _attrs, _body} -> name in declared end)
      end

    generic ++ composed
  end

  @doc """
  Whether the component has somewhere to put content at all.

  `inner_block` is the only slot an author's text can land in. A component without one is not
  incomplete — a spinner has nothing to say — so it is left alone rather than given a body that
  Phoenix would refuse.
  """
  @spec takes_content?(map()) :: boolean()
  def takes_content?(entry) do
    entry
    |> Inspector.slots()
    |> Enum.any?(&(Inspector.name(&1) == "inner_block"))
  end

  defp starter(name) do
    words = name |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true)

    Enum.find_value(@starters, @fallback, fn {keys, text} ->
      Enum.any?(keys, &matches?(words, &1)) && text
    end)
  end

  # A multi-word key like `card-title` has to match the tail of the name in order, so
  # `chelekom-card-title` matches it and `chelekom-card` does not.
  defp matches?(words, key) do
    key_words = String.split(key, "-")

    Enum.any?(0..max(length(words) - 1, 0), fn index ->
      Enum.slice(words, index, length(key_words)) == key_words
    end)
  end

  defp name(%{name: name}) when is_binary(name), do: name
  defp name(%{"name" => name}) when is_binary(name), do: name
  defp name(_entry), do: ""
end
