# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.FormRole do
  @moduledoc """
  What part of a form a component plays, declared by whoever wrote it rather than guessed here.

      "extra": {"form": {"role": "field", "field": "bind", "name": "input_name", "label": "caption"}}

  `role` is the only required key and is one of `wrapper`, `field`, `error`, `fieldset`, `submit`.
  Every other key NAMES ONE OF THIS COMPONENT'S OWN ATTRIBUTES, so a kit that calls its
  `Phoenix.HTML.FormField` attribute `bind` says so, and the editor writes `bind={f[:email]}` without
  ever knowing the word "field".

  `field`, `name` and `value` are attributes the editor WRITES; `label` is one it reads the author's
  own word out of (`MishkaCmsCore.Runtime.PageBuilder.Fields.field_label/2`). Every one of the four is
  an attribute, which is why a slot is not a candidate — see below.

  ## A wrong role is worse than no role

  Same doctrine and same failure mode as `MishkaCmsCore.Builder.Furnishing`: this is a third party's
  JSON, so anything unreadable answers `:none` and `MishkaCmsCore.Runtime.PageBuilder.Fields` infers
  instead — which is what every kit shipped before this key existed gets, and is right most of the
  time. A malformed declaration never costs the component, and a malformed component never costs the
  kit (`MishkaCmsCore.UiKit.Contract`).

  ## A key that points at nothing is dropped

  `build/2` keeps only the keys whose value names an ATTRIBUTE the component actually declares.
  Writing `bind={f[:x]}` onto a component with no `bind` attribute is the one failure this module
  exists to prevent: the attribute is dropped on the way to the renderer, the field is called with
  neither a binding nor a name, and `KeyError :name` lands inside LiveView's diff.

  A slot is not a candidate, and validating against attrs AND slots reopened the same failure from
  the other side: `"field": "inner_block"` named something the component really does declare, so the
  key survived, and the editor then wrote `inner_block={f[:email]}` — which is not an attribute the
  component accepts either. Every key here names something the editor writes into or reads out of an
  attribute, so an attribute is the only thing it can be.
  """

  use GuardedStruct

  alias MishkaCmsCore.Runtime.PageBuilder.Inspector

  @roles ~w(wrapper field error fieldset submit)

  guardedstruct do
    field(:role, :string,
      enforce: true,
      derives:
        "sanitize(trim, downcase) validate(enum=String[wrapper::field::error::fieldset::submit])"
    )

    field(:bindings, :map, default: %{}, derives: "validate(map)")
  end

  @doc "Every role a kit may declare, so it can be read rather than guessed."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc """
  This component's declared role, or `:none`.

  `:none` is not a failure — most components declare nothing, and inference is the answer for them.
  It is also what a malformed declaration gets, for the reason in the moduledoc.
  """
  @spec build(term(), map()) :: {:ok, t()} | :none
  def build(declared, entry) when is_map(declared) and map_size(declared) > 0,
    do: from_role(role(declared), declared, entry)

  def build(_declared, _entry), do: :none

  # The `enforce: true` on `role` guards a MISSING key, not a nil value, and the enum derive does not
  # run on nil either — so a declaration carrying only bindings would validate into `%{role: nil}`
  # and reach `String.to_existing_atom(nil)` in the caller. Nothing but a string is a role.
  defp from_role(role, declared, entry) when is_binary(role) do
    case builder(%{role: role, bindings: %{}}) do
      {:ok, struct} -> {:ok, %{struct | bindings: bindings(declared, entry)}}
      _unusable -> :none
    end
  end

  defp from_role(_role, _declared, _entry), do: :none

  defp role(%{"role" => role}), do: role
  defp role(%{role: role}), do: role
  defp role(_declared), do: nil

  defp bindings(declared, entry) do
    known = declared_names(entry)

    for {key, value} <- declared,
        to_string(key) != "role",
        is_binary(value),
        MapSet.member?(known, value),
        into: %{},
        do: {to_string(key), value}
  end

  defp declared_names(entry) do
    entry
    |> Inspector.attrs()
    |> Enum.map(&Inspector.name/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new(&to_string/1)
  end
end
