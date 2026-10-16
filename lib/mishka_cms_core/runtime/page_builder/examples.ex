# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Examples do
  @moduledoc """
  The example list behind a component's Examples modal — curated out of the two sets a kit bundle
  ships, which are not the same thing and were never reconciled.

  ## The two sets

  `extra.examples` is the kit's own catalogue: one entry per option, generated from the component's
  variants. It is exhaustive and it is dull — `<.component variant="base">Base</.component>` twelve
  times over, with the content replaced by the name of the thing being demonstrated.

  `extra.demo_examples` is every real usage on the kit's documentation site, with the surrounding
  content intact: `"Here is a gentle confirmation that your action was successful."` rather than
  `"Base"`. There are 3,084 of them across the bundle and, until this module, **nothing read them**.

  ## What curation means here

  Three rules, in this order:

    1. **Prefer composed.** Where both sets demonstrate the same options, the documentation one wins:
       identical markup, real content. A preview whose body reads "Base" tells the author nothing
       about what the component looks like in a page.
    2. **Dedup by what an example SAYS.** Two entries setting the same attributes on the same
       component are one example however differently they are labelled — and the demo set repeats
       itself heavily, because a docs page shows the same alert under several headings.
    3. **Keep the base first.** The unmodified component is what someone opening the modal wants to
       see before any variant of it.

  Every surviving example gets a stable `id` (so a selection survives a re-render), a `title` and a
  `description` that says what it actually demonstrates — read off the attributes it sets rather
  than copied from a label, because the labels upstream are frequently just the section name.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  # A SHORT list of complete ones, not a catalogue. The Wizard covers "what does this look like in
  # amber, bordered, large" far better than twenty near-identical cards ever did — so what is left
  # for the modal to answer is "what does a finished one look like in a page", and that needs a
  # handful of good answers, not two dozen mediocre ones.
  @limit 6

  @type example :: %{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          source: String.t(),
          composed?: boolean(),
          base?: boolean(),
          section: String.t() | nil,
          requires: map()
        }

  @doc """
  The curated example list for one component row (or palette entry).

  Returns `[]` when the component ships none, which is what the modal's empty state is for.
  """
  @spec for_component(map()) :: [example()]
  def for_component(component) do
    curated = component |> raw(["examples"]) |> Enum.map(&normalise(&1, false))
    composed = component |> raw(["demo_examples"]) |> Enum.map(&normalise(&1, true))

    (curated ++ composed)
    |> Enum.reject(&is_nil/1)
    |> dedup()
    |> prefer_furnished()
    |> order()
    |> Enum.take(@limit)
    |> Enum.with_index()
    |> Enum.map(fn {example, index} -> Map.put(example, :id, id(example, index)) end)
  end

  @doc """
  The curated examples of ONE component, read fresh from the database by name.

  The palette deliberately carries no examples: curating all 183 components parses every example
  each one ships and cost 7.8 seconds at editor open, to fill a modal that is opened for a single
  component. Both readers of that modal — the panel and the preview iframe — come through here
  instead, and only when the modal is opened.
  """
  @spec for_name(String.t(), String.t() | nil) :: [example()]
  def for_name(name, site_id \\ nil) do
    require Ash.Query

    args = if(is_binary(site_id), do: %{site_id: site_id}, else: %{})

    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:for_tenant_with_globals, args, authorize?: false)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.select([:id, :name, :extra])
    |> Ash.read(page: [limit: 1])
    |> case do
      {:ok, %{results: [component | _rest]}} -> for_component(component)
      {:ok, [component | _rest]} -> for_component(component)
      _none -> []
    end
  end

  @doc "How many examples a component would offer — what the palette's badge counts."
  @spec count(map()) :: non_neg_integer()
  def count(component), do: component |> for_component() |> length()

  defp raw(component, path),
    do: Enum.reduce(path, extra(component), &Map.get(&2 || %{}, &1)) |> List.wrap()

  defp extra(%{extra: extra}) when is_map(extra), do: extra
  defp extra(%{"extra" => extra}) when is_map(extra), do: extra
  defp extra(_component), do: %{}

  defp normalise(%{"source" => source} = raw, composed?) when is_binary(source) do
    trimmed = String.trim(source)

    case trimmed do
      "" ->
        nil

      _source ->
        %{
          title: title(raw, composed?),
          description: nil,
          source: trimmed,
          composed?: composed?,
          base?: raw["base"] == true,
          section: blank(raw["section"]),
          requires: raw["requires"] || %{}
        }
        |> describe()
    end
  end

  defp normalise(_raw, _composed?), do: nil

  # An upstream label is often just the section name repeated (`"Base Variant"`, section
  # `"base-variant-alert"`), and a demo example has no label at all. Both get a title from what the
  # markup sets, and fall back to the label only when there is nothing to say.
  defp title(raw, composed?) do
    case {blank(raw["label"]), composed?} do
      {nil, true} -> gettext("In use")
      {nil, false} -> gettext("Example")
      {label, _composed} -> label
    end
  end

  # What an example DEMONSTRATES: the attributes it sets that a bare component would not. This is
  # the one thing a reader scanning the list needs and the one thing the bundle never says.
  defp describe(example) do
    attrs = attributes(example.source)

    description =
      cond do
        attrs != [] -> Enum.map_join(attrs, ", ", &phrase/1)
        example.base? -> gettext("The component with nothing set")
        true -> gettext("The component as it ships")
      end

    %{example | description: description}
  end

  # AN ADDRESS IS NOT AN OPTION. A picture's `src` is the sample the kit ships, written inline as
  # `data:image/…` — "src data:image/svg+xml;base64,PHN2Zy…" told the reader nothing but which
  # attribute was set, so that is all it says.
  defp phrase({name, value}) do
    case value
         |> String.trim(~s("))
         |> String.starts_with?(["data:", "http://", "https://", "/"]) do
      true -> name
      false -> "#{name} #{value}"
    end
  end

  defp attributes(source) do
    case component_node(source) do
      nil ->
        []

      node ->
        node.attrs
        |> Enum.reject(fn {name, _value} -> name in ~w(component_name site id class) end)
        |> Enum.map(fn {name, value} -> {name, readable(Node.attr_text(node, name) || value)} end)
        |> Enum.reject(fn {_name, value} -> value in [nil, "", "nil"] end)
        |> Enum.sort()
    end
  end

  # `kind={:danger}` is written as an atom because that is what the component matches on, but a
  # description is prose: the reader wants "kind danger", not the syntax it happens to travel in.
  defp readable(value) when is_binary(value), do: String.trim_leading(value, ":")
  defp readable(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp readable(nil), do: nil
  defp readable(value), do: to_string(value)

  defp component_node(source) do
    case Tree.parse(source) do
      {:ok, tree} -> tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))
      _other -> nil
    end
  end

  # Deduping is two different questions, and answering both with one rule was wrong.
  #
  # Among the DOCUMENTATION examples, two entries are the same only when they set the same attributes
  # AND show the same words — a docs page legitimately shows one alert with three different bodies,
  # and those are three things worth previewing.
  #
  # Between the two SETS the words never match, because a curated example's body is the name of the
  # option it demonstrates. So a curated entry is superseded by any documentation entry setting the
  # same attributes, and hands over its label on the way out: the label is the better name, the
  # documentation body is the better preview.
  defp dedup(examples) do
    {curated, composed} = Enum.split_with(examples, &(not &1.composed?))

    composed = uniq_by_signature(composed)
    by_attrs = MapSet.new(composed, &attributes(&1.source))

    {superseded, kept} =
      Enum.split_with(curated, &MapSet.member?(by_attrs, attributes(&1.source)))

    labels = Map.new(superseded, &{attributes(&1.source), {&1.title, &1.section}})

    uniq_by_signature(kept) ++ relabel(composed, labels)
  end

  # Only the FIRST documentation example for a given set of attributes takes the curated label —
  # there are usually several, and handing the same name to all of them made the list read as
  # duplicates of one entry.
  defp relabel(composed, labels) do
    composed
    |> Enum.map_reduce(labels, fn example, remaining ->
      key = attributes(example.source)

      case Map.pop(remaining, key) do
        {nil, remaining} -> {example, remaining}
        {{title, section}, remaining} -> {%{example | title: title, section: section}, remaining}
      end
    end)
    |> elem(0)
  end

  defp uniq_by_signature(examples), do: Enum.uniq_by(examples, &signature/1)

  defp signature(example), do: {attributes(example.source), words(example.source)}

  # The kit's `"Base"` and a docs page's real sentence are the same example wearing different
  # content, so the comparison is on shape, not on the exact words.
  defp words(source) do
    source
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.downcase()
    |> String.slice(0, 60)
  end

  defp order(examples) do
    Enum.sort_by(examples, fn example ->
      {(example.base? && 0) || 1, -substance(example), (example.composed? && 0) || 1,
       example.title}
    end)
  end

  # How much of a component an example actually shows. An entry whose body is empty demonstrates the
  # component's outline and nothing else — 334 of the kit's own demo entries are exactly that, and
  # they are what made an author drop a banner and see a blank strip. Ranked below anything with
  # content, and dropped outright by `prefer_furnished/1` when the component has better to offer.
  defp substance(%{source: source}) do
    text = source |> String.replace(~r/<[^>]*>/, " ") |> String.trim()

    words = text |> String.split(~r/\s+/, trim: true) |> length()
    attrs = length(Regex.scan(~r/\s[a-z_]+=/, source))
    children = length(Regex.scan(~r/<[a-z.]/, source))

    min(words, 40) + attrs * 2 + min(children, 10) * 3
  end

  # An empty example survives only when the component has nothing better. Seven components in the
  # kit are in that position — `chelekom-gallery`, `chelekom-carousel` and friends, whose every demo
  # entry is an empty shell — and showing an outline beats showing nothing at all.
  defp prefer_furnished(examples) do
    case Enum.split_with(examples, &furnished?/1) do
      {[], bare} -> bare
      {furnished, _bare} -> furnished
    end
  end

  # CONTENT IS NOT ALWAYS WORDS. This read an example as empty unless something was left after every
  # tag was stripped — so a gallery of six image tiles, a carousel of three slides and every other
  # component whose content IS components scored zero, and one example with a sentence in it was
  # enough to drop the rest. `chelekom-gallery` ships four and offered one: not the three-column grid
  # the drop needs, nor the masonry one, which is the whole of "there is no option to choose style".
  #
  # A tag inside the one the example opens with is content. Closing tags do not count — `</` is not
  # a name — so a self-closing component alone still reads as the bare shell it is.
  defp furnished?(%{source: source}) do
    stripped = source |> String.replace(~r/<[^>]*>/, "") |> String.trim()

    stripped != "" or length(Regex.scan(~r/<[a-zA-Z.:]/, source)) > 1
  end

  # Stable across renders, and readable in the DOM: the index alone would move an example's id when
  # a sibling is deduped away, and the section alone is not unique.
  defp id(example, index) do
    slug =
      (example.section || example.title)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    case slug do
      "" -> "ex-#{index}"
      slug -> "#{slug}-#{index}"
    end
  end

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank(_value), do: nil
end
