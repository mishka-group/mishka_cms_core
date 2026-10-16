# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake do
  @moduledoc """
  A second icon set, so the facade can be tested with more than one registered.

  Deliberately minimal and deliberately DIFFERENT from heroicons: one glyph, one weight. The single
  weight is the point — it is what proves the variant row narrows to the suffixes every registered
  set actually ships, rather than offering a button half the results cannot honour.
  """

  @behaviour MishkaCmsCore.Runtime.PageBuilder.IconLibrary

  @impl true
  def prefixes, do: ["fake-"]

  @impl true
  def label, do: "Fake"

  @impl true
  def all, do: ["fake-star"]

  @impl true
  def variants, do: [{"", "Outline"}]

  @impl true
  def svg(name, size)

  def svg("fake-star", size), do: {:safe, [~s(<svg width="#{size}" height="#{size}"></svg>)]}
  def svg(_name, _size), do: nil

  @impl true
  def css(names) do
    names
    |> Enum.filter(&(&1 in all()))
    |> Enum.map_join("\n", &".#{&1}{content:'FAKE';}")
  end

  @impl true
  def search(query, opts) do
    limit = Keyword.get(opts, :limit, 60)
    needle = query |> to_string() |> String.trim() |> String.downcase()

    all()
    |> Enum.filter(&String.contains?(&1, needle))
    |> Enum.take(limit)
  end

  @impl true
  def count(query, _variant), do: length(search(query, limit: 1000))
end
