# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.CodeReads do
  @moduledoc """
  What a snippet reads, what it calls and what it assigns, read off the parsed code.

  The sibling of `MishkaCmsCore.Runtime.PageBuilder.CodeFlags`, which answers a different question
  the same way: parse it, walk it, and let the shape of the tree say what a thing is. An assign is
  the node `{:@, meta, [{name, meta, context}]}` — so `@flash` inside a string, inside a comment, or
  written out in a code sample is not one, and neither is `@moduledoc "…"`, whose context is the
  text rather than an atom.

      iex> alias MishkaCmsCore.Runtime.PageBuilder.CodeReads
      iex> CodeReads.assigns(~S|[@size, "@colour is not one"]|) |> MapSet.to_list()
      ["size"]

  For a template rather than a snippet, `MishkaCmsCore.Runtime.PageBuilder.Markup.expressions/1`
  gives the expressions to hand here.

  ## What it does with code it cannot parse

  Nothing found. An author is mid-sentence in a box they are typing into, and `CodeCheck` is what
  tells them the code will not compile — a half-typed line is not this module's news to break.

  `assigned/1` is the exception: its caller decides from the answer that an assign is NOT written,
  so code it cannot read is `:unknown`.
  """

  @doc """
  Every assign a snippet reads, by name and without the `@`.

      iex> MishkaCmsCore.Runtime.PageBuilder.CodeReads.assigns("@a <> @b") |> MapSet.to_list()
      ["a", "b"]
  """
  @spec assigns(String.t() | nil) :: MapSet.t(String.t())
  def assigns(code), do: code |> walked(&assign/1) |> MapSet.new()

  @doc """
  Every call a snippet makes by a bare name, as `{name, arguments}` with the arguments still quoted.

  Bare-name and nothing else: `String.trim(x)` is a call on a module and is not one of these, which
  is what makes this the right question to ask about a component's own helpers.
  """
  @spec calls(String.t() | nil) :: [{atom(), [Macro.t()]}]
  def calls(code), do: walked(code, &call/1)

  @doc """
  Every assign a snippet may write, by name — or `:unknown` when it writes one whose name it works
  out at runtime, or when it does not parse.

  A write is:

    * `assign/2,3`, `assign_new/3`, `assign_async/3,4` and `update/3`, bare, piped or on any module
      but `Map`;
    * on `Map`, `put/3`, `put_new/3`, `put_new_lazy/3`, `replace/3`, `replace!/3`, `update/4`,
      `update!/3` and `merge/2,3`;
    * a map update, `%{map | key: value}`;
    * `put_in`, `update_in`, `get_and_update_in` and `pop_in` on a path through `assigns`, which is
      `:unknown`.

  A key given as anything but an atom — a variable, a call, a keyword list or map that is not
  written out — is `:unknown`. On `Map` and in a map update it is `:unknown` only when the map is
  `assigns` or `socket.assigns`; any other map there is ordinary data. `assign(socket, assigns)`
  writes nothing new: it hands the component what it was handed.

  Unlike `assigns/1`, code that does not parse is `:unknown` rather than nothing.

      iex> MishkaCmsCore.Runtime.PageBuilder.CodeReads.assigned(
      ...>   "socket |> assign(:page, 1) |> assign(loading: true)"
      ...> )
      {:ok, MapSet.new(["loading", "page"])}

      iex> MishkaCmsCore.Runtime.PageBuilder.CodeReads.assigned("assign(socket, key, 1)")
      :unknown
  """
  @spec assigned(String.t() | nil) :: {:ok, MapSet.t(String.t())} | :unknown
  def assigned(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> ast |> writes() |> settled()
      {:error, _unparseable} -> :unknown
    end
  end

  def assigned(nil), do: {:ok, MapSet.new()}

  @assigning [:assign, :assign_new, :assign_async, :update]
  @map_writes [:put, :put_new, :put_new_lazy, :replace, :replace!, :update, :update!]
  @path_writes [:put_in, :update_in, :get_and_update_in, :pop_in]

  # A PIPE IS READ AS THE CALL IT MAKES, so `socket |> assign(:page, 1)` is `assign(socket, :page, 1)`
  # and the key is the second argument however the call was written.
  defp writes(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn node, found ->
        node = unpiped(node)
        {node, [written(node) | found]}
      end)

    found
  end

  defp unpiped({:|>, _meta, [left, {name, meta, args}]}) when is_list(args),
    do: {name, meta, [left | args]}

  defp unpiped({:|>, _meta, [left, {name, meta, context}]})
       when is_atom(name) and is_atom(context),
       do: {name, meta, [left]}

  defp unpiped(node), do: node

  defp written({{:., _dot, [{:__aliases__, _alias, [:Map]}, name]}, _meta, [map, key | _rest]})
       when name in @map_writes,
       do: map_key(map, key)

  defp written(
         {{:., _dot, [{:__aliases__, _alias, [:Map]}, :merge]}, _meta, [map, other | _rest]}
       ),
       do: map_keys(map, other)

  defp written({{:., _dot, [{:__aliases__, _alias, [:Map]}, _reads]}, _meta, _args}),
    do: {:keys, []}

  defp written({{:., _dot, [_module, name]}, _meta, [_ | _] = args}) when name in @assigning,
    do: assigning(args)

  defp written({name, _meta, [_ | _] = args}) when name in @assigning, do: assigning(args)

  defp written({name, _meta, [_ | _] = args}) when name in @path_writes do
    case Enum.any?(args, &through_assigns?/1) do
      true -> :unknown
      false -> {:keys, []}
    end
  end

  defp written({:%{}, _meta, [{:|, _bar, [map, pairs]}]}), do: map_keys(map, pairs)

  defp written(_node), do: {:keys, []}

  # `assign(socket, assigns)` hands over what the caller handed in: no key the caller did not write.
  defp assigning([_target, {:assigns, _meta, context}]) when is_atom(context), do: {:keys, []}
  defp assigning([_target, keys]), do: keys(keys)
  defp assigning([_target, key, _value | _rest]), do: named(key)
  defp assigning(_other), do: :unknown

  defp named(key) when is_atom(key), do: {:keys, [key]}
  defp named(keys) when is_list(keys), do: keys |> Enum.map(&{&1, nil}) |> keys()
  defp named(_computed), do: :unknown

  defp map_key(map, key) do
    case {named(key), assigns?(map)} do
      {:unknown, false} -> {:keys, []}
      {found, _map} -> found
    end
  end

  defp map_keys(map, pairs) do
    case {keys(pairs), assigns?(map)} do
      {:unknown, false} -> {:keys, []}
      {found, _map} -> found
    end
  end

  # A STRING KEY NAMES NO ASSIGN, so a map written with one says nothing about them.
  defp keys(pairs) when is_list(pairs) do
    with true <- Enum.all?(pairs, &match?({_key, _value}, &1)),
         names = pairs |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_binary/1),
         true <- Enum.all?(names, &is_atom/1) do
      {:keys, names}
    else
      false -> :unknown
    end
  end

  defp keys({:%{}, _meta, [{:|, _bar, [_map, pairs]}]}), do: keys(pairs)
  defp keys({:%{}, _meta, pairs}), do: keys(pairs)
  defp keys(_computed), do: :unknown

  defp assigns?({:assigns, _meta, context}) when is_atom(context), do: true
  defp assigns?({{:., _dot, [_owner, :assigns]}, _meta, []}), do: true
  defp assigns?(_map), do: false

  defp through_assigns?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or node == :assigns or assigns?(node)}
      end)

    found?
  end

  defp settled(found) do
    case Enum.member?(found, :unknown) do
      true ->
        :unknown

      false ->
        {:ok, for({:keys, keys} <- found, key <- keys, into: MapSet.new(), do: to_string(key))}
    end
  end

  defp assign({:@, _meta, [{name, _name_meta, context}]})
       when is_atom(name) and is_atom(context),
       do: [Atom.to_string(name)]

  defp assign(_node), do: []

  # A CALL AND A VARIABLE ARE THE SAME SHAPE BUT FOR THE LAST ELEMENT: `foo()` quotes with an empty
  # argument list and `foo` with `nil`, so a list is what tells them apart. Operators quote this way
  # too and are left in — every caller matches on a name it already knows.
  defp call({name, _meta, args}) when is_atom(name) and is_list(args), do: [{name, args}]

  defp call(_node), do: []

  defp walked(code, fun) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> collected(ast, fun)
      {:error, _half_typed} -> []
    end
  end

  defp walked(_code, _fun), do: []

  defp collected(ast, fun) do
    {_ast, found} = Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ fun.(node)} end)

    found
  end
end
