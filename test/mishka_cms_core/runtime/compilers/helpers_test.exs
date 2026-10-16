# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.HelpersTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.Compilers.Helpers

  describe "loaded?/1 — single source of truth for runtime module presence" do
    test "true for a module that is loaded in the code table" do
      assert Helpers.loaded?(__MODULE__)
      assert Helpers.loaded?(Enum)
    end

    test "false for a module that was never compiled/loaded" do
      refute Helpers.loaded?(
               :"Elixir.Mishka.Runtime.NotCompiled#{System.unique_integer([:positive])}"
             )
    end
  end

  # `:global` backs off about 4 s a try once it has stopped doubling, so a wait is turned into tries.
  describe "install_lock_retries/1 — how long a build waits for a Tailwind or esbuild install" do
    test "ten minutes unless configured" do
      assert Helpers.install_lock_retries() == Helpers.install_lock_retries(:timer.minutes(10))
      assert Helpers.install_lock_retries(:timer.minutes(10)) == 154
    end

    test "a longer wait is more tries, and a wait shorter than the back-off is its first five" do
      assert Helpers.install_lock_retries(:timer.minutes(1)) == 19
      assert Helpers.install_lock_retries(:timer.minutes(30)) == 454
      assert Helpers.install_lock_retries(0) == 5
    end
  end
end
