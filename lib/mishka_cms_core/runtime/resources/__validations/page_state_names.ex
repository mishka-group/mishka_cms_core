# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.PageStateNames do
  @moduledoc """
  Refuses a page whose `state` names an assign it may not have.

  Each name becomes an atom when the page compiles and an assign when it is mounted, so it is
  checked here, at the action boundary every writer passes — the builder, the page form, the JSON
  API and a seed alike:

    * it reads as an assign: `^[a-z_][a-zA-Z0-9_]*$`, and not `__`-prefixed;
    * it is not one the runtime or LiveView already owns — `@page`, `@flash`, `@csp_nonce` and the
      rest of `MishkaCmsCore.Runtime.PageState.reserved/0` — because assigning over one would break
      the page or the runtime around it;
    * it appears once, because the second value would silently replace the first.

  The code beside each name is `MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles`'s.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageState

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.changing_attribute?(changeset, :state) do
      false -> :ok
      true -> changeset |> Ash.Changeset.get_attribute(:state) |> List.wrap() |> checked()
    end
  end

  defp checked(entries) do
    names = Enum.map(entries, &name/1)

    case Enum.reject(names, &PageState.valid_name?/1) do
      [] -> unique(names)
      [bad | _rest] -> {:error, field: :state, message: refusal(bad)}
    end
  end

  defp unique(names) do
    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [name | _rest] ->
        {:error,
         field: :state,
         message:
           dgettext("errors", "The state names %{name} twice; each name is one assign.",
             name: name
           )}
    end
  end

  defp refusal(name) when is_binary(name) do
    case name in PageState.reserved() do
      true ->
        dgettext("errors", "%{name} is an assign the runtime already sets; choose another name.",
          name: name
        )

      false ->
        dgettext(
          "errors",
          "%{name} is not an assign name: start with a lowercase letter, then letters, digits or _.",
          name: inspect(name)
        )
    end
  end

  defp refusal(_name), do: dgettext("errors", "Every state entry needs a name.")

  defp name(%{name: name}), do: name
  defp name(%{"name" => name}), do: name
  defp name(_entry), do: nil

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts),
    do: [message: "Validates that each state name is a free, well-formed assign", vars: []]
end
