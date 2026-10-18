# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.StatefulIds do
  @moduledoc """
  Refuses a page that places two live components under one `id`.

  ## Why this is a rule and not a warning

  `Phoenix.LiveView.Diff` raises on it:

      found duplicate ID "…" for component … when rendering template

  inside whichever LiveView renders the page, where nothing contains it. An advisory would be the
  wrong shape for something that is certain to take the page down rather than merely likely to look
  wrong.

  ## Why the editor's own minting is not enough

  `EditorSession.with_id/4` mints one per drop and `PageBuilder.Ids.dedupe/2` renames the arrivals
  that collided — but `dedupe/2` is deliberately given the nodes that ARRIVED, and answers nothing
  when a whole document arrives at once. That is exactly what the source window does: an author
  pastes markup, and a copy-paste of a component tag inside it carries the same id twice with
  nothing to call an arrival. A draft restore and a seeded template have the same shape.

  So this is asked of the stored markup, at the action boundary, where every writer passes.

  ## Only live components, and only literal ids

  A function component with a duplicate id is a bad idea and not a crash, and the editor already
  renames those. `id={@row.id}` is the author binding the id to their data and two of them are not a
  collision — the same distinction `PageBuilder.Ids` draws.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  require Ash.Query

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.changing_attribute?(changeset, :template) do
      false -> :ok
      true -> checked(Ash.Changeset.get_attribute(changeset, :template) || "")
    end
  end

  defp checked(template) do
    template
    |> placements()
    |> case do
      [] -> :ok
      placements -> refusal(placements)
    end
  end

  defp refusal(placements) do
    live = placements |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> stateful_among()

    placements
    |> Enum.filter(fn {name, _id} -> name in live end)
    |> Enum.group_by(fn {_name, id} -> id end)
    |> Enum.find(fn {_id, group} -> match?([_, _ | _], group) end)
    |> case do
      nil ->
        :ok

      {id, group} ->
        {:error,
         field: :template,
         message:
           dgettext(
             "errors",
             "two live components share the id %{id} (%{components}). LiveView identifies a live component by its id and refuses a page carrying the same one twice — give each its own.",
             id: inspect(id),
             components: group |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")
           )}
    end
  end

  # UNPARSEABLE MARKUP IS SOMEBODY ELSE'S REFUSAL. `Validations.PageCodeCompiles` says what is
  # actually wrong with it, and two sentences about one typo is worse than one.
  defp placements(template) when is_binary(template) do
    case Tree.parse(template) do
      {:ok, tree} ->
        for node <- Tree.walk(tree),
            node.kind == :component,
            name = Node.component_name(node),
            is_binary(name),
            {:string, id} <- [Node.attr(node, "id")],
            trimmed = String.trim(id),
            trimmed != "",
            do: {name, trimmed}

      _unparseable ->
        []
    end
  end

  defp placements(_template), do: []

  defp stateful_among([]), do: []

  defp stateful_among(names) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name in ^names and stateful == true)
    |> Ash.Query.select([:name])
    |> Ash.read()
    |> case do
      {:ok, %{results: rows}} -> Enum.map(rows, & &1.name)
      {:ok, rows} when is_list(rows) -> Enum.map(rows, & &1.name)
      _unreadable -> []
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts),
    do: [message: "Validates that no two live components on a page share an id", vars: []]
end
