# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.Collection do
  @moduledoc """
  The list or map an attribute is holding, read out of a document and written back into one.

  ## Why this is not a text box

  `chelekom-filterable-gallery` keeps its whole content in two `list` attributes — the filter
  buttons and the pictures behind them — and thirty-nine attributes across the shipped kit are
  shaped the same way. The panel drew a one-line box for every one of them and wrote what was typed
  as a STRING, so a component that maps over its own attribute raised the moment anything was
  entered. The report reads "we cannot add any image and it's not clear how it works".

  So the panel needs a control that knows it is holding a collection, and that control needs to read
  the list, change one item, and write the whole thing back as one edit. That is this module.

  ## What counts as readable

  `MishkaCmsCore.Builder.Literal` decides, and it decides by walking the quoted form rather than
  evaluating it: a list of strings, a list of maps, a keyword list. Anything else — a binding, a
  function call, an interpolation — answers `:error`, and a caller holding `:error` must leave the
  attribute alone rather than overwrite what it could not read. An author who has written
  `media={@photos}` means it.

  ## And what is written back

  `inspect/1`, which is the exact shape the editor can read again. One `set_attr` per change, so one
  undo step per add, per removal and per edit.
  """

  alias MishkaCmsCore.Builder.Literal
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @doc """
  The collection an attribute holds on this node, or the declared default when it holds nothing.

  `:error` when the attribute is there and is not data — a binding rather than a list.
  """
  @spec read(Node.t() | term(), String.t(), term()) :: {:ok, list()} | :error
  def read(node, name, default \\ []) do
    case Node.attr(node, name) do
      nil -> {:ok, listed(default)}
      {:expr, source} -> source |> Literal.value() |> listed_result()
      {:string, ""} -> {:ok, listed(default)}
      {:string, source} -> source |> Literal.value() |> listed_result()
      _other -> :error
    end
  end

  @doc "The source text for a collection, ready to be written as an expression attribute."
  @spec write(list()) :: String.t()
  def write(items) when is_list(items),
    do: inspect(items, limit: :infinity, printable_limit: :infinity)

  @doc """
  One item changed, added or dropped, and the whole collection back.

  Out-of-range indexes are left alone rather than raising: the panel and the document can disagree
  for one render after an undo, and a stale click must not take the editor down.
  """
  @spec put(list(), non_neg_integer(), term()) :: list()
  def put(items, index, value) when is_list(items) and index >= 0 do
    case Enum.at(items, index) do
      nil -> items
      _present -> List.replace_at(items, index, value)
    end
  end

  @spec put_in_item(list(), non_neg_integer(), atom(), term()) :: list()
  def put_in_item(items, index, key, value) when is_atom(key) do
    case Enum.at(items, index) do
      %{} = item -> put(items, index, Map.put(item, key, value))
      _other -> items
    end
  end

  @spec add(list(), term()) :: list()
  def add(items, value) when is_list(items), do: items ++ [value]

  @spec remove(list(), non_neg_integer()) :: list()
  def remove(items, index) when is_list(items) and index >= 0, do: List.delete_at(items, index)

  @doc """
  What an empty row of this collection looks like, read off the ones already there.

  A list of maps gets a map with the same keys blank, so the new card carries the same fields as its
  neighbours; a list of anything else gets an empty string. An empty list has nothing to read, and
  the caller's own sample is the answer — `MishkaCmsCore.Runtime.PageBuilder.Starter` has one for
  the shapes it knows.
  """
  @spec blank(list(), term()) :: term()
  def blank(items, fallback \\ "") do
    cond do
      sample = Enum.find(items, &is_map/1) -> Map.new(Map.keys(sample), &{&1, ""})
      Enum.any?(items, &pair?/1) -> {"", ""}
      true -> fallback
    end
  end

  @doc """
  Whether an item is one side of a map or a keyword list rather than a value on its own.

  A `map` attribute is read out as its pairs — `chelekom-flash` holds `%{"info" => "…"}` and
  `chelekom-pagination` a map of query parameters — and a pair is edited as a pair, one field for
  each side.
  """
  @spec pair?(term()) :: boolean()
  def pair?({_key, _value}), do: true
  def pair?(_item), do: false

  @doc "One side of a pair changed, the other left as it was."
  @spec put_side(list(), non_neg_integer(), :key | :value, term()) :: list()
  def put_side(items, index, side, value) do
    case Enum.at(items, index) do
      {key, existing} -> put(items, index, (side == :key && {value, existing}) || {key, value})
      _not_a_pair -> items
    end
  end

  defp listed_result({:ok, value}), do: {:ok, listed(value)}
  defp listed_result(:error), do: :error

  defp listed(value) when is_list(value), do: value
  defp listed(%{} = value), do: Enum.to_list(value)
  defp listed(_other), do: []
end
