# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.StatefulShape do
  @moduledoc """
  Refuses a component that says it keeps state and is shaped so that it cannot.

  Two combinations, both of which compiled quietly before this and failed later somewhere the author
  could not connect to what they did.

  ## Declaring a name LiveView owns

  `Phoenix.Component.assign/3` and `assign_new/3` refuse five names on a socket: its
  `@non_assignables`, `[:uploads, :streams, :socket, :myself]`, and `:flash`, which
  `validate_assign_key!/1` refuses in a clause of its own. Neither is exported, so nothing can consult
  them; the names are repeated here, which is a copy and is why it is short and named. It is the ONLY
  copy: `MishkaCmsCore.UiKit.Contract` and the component compiler read it through
  `reserved_names/0`, so the three refusals cannot drift apart.

  A function component may declare an attr called `socket` and get away with it because nothing ever
  assigns one; a live component cannot, and the failure arrives inside a visitor's LiveView rather
  than at the point of writing. A SLOT is the same question: the compiler's `update_many/1` assigns a
  declared slot onto the socket under its name exactly as it assigns an attr, so `slot :streams`
  raises the moment a parent fills it.

  Consequence worth stating: `chelekom-file-field` declares `attr :uploads` and therefore cannot be
  stateful — which is correct anyway, since `allow_upload/3` is a `Phoenix.LiveView` function a
  LiveComponent cannot call.

  ## Carrying `extra.clauses`

  34 of the kit's installed components dispatch through `extra.clauses`, which compile to a `case`
  where each branch has its own root element. A stateful component has to have ONE static root — the
  diff raises otherwise — and the compiler's stateful emitter reads the template and not the clause
  list, so before this the clauses were silently discarded: a component that rendered only its base
  branch, with nothing said anywhere.

  Refusing is the honest half of that. The other half is that a single root cannot be proven from a
  clause list, only from a render, which is `MishkaCmsCore.Runtime.Compilers.ComponentCompiler`'s
  root probe.

  ## Only what this write changed

  A component that was stateless and is being made stateful is checked; one whose `stateful` is not
  changing and whose declarations are not changing is left alone, so a row stored before this
  validation existed stays editable.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  # Phoenix.Component's own `@non_assignables`, plus the `:flash` it refuses separately. Neither is
  # exported.
  @reserved ~w(uploads streams socket myself flash)

  @doc """
  The names a live component cannot declare, as an attr or as a slot, because LiveView assigns them
  itself.
  """
  @spec reserved_names() :: [String.t()]
  def reserved_names, do: @reserved

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case stateful?(changeset) and touched?(changeset) do
      false -> :ok
      true -> refusal(changeset)
    end
  end

  defp refusal(changeset) do
    with :ok <- no_reserved_names(changeset) do
      no_clauses(changeset)
    end
  end

  # Attrs first and then slots, reporting the first of the two that is wrong, the way
  # `Validations.InterfaceDeclaration` reports the first faulty row.
  defp no_reserved_names(changeset) do
    [:attrs, :slots]
    |> Enum.map(&{&1, taken(changeset, &1)})
    |> Enum.find(fn {_field, taken} -> taken != [] end)
    |> case do
      nil ->
        :ok

      {field, taken} ->
        {:error,
         field: field,
         message:
           Gettext.dgettext(MishkaCmsCore.Gettext, "errors", reserved_message(taken),
             names: Enum.join(taken, ", ")
           )}
    end
  end

  defp taken(changeset, field) do
    changeset
    |> Ash.Changeset.get_attribute(field)
    |> List.wrap()
    |> Enum.map(&name_of/1)
    |> Enum.filter(&(&1 in @reserved))
  end

  defp no_clauses(changeset) do
    changeset
    |> Ash.Changeset.get_attribute(:extra)
    |> clauses()
    |> case do
      [] ->
        :ok

      _some ->
        {:error,
         field: :stateful,
         message:
           dgettext_noop(
             "errors",
             "a live component cannot dispatch through clauses — each branch has its own root element and a live component must have exactly one. Split it into separate components, or leave this one as a function component."
           )}
    end
  end

  defp clauses(%{} = extra),
    do: (Map.get(extra, "clauses") || Map.get(extra, :clauses) || []) |> List.wrap()

  defp clauses(_extra), do: []

  defp name_of(%{} = declaration),
    do: to_string(Map.get(declaration, "name") || Map.get(declaration, :name) || "")

  defp name_of(_declaration), do: ""

  defp reserved_message([_one]),
    do:
      dgettext_noop(
        "errors",
        "a live component cannot declare %{names} — LiveView assigns it itself, and assigning over it raises"
      )

  defp reserved_message(_many),
    do:
      dgettext_noop(
        "errors",
        "a live component cannot declare %{names} — LiveView assigns them itself, and assigning over it raises"
      )

  defp stateful?(changeset), do: Ash.Changeset.get_attribute(changeset, :stateful) == true

  # WHAT THIS WRITE TOUCHED. Becoming stateful is a change worth checking; so is changing the
  # declarations or the clause list of something already stateful. A write that moves neither — a
  # rename, a description — must not be refused because of a row somebody stored before this rule.
  defp touched?(changeset) do
    Enum.any?(
      [:stateful, :attrs, :slots, :extra],
      &Ash.Changeset.changing_attribute?(changeset, &1)
    )
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts),
    do: [message: "Validates that a stateful component is shaped so it can be one", vars: []]
end
