# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Marketplace.Token do
  @moduledoc """
  One design token — the validated shape both the Mock adapter and any real backend must produce.

  `usage` is how many places in the site currently reference the token; the Studio sorts and dims by
  it, so an unused token is visibly unused. `custom?` marks a token the team added rather than one
  the theme shipped with, which the CSS generator highlights.
  """
  use GuardedStruct

  guardedstruct do
    field(:category, String.t(),
      enforce: true,
      derives: "validate(enum=String[color::type::space::radius::shadow::motion::screen])"
    )

    field(:label, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(string, not_empty)"
    )

    field(:key, String.t(), enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
    field(:value, String.t(), enforce: true, derives: "validate(string, not_empty)")
    field(:usage, integer(), default: 0)
    field(:custom?, boolean(), default: false)
    field(:glyph, String.t(), default: "")
  end

  @doc "Builds a token, raising on an invalid one — seeds are compile-time data, not user input."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case builder(attrs) do
      {:ok, token} -> token
      error -> raise ArgumentError, "invalid design token #{inspect(attrs)}: #{inspect(error)}"
    end
  end

  @doc ~s|Whether a token matches a category filter — `"all"`, `"custom"`, or a category name.|
  @spec matches?(t(), String.t()) :: boolean()
  def matches?(_token, "all"), do: true
  def matches?(token, "custom"), do: token.custom?
  def matches?(token, category), do: token.category == category
end
