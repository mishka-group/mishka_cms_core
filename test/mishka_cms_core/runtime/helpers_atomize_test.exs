# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.HelpersAtomizeTest do
  @moduledoc """
  What `atomize_keys/1` may and may not add to the atom table.

  The maps it is handed are JSONB columns with no schema over their keys — a component's `extra`, an
  attr's `opts`, a page's `content` — so whoever authors a document chooses those key names. Atoms
  are never garbage collected and the VM stops at about a million of them, so converting every key
  made the document author the one who decides how many there are.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Helpers

  describe "keys the code already names" do
    test "are converted, so a caller matching on them still matches" do
      assert %{template: "<div/>", attrs: []} =
               Helpers.atomize_keys(%{"template" => "<div/>", "attrs" => []})
    end

    test "including deep inside the structure" do
      assert %{attrs: [%{name: "size"}]} =
               Helpers.atomize_keys(%{"attrs" => [%{"name" => "size"}]})
    end

    test "and an atom key is left as it is" do
      assert %{template: "x"} = Helpers.atomize_keys(%{template: "x"})
    end
  end

  describe "a key nobody names" do
    test "stays a binary rather than becoming an atom" do
      key = "authored_key_#{System.unique_integer([:positive])}"

      assert %{^key => "value"} = Helpers.atomize_keys(%{key => "value"})
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "even nested under a key that is converted" do
      key = "nested_key_#{System.unique_integer([:positive])}"

      assert %{extra: %{^key => 1}} = Helpers.atomize_keys(%{"extra" => %{key => 1}})
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    # The one that matters: a document with many authored keys must not be able to fill the table.
    #
    # Each flooded key is checked by name, not through the VM's atom count: that count is global
    # and the suite is concurrent, so a test compiling a runtime module meanwhile moves it by
    # hundreds. The keys carry a unique integer, so nothing else can have made any of them an atom.
    test "so two thousand of them add nothing to the atom table" do
      keys = for n <- 1..2_000, do: "flood_#{System.unique_integer([:positive])}_#{n}"

      result = Helpers.atomize_keys(Map.new(keys, &{&1, true}))

      assert Enum.sort(Map.keys(result)) == Enum.sort(keys)
      for key <- keys, do: assert_raise(ArgumentError, fn -> String.to_existing_atom(key) end)
    end
  end
end
