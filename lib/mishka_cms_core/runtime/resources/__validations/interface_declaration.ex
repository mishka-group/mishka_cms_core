# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.InterfaceDeclaration do
  @moduledoc """
  Refuses a component whose declared attributes or slots could not compile.

  ## Why this is on the resource and not in the editor

  A component's `attrs` and `slots` reach the database from three places — the Components table's
  form, the builder's Interface tab, and any script or import that writes the columns — and the rule
  is the same everywhere: a name becomes an atom and is written into a `def`, so `Size` and
  `my-size` are not names, one name may not be declared twice, and Phoenix refuses `required: true`
  together with a default ("attributes should not have a default value if they are required").

  Enforced in the editor alone, each of those surfaces would have needed its own copy, and the two
  that are not the editor would have had none. Here it is one answer at the action boundary, which is
  where `MishkaCmsCore.Runtime.Resources.Validations.CodeChange` and `TemplateCompiles` already sit
  for the same reason.

  `MishkaCmsCore.Runtime.PageBuilder.Interface.validate/2` holds the rules themselves, because the
  editor also wants them BEFORE a save — to mark the offending row while somebody is still typing in
  it. This is the half that makes them true of the record.

  ## What it does not do

  It says nothing about whether the template AGREES with the declaration. A component may legitimately
  be saved with an attribute its markup does not read yet, and a template that reads `@size` with no
  `attr :size` is advice the editor gives — see `Interface.undeclared/3` — rather than a write to
  refuse. Half-finished work has to be storable.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Interface

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    attrs = declared(changeset, :attrs)
    slots = declared(changeset, :slots)

    case Interface.validate(attrs, slots) do
      [] -> :ok
      [{kind, index, message} | _rest] -> refuse(kind, index, message)
    end
  end

  # The value being written when there is one, and the stored value when this action does not touch
  # it — a change to `attrs` alone must still be checked against the slots already on the record,
  # because "declared twice" is a question about the pair.
  defp declared(changeset, field) do
    case Ash.Changeset.fetch_argument_or_change(changeset, field) do
      {:ok, value} when is_list(value) -> value
      _unchanged -> changeset.data |> Map.get(field) |> List.wrap()
    end
  end

  defp refuse(kind, index, message) do
    {:error,
     field: field_for(kind),
     message:
       Gettext.dgettext(MishkaCmsCore.Gettext, "errors", template(kind),
         number: index + 1,
         detail: message
       )}
  end

  defp field_for(:attr), do: :attrs
  defp field_for(_slot), do: :slots

  # Named by position, because the row that is wrong may be the one with no name at all — and
  # "attribute 3" is something a reader can count to in a form that draws them in order.
  defp template(:attr), do: dgettext_noop("errors", "#%{number} attribute: %{detail}")
  defp template(_slot), do: dgettext_noop("errors", "#%{number} slot: %{detail}")
end
