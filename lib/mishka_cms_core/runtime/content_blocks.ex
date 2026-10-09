defmodule MishkaCmsCore.Runtime.ContentBlocks do
  @moduledoc """
  Ready-made blocks the content editor offers beside its single components — whole
  `MishkaCmsCore.Runtime.ContentComponents` markers, components inside components and slots filled
  in, so an author places one and only changes the words.

  THEY COME FROM THE COMPONENTS' OWN EXAMPLES — a component's `examples`, finished uses of it as a
  page would hold them, which a kit ships with its components and a component an author adds in the
  CMS may carry too. Each example of each component the palette lists is read with the page builder's
  template parser (`MishkaCmsCore.Runtime.PageBuilder.Tree`) and written as a marker: a component
  as a component marker, a slot as a slot marker, HTML as the HTML it is. An example that needs
  more than a marker holds — an expression, a loop, a component the palette does not list, a slot
  its component does not declare — is not offered. Only the attributes a component declares and a
  marker can carry are kept; the rest of an example's attributes are left to their defaults.

  A component that declares how it arrives when dropped — the `furnishing` the page builder places
  (`MishkaCmsCore.Builder.Furnishing`) — is offered that way too, first among its blocks: the plain
  one, an author's starting point, named after the component itself.

  Nothing here names a kit or a component: a site offers exactly the blocks its components bring.

  ## Events

    * `runtime:content:editor_blocks` — before the blocks are offered, with
      `%{site_id: site_id, blocks: blocks}` and `%{current_user: user}` as meta. Each block is
      `%{id, title, component, category, tree}`, `tree` a `t:MishkaCmsCore.Runtime.ContentComponents.tree/0`
      and `title` `nil` for the plain one, which is named after its component.
      A plugin answers the map with other `blocks` to add its own or take some away; the editor
      offers only those whose components the palette lists.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.ContentComponents
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaInstaller.Event.Hook

  @event "runtime:content:editor_blocks"

  @void ~w(area base br col embed hr img input link meta param source track wbr)

  @typedoc "A block the editor offers, its marker written; `title` is `nil` for the plain one."
  @type block :: %{
          id: String.t(),
          title: String.t() | nil,
          component: String.t(),
          category: String.t(),
          tree: ContentComponents.tree(),
          marker: String.t()
        }

  @doc """
  The blocks the editor offers on `site_id` to `actor`, given the palette's `entries`: every example
  of every entry that a marker can hold, as a plugin answering `runtime:content:editor_blocks`
  leaves them, with its marker.
  """
  @spec available([ContentComponents.entry()], String.t() | nil, map() | nil) :: [block()]
  def available(entries, site_id, actor) do
    listed = Map.new(entries, &{&1.name, &1})
    blocks = Enum.flat_map(entries, &(plain(&1, listed) ++ examples(&1, listed)))

    %{site_id: site_id, blocks: blocks}
    |> then(&Hook.call(@event, &1, meta: %{current_user: actor}))
    |> case do
      %{blocks: given} when is_list(given) -> given
      _unchanged -> blocks
    end
    |> Enum.filter(&placeable?(&1, listed))
    |> Enum.flat_map(fn block ->
      case ContentComponents.write(block.tree) do
        marker when is_binary(marker) -> [Map.put(block, :marker, marker)]
        nil -> []
      end
    end)
  end

  @doc """
  The blocks one palette entry's examples make, `listed` the palette by name: each example a marker
  can hold, in the order the component lists them.
  """
  @spec examples(ContentComponents.entry(), %{String.t() => ContentComponents.entry()}) :: [map()]
  def examples(%{examples: [_ | _] = examples} = entry, listed) do
    examples
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {source, n} ->
      case example(source, listed) do
        {:ok, %{name: name} = tree, label} when name == entry.name ->
          [
            %{
              id: "#{entry.name}-example-#{n}",
              title: title(label, entry.name, n),
              component: entry.name,
              category: entry.category,
              tree: tree
            }
          ]

        _not_one_of_its_own ->
          []
      end
    end)
  end

  def examples(_entry, _listed), do: []

  @doc """
  The plain block of one palette entry, `listed` the palette by name: the component as its
  `furnishing` says it arrives, when it says so and a marker can hold it.
  """
  @spec plain(ContentComponents.entry(), %{String.t() => ContentComponents.entry()}) :: [map()]
  def plain(%{furnishing: %{} = furnishing, name: name} = entry, listed) do
    source =
      ~s(<.component component_name="#{name}"#{attributes(furnishing.attrs)}>) <>
        furnishing.body <> Enum.map_join(furnishing.slots, &slot_source/1) <> "</.component>"

    case example(source, listed) do
      {:ok, %{name: ^name} = tree, _id} ->
        [
          %{
            id: name <> "-plain",
            title: nil,
            component: name,
            category: entry.category,
            tree: tree
          }
        ]

      _not_a_marker ->
        []
    end
  end

  def plain(_entry, _listed), do: []

  defp slot_source(%{name: name, body: body, attrs: attrs}) do
    case Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      true -> "<:#{name}#{attributes(attrs)}>#{body}</:#{name}>"
      false -> ""
    end
  end

  # A word, a number or a yes/no is written as the marker writes it; a list or a map a marker cannot
  # hold is left to the component's default.
  defp attributes(attrs) do
    for {name, value} <- attrs || %{},
        is_binary(name),
        Regex.match?(~r/\A[a-z_][a-z0-9_-]*\z/, name),
        text = written(value),
        is_binary(text),
        into: "",
        do: ~s( #{name}="#{escape(text)}")
  end

  defp written(value) when is_binary(value), do: value
  defp written({:expr, value}) when is_number(value) or is_boolean(value), do: to_string(value)
  defp written(_data), do: nil

  # One example as a marker tree: one component at its root and nothing a marker cannot hold.
  defp example(source, listed) when is_binary(source) do
    with {:ok, tree} <- Tree.parse(source),
         [root] <- Enum.reject(Tree.children(tree, :root), &blank?/1),
         {:ok, [{:component, component}]} <- convert(tree, root, listed, nil) do
      {:ok, component, string_attr(root, "id")}
    else
      _not_a_block -> :error
    end
  end

  defp example(_source, _listed), do: :error

  defp convert(tree, %{kind: :component} = node, listed, _parent) do
    with name when is_binary(name) <- string_attr(node, "component_name"),
         %{} = entry <- Map.get(listed, name),
         {:ok, parts} <- parts(tree, node, listed, entry) do
      {:ok, [{:component, %{name: name, attrs: carried(node, entry.attrs), parts: parts}}]}
    else
      _unlisted_or_unreadable -> :error
    end
  end

  defp convert(tree, %{kind: :slot, tag: ":" <> name} = node, listed, %{slots: slots}) do
    with %{} = declared <- Enum.find(slots, &(&1.name == name)),
         {:ok, parts} <- parts(tree, node, listed, nil) do
      {:ok, [{:slot, %{name: name, attrs: carried(node, declared.attrs), parts: parts}}]}
    else
      _undeclared -> :error
    end
  end

  defp convert(tree, %{kind: :tag, tag: tag} = node, listed, parent) do
    with {:ok, open} <- open_tag(node),
         {:ok, parts} <- parts(tree, node, listed, parent) do
      case parts == [] and String.downcase(tag) in @void do
        true -> {:ok, [{:text, open}]}
        false -> {:ok, [{:text, open}] ++ parts ++ [{:text, "</#{tag}>"}]}
      end
    end
  end

  # A template's line breaks and indentation are spacing in HTML, and one space is what they draw.
  defp convert(_tree, %{kind: :text, text: text}, _listed, _parent) when is_binary(text) do
    cond do
      String.trim(text) != "" -> {:ok, [{:text, String.replace(text, ~r/\s*\n\s*/, " ")}]}
      String.contains?(text, "\n") -> {:ok, []}
      true -> {:ok, [{:text, " "}]}
    end
  end

  defp convert(_tree, %{kind: kind}, _listed, _parent) when kind in [:html_comment, :eex_comment],
    do: {:ok, []}

  defp convert(_tree, _expression_or_slot_elsewhere, _listed, _parent), do: :error

  defp parts(tree, node, listed, parent) do
    tree
    |> Tree.children(node.id)
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, parts} ->
      case convert(tree, child, listed, parent) do
        {:ok, more} -> {:cont, {:ok, parts ++ more}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> merged() |> trimmed()}
      :error -> :error
    end
  end

  # The spacing a part opens and closes with is the template's indentation, not its content.
  defp trimmed(parts) do
    parts
    |> edge(&String.trim_leading/1)
    |> Enum.reverse()
    |> edge(&String.trim_trailing/1)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == {:text, ""}))
  end

  defp edge([{:text, text} | rest], trim), do: [{:text, trim.(text)} | rest]
  defp edge(parts, _trim), do: parts

  # Adjacent HTML is one piece of text, as `ContentComponents.read/1` would give it back.
  defp merged(parts) do
    parts
    |> Enum.chunk_by(&match?({:text, _}, &1))
    |> Enum.flat_map(fn
      [{:text, _} | _] = texts -> [{:text, Enum.map_join(texts, fn {:text, t} -> t end)}]
      others -> others
    end)
  end

  # The attributes a marker can carry for the declarations `declared`, as written in the example.
  defp carried(node, declared) do
    names = MapSet.new(declared, & &1.name)

    for {name, value} <- node.attrs,
        is_binary(name),
        MapSet.member?(names, name),
        text = literal(value),
        is_binary(text),
        into: %{},
        do: {name, text}
  end

  defp literal({:string, value}), do: value
  defp literal(:boolean), do: "true"

  # `default={true}`, `size={3}`: an expression that is a literal is the value it writes.
  defp literal({:expr, code}) when is_binary(code) do
    case Regex.run(~r/\A\s*(true|false|-?\d+(?:\.\d+)?)\s*\z/, code) do
      [_whole, value] -> value
      nil -> nil
    end
  end

  defp literal(_expression), do: nil

  defp open_tag(%{tag: tag, attrs: attrs}) do
    written =
      Enum.reduce_while(attrs, [], fn
        {name, {:string, value}}, acc when is_binary(name) ->
          {:cont, [~s( #{name}="#{escape(value)}") | acc]}

        {name, :boolean}, acc when is_binary(name) ->
          {:cont, [" " <> name | acc]}

        _expression, _acc ->
          {:halt, :error}
      end)

    case written do
      :error -> :error
      attrs -> {:ok, "<#{tag}" <> (attrs |> Enum.reverse() |> Enum.join()) <> ">"}
    end
  end

  defp escape(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp string_attr(%{attrs: attrs}, name) do
    Enum.find_value(attrs, fn
      {^name, {:string, value}} -> value
      _other -> nil
    end)
  end

  defp blank?(%{kind: :text, text: text}), do: String.trim(text || "") == ""
  defp blank?(%{kind: kind}), do: kind in [:html_comment, :eex_comment]

  # AN EXAMPLE'S NAME IS ITS ID, less the words naming its component: `timeline-order-tracking` on
  # `chelekom-timeline` is "Order tracking", and so is `tl-order-tracking` or `timelinesection-…` on
  # `chelekom-timeline-section` — one of the component's own words, the last of them run together,
  # or a word of two to four letters spelled, in order, from the letters of the last of them. One
  # without an id, or nothing but those, is counted.
  defp title(id, component, n) when is_binary(id) do
    own = String.split(component, "-")
    run_together = for i <- 0..(length(own) - 1), do: own |> Enum.drop(i) |> Enum.join()

    case id |> String.split(["-", "_"]) |> Enum.reject(&naming?(&1, own, run_together)) do
      [] -> gettext("Example %{n}", n: n)
      words -> words |> Enum.join(" ") |> String.capitalize()
    end
  end

  defp title(_id, _component, n), do: gettext("Example %{n}", n: n)

  defp naming?(word, own, run_together),
    do: word in own or word in run_together or Enum.any?(run_together, &short_for?(word, &1))

  defp short_for?(<<first, rest::binary>> = word, <<first, name::binary>>)
       when byte_size(word) in 2..4,
       do: in_order?(rest, name)

  defp short_for?(_word, _name), do: false

  defp in_order?(<<>>, _letters), do: true

  defp in_order?(<<letter, rest::binary>>, letters) do
    case String.split(letters, <<letter>>, parts: 2) do
      [_before, later] -> in_order?(rest, later)
      [_none] -> false
    end
  end

  # Every component in the block is listed, and every slot in it is one its component declares.
  defp placeable?(%{tree: %{name: _} = tree}, listed), do: fits?(tree, listed)
  defp placeable?(_block, _listed), do: false

  defp fits?(%{name: name, parts: parts}, listed) do
    case Map.fetch(listed, name) do
      {:ok, entry} -> Enum.all?(parts, &part_fits?(&1, entry, listed))
      :error -> false
    end
  end

  defp part_fits?({:text, _text}, _entry, _listed), do: true
  defp part_fits?({:component, tree}, _entry, listed), do: fits?(tree, listed)

  defp part_fits?({:slot, %{name: name, parts: parts}}, entry, listed) do
    Enum.any?(entry.slots, &(&1.name == name)) and
      Enum.all?(parts, &part_fits?(&1, entry, listed))
  end

  defp part_fits?(_part, _entry, _listed), do: false
end
