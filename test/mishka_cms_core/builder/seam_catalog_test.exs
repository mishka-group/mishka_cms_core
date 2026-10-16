# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.SeamCatalogTest do
  @moduledoc """
  Every event the builder advertises must actually fire.

  This is the failure the seam work was fixing, and it is the only one that cannot be caught by
  using the editor: a declared event with no call site behaves exactly like a working one right up
  until it matters. The author reads the catalog, writes the plugin, registers it, and watches
  nothing happen — with no error to read, because from the outside "no plugin contributed" and
  "nothing ever asked" are the same silence.

  So the catalog is checked against the source rather than against itself: each registry in
  `Events.registries/0` must be collected somewhere in `lib`, and each named seam must be called.
  Adding an event without a caller fails here, which is the point — the catalog can only grow with
  the code.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.Events

  @moduletag :unit

  # Every named seam in the catalog: the transforms, the gates and the announcements. The registries
  # come from `Events.registries/0`, which is already the list.
  @named ~w(history_query before_draft_save after_draft_save before_comment after_comment
            before_code_apply before_token_set before_class_save before_element_css
            after_element_css before_ask containment preview_document examples preset_choices
            toolbar_invoked form_role form_customized form_created)a

  defp source do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(&String.ends_with?(&1, "builder/events.ex"))
    |> Enum.map_join("\n", &File.read!/1)
  end

  describe "the catalog against the code" do
    setup do
      %{source: source()}
    end

    test "every registry it declares is collected somewhere", %{source: source} do
      dead =
        Events.registries()
        |> Map.keys()
        |> Enum.reject(&Regex.match?(~r/collect\w*\(\s*:#{&1}\b/, source))

      assert dead == [], "declared but never collected: #{inspect(dead)}"
    end

    test "every named seam it declares is called somewhere", %{source: source} do
      dead = Enum.reject(@named, &Regex.match?(~r/Events\.#{&1}\(/, source))

      assert dead == [], "declared but never fired: #{inspect(dead)}"
    end

    test "and the module really exports each of them", _context do
      exported = Events.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      for name <- @named, do: assert(name in exported, "#{name} is documented but not exported")
    end
  end

  describe "the names themselves" do
    test "every registry event is namespaced to the builder" do
      for {_registry, {event, key}} <- Events.registries() do
        assert String.starts_with?(event, "builder:")
        assert is_atom(key)
      end
    end

    test "no two registries share an event name" do
      names = Events.registries() |> Map.values() |> Enum.map(&elem(&1, 0))

      assert length(Enum.uniq(names)) == length(names)
    end
  end
end
