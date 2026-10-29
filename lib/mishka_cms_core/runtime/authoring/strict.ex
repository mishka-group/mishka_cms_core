# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Strict do
  @moduledoc """
  What the editor refuses to let past in development, and forgives in production.

  ## Why this exists

  Nine bugs were found in the editor's history over one stretch of work, and eight of them were
  silent: a filter comparing against a pinned nil, which Postgres reads as `= NULL` and never
  matches; a relationship that was never preloaded, so every row claimed to be by "System
  administrator"; a capped list used as a "did anything change?" signal, which saturated and stopped
  the editor recording anything at all. None raised. Each degraded to something that looks exactly
  like a legitimate empty answer, and each was found by somebody noticing that a screen looked wrong.

  The forgiving behaviour is right in production — an editor that takes itself down because one
  plugin returned the wrong shape is worse than one that carries on. It is wrong everywhere else,
  because during development an empty answer that should have been impossible is the single most
  valuable thing you can be told about.

  So the two are separated. Every check here raises in `:dev` and `:test` and compiles to nothing in
  `:prod` — `check!/2` and its friends are macros, so a release contains no call, no closure and no
  branch.

      config :mishka_cms_core, builder_strict: false

  ## What to check with it

  Conditions that are impossible unless something is already broken. Not user error, not a refused
  op, not a document that failed to parse — those are answers. A dangling child id in a document, a
  write to a table that is not there, a history entry pointing at nothing: those are bugs, and every
  one of them used to travel silently to somewhere far away from its cause.
  """
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  @strict Application.compile_env(:mishka_cms_core, :builder_strict, Mix.env() != :prod)

  @doc "Whether the strict checks are compiled in. False in a release."
  @spec enabled?() :: boolean()
  def enabled?, do: @strict

  @doc """
  Raises `where: why` unless `condition` holds. Compiles to nothing in production.

  The condition is not evaluated at all in a release, so an expensive check costs a developer time
  and costs a deployment nothing.
  """
  defmacro check!(condition, where, why) do
    case @strict do
      true ->
        quote do
          case unquote(condition) do
            truthy when truthy not in [false, nil] ->
              :ok

            _failed ->
              raise MishkaCmsCore.Runtime.Authoring.Strict.Violation,
                message: "#{unquote(where)}: #{unquote(why)}"
          end
        end

      false ->
        quote do
          _ = fn -> unquote(condition) end
          :ok
        end
    end
  end

  @doc "Raises outright — for a branch that should be unreachable. Compiles to nothing in production."
  defmacro violation!(where, why) do
    case @strict do
      true ->
        quote do
          raise MishkaCmsCore.Runtime.Authoring.Strict.Violation,
            message: "#{unquote(where)}: #{unquote(why)}"
        end

      false ->
        quote do
          _ = fn -> {unquote(where), unquote(why)} end
          :ok
        end
    end
  end

  @doc """
  Every way a document can be internally inconsistent, in one predicate.

  A `children` list naming an id that is not in `nodes` is the one that matters most: the serializer
  is deliberately total, so it skips what it cannot find — and a save writes what the serializer
  produced. A subtree that vanished this way leaves markup that parses perfectly, so the save's own
  "is this readable?" check cannot see it. The document is simply smaller than it was, silently.

  Returns `:ok` or `{:error, reason}`; `tree!/2` is the raising form the mutation funnel uses.
  """
  @spec inspect_tree(Tree.t()) :: :ok | {:error, String.t()}
  def inspect_tree(%Tree{} = tree) do
    with :ok <- every_child_exists(tree),
         :ok <- every_root_exists(tree),
         :ok <- parents_agree(tree) do
      no_cycles(tree)
    end
  end

  def inspect_tree(_other), do: {:error, "not a tree"}

  @doc "Raises when a document is internally inconsistent. Compiles to nothing in production."
  defmacro tree!(tree, where) do
    case @strict do
      true ->
        quote do
          case MishkaCmsCore.Runtime.Authoring.Strict.inspect_tree(unquote(tree)) do
            :ok ->
              :ok

            {:error, reason} ->
              raise MishkaCmsCore.Runtime.Authoring.Strict.Violation,
                message: "#{unquote(where)}: #{reason}"
          end
        end

      false ->
        quote do
          _ = fn -> unquote(tree) end
          :ok
        end
    end
  end

  defp every_child_exists(tree) do
    tree.nodes
    |> Enum.find_value(fn {id, node} ->
      case Enum.find(node.children, &(!is_map_key(tree.nodes, &1))) do
        nil -> nil
        missing -> "#{id} lists a child #{missing} that is not in the document"
      end
    end)
    |> problem()
  end

  defp every_root_exists(tree) do
    tree.roots
    |> Enum.find(&(!is_map_key(tree.nodes, &1)))
    |> case do
      nil -> nil
      missing -> "the root #{missing} is not in the document"
    end
    |> problem()
  end

  defp parents_agree(tree) do
    tree.nodes
    |> Enum.find_value(fn {id, node} -> disagreement(tree, id, node) end)
    |> problem()
  end

  defp disagreement(tree, id, %Node{parent_id: nil}) do
    case id in tree.roots do
      true -> nil
      false -> "#{id} has no parent but is not a root"
    end
  end

  defp disagreement(tree, id, %Node{parent_id: parent_id}) do
    case Tree.get(tree, parent_id) do
      nil -> "#{id} names a parent #{parent_id} that is not in the document"
      %Node{children: children} -> child_of(id, parent_id, children)
    end
  end

  defp child_of(id, parent_id, children) do
    case id in children do
      true -> nil
      false -> "#{id} names #{parent_id} as its parent, which does not list it as a child"
    end
  end

  # A cycle is what turns a walk into a hang, so it is worth the pass that finds it.
  defp no_cycles(tree) do
    tree.roots
    |> Enum.find_value(&descend(tree, &1, MapSet.new()))
    |> problem()
  end

  defp descend(tree, id, seen) do
    case MapSet.member?(seen, id) do
      true ->
        "#{id} is its own ancestor"

      false ->
        seen = MapSet.put(seen, id)
        tree |> Tree.child_ids(id) |> Enum.find_value(&descend(tree, &1, seen))
    end
  end

  defp problem(nil), do: :ok
  defp problem(reason), do: {:error, reason}
end
