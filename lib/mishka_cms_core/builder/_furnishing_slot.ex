# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.FurnishingSlot do
  @moduledoc """
  One sample `<:slot>` entry in a component's declared furnishing.

  Its own module because a component's furnishing is a THIRD PARTY's JSON — see
  `MishkaCmsCore.Builder.Furnishing` — and a slot entry that is a string, or a map with no name, has
  to fail on its own rather than take the whole furnishing down with it.

  `attrs` are written onto the slot verbatim, so this is where an `<:option>` says which `value` it
  carries. Only the slot's own attributes belong here; the component's are `attrs` on the component.
  """

  use GuardedStruct

  guardedstruct do
    field(:name, String.t(), enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
    field(:body, String.t(), default: "", derives: "sanitize(trim)")
    field(:attrs, map(), default: %{}, derives: "validate(map)")
  end

  @doc """
  Validates one entry, returning `:error` rather than raising — a kit's furnishing is untrusted.
  """
  @spec check(term()) :: {:ok, t()} | :error
  def check(entry) when is_map(entry) do
    case builder(atomise(entry)) do
      {:ok, slot} -> {:ok, %{slot | attrs: stringify_attrs(slot.attrs)}}
      _invalid -> :error
    end
  end

  def check(_entry), do: :error

  defp atomise(entry) do
    Map.new(entry, fn
      {key, value} when is_binary(key) -> {safe_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  # An unknown key is dropped rather than crashing on `String.to_existing_atom/1`: a kit is free to
  # carry fields this CMS has never heard of, exactly as `MishkaCmsCore.UiKit.Contract` allows.
  defp safe_key("name"), do: :name
  defp safe_key("body"), do: :body
  defp safe_key("attrs"), do: :attrs
  defp safe_key(other), do: other

  # The writer interpolates these straight into HEEx, where an attribute name is text either way.
  defp stringify_attrs(attrs) when is_map(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp stringify_attrs(_attrs), do: %{}
end
