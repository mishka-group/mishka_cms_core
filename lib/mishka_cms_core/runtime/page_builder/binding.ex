# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Binding do
  @moduledoc """
  The v2 prototype's **Data tab**: repeating a node over a CMS collection.

  An author selects a card, picks "Blog posts", and the card becomes one card per post. In the
  template that is a `:for` comprehension — but the editor does not write raw source and then try to
  read it back with a regex. The binding is held as a **structured descriptor** in the node's meta
  and *generated* into `:for` on serialize, so it round-trips structurally: reopening the page shows
  the picker set to "Blog posts", not an opaque amber chip.

  This is the difference between the loop being editable and merely surviving. ADR-9 keeps
  hand-written `eex_block` source byte-for-byte because the editor cannot understand it; a binding
  it generated itself, it can.

  ## Sources

  A source names a collection the CMS can actually read. They are declared here rather than guessed
  from the template so the picker can only ever offer bindings that resolve, and so an extension can
  add one through `builder:components`' sibling registry without the editor learning about blogs.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @sources [
    %{key: "posts", label: gettext_noop("Blog posts"), assign: "@posts", item: "post"},
    %{
      key: "collections",
      label: gettext_noop("Blog collections"),
      assign: "@collections",
      item: "collection"
    },
    %{key: "documents", label: gettext_noop("Documents"), assign: "@documents", item: "document"},
    %{
      key: "sections",
      label: gettext_noop("Document sections"),
      assign: "@sections",
      item: "section"
    },
    %{key: "media", label: gettext_noop("Media"), assign: "@media", item: "item"}
  ]

  @doc "The collections the Data tab can bind a node to."
  @spec sources() :: [map()]
  def sources, do: @sources

  @doc "One source by key, or `nil`."
  @spec source(String.t()) :: map() | nil
  def source(key), do: Enum.find(@sources, &(&1.key == key))

  @doc "The binding recorded on a node, or `nil`."
  @spec get(Node.t()) :: map() | nil
  def get(%Node{meta: meta}), do: Map.get(meta, :binding)
  def get(_node), do: nil

  @doc "Whether a node repeats."
  @spec bound?(Node.t()) :: boolean()
  def bound?(node), do: not is_nil(get(node))

  @doc """
  Binds `id` to a source. An unknown source key is refused rather than written, so the serializer
  can never be handed a loop over something that does not exist.
  """
  @spec put(Tree.t(), String.t(), String.t(), keyword()) :: {:ok, Tree.t()} | {:error, term()}
  def put(tree, id, source_key, opts \\ []) do
    with %{} = source <- source(source_key),
         %Node{} = node <- Tree.get(tree, id) do
      binding = %{
        source: source.key,
        assign: source.assign,
        item: opts[:item] || source.item,
        limit: opts[:limit]
      }

      {:ok, put_node(tree, %{node | meta: Map.put(node.meta, :binding, binding)})}
    else
      nil -> {:error, :unknown_source}
    end
  end

  @doc "Removes a node's binding, so it stops repeating."
  @spec delete(Tree.t(), String.t()) :: {:ok, Tree.t()} | {:error, term()}
  def delete(tree, id) do
    case Tree.get(tree, id) do
      nil -> {:error, :unknown_node}
      node -> {:ok, put_node(tree, %{node | meta: Map.delete(node.meta, :binding)})}
    end
  end

  defp put_node(tree, node), do: %{tree | nodes: Map.put(tree.nodes, node.id, node)}

  @doc """
  The `<%= for … do %>` opening a bound node serializes inside, or `nil` when it is not bound.
  """
  @spec open(Node.t()) :: String.t() | nil
  def open(node) do
    case get(node) do
      nil -> nil
      binding -> "<%= for #{binding.item} <- #{enumerable(binding)} do %>"
    end
  end

  @doc "The closing tag matching `open/1`."
  @spec close(Node.t()) :: String.t() | nil
  def close(node), do: if(bound?(node), do: "<% end %>")

  defp enumerable(%{assign: assign, limit: limit}) when is_integer(limit),
    do: "Enum.take(#{assign}, #{limit})"

  defp enumerable(%{assign: assign}), do: assign

  @doc """
  Reads a binding back out of a parsed `:eex_block` whose source this module generated.

  Returns `{:ok, binding}` for a loop the editor recognises and `:error` for any other block — a
  hand-written comprehension stays an opaque atomic chip, exactly as ADR-9 requires, because
  pretending to understand it is how the old editor corrupted things.
  """
  @spec parse(String.t()) :: {:ok, map()} | :error
  def parse(text) when is_binary(text) do
    with %{"item" => item, "rest" => rest} <-
           Regex.named_captures(
             ~r/^for\s+(?<item>\w+)\s+<-\s+(?<rest>.+?)\s+do$/,
             String.trim(text)
           ),
         {:ok, assign, limit} <- enumerable_parts(rest),
         %{} = source <- Enum.find(@sources, &(&1.assign == assign)) do
      {:ok, %{source: source.key, assign: assign, item: item, limit: limit}}
    else
      _unrecognised -> :error
    end
  end

  def parse(_text), do: :error

  defp enumerable_parts(rest) do
    case Regex.named_captures(~r/^Enum\.take\((?<assign>@\w+),\s*(?<limit>\d+)\)$/, rest) do
      %{"assign" => assign, "limit" => limit} -> {:ok, assign, String.to_integer(limit)}
      nil -> if String.match?(rest, ~r/^@\w+$/), do: {:ok, rest, nil}, else: :error
    end
  end

  @doc """
  How many preview rows the canvas renders for a bound node — the demo's three, with a badge — since
  the editor has no real data to loop over.
  """
  @spec preview_count() :: pos_integer()
  def preview_count, do: 3
end
