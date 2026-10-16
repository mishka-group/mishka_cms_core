# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.TailwindVerifyTest do
  @moduledoc """
  The version check must read a version the binary painted.

  ## What this cost

  Tailwind colours its own output. Under the development server it printed

      "\\e[3m\\e[1m\\e[34m≈\\e[39m\\e[22m\\e[23m tailwindcss \\e[34mv4.3.2\\e[39m"

  — a colour escape sits BETWEEN `tailwindcss ` and `v4.3.2`, so a pattern wanting them adjacent
  found nothing and `verify_binary/2` declared a perfectly good 79,759,970-byte binary unreadable.
  The same binary run by hand into a pipe emitted no colour and matched, which is exactly why this
  looked unreproducible.

  What followed was not a slow boot. Failing verification means installing, installing means
  downloading 80 MB from GitHub, and on a machine that cannot reach GitHub every Tailwind pass
  failed: no shared base, no site CSS, no site JS. `/contact` served
  `href="/assets/css/localhost/.css"` — an empty hash — with 41 bytes of stub behind it, and had no
  styles at all.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  # The pattern and the strip as `TailwindCompiler` applies them.
  @version ~r/tailwindcss v(\d+\.\d+\.\d+)/
  @ansi ~r/\e\[[0-9;]*[a-zA-Z]/

  defp uncoloured(output), do: String.replace(output, @ansi, "")

  @painted "\e[3m\e[1m\e[34m≈\e[39m\e[22m\e[23m tailwindcss \e[34mv4.3.2\e[39m\n\nUsage:\n"
  @plain "≈ tailwindcss v4.3.2\n\nUsage:\n"

  test "the coloured output is what the old check could not read" do
    refute Regex.run(@version, @painted),
           "if this matches, the bug this test is about cannot happen and the strip is dead code"
  end

  test "stripping the colour finds the version the binary reported" do
    assert [_whole, "4.3.2"] = Regex.run(@version, uncoloured(@painted))
  end

  # The uncoloured case is the one that always worked; it must keep working.
  test "output that was never painted is unaffected" do
    assert [_whole, "4.3.2"] = Regex.run(@version, uncoloured(@plain))
  end

  test "a version mismatch is still a mismatch, not a pass" do
    other = String.replace(@painted, "4.3.2", "3.4.17")

    assert [_whole, "3.4.17"] = Regex.run(@version, uncoloured(other))
  end

  # A TRUNCATED OR FOREIGN BINARY still has to fail. Stripping escapes must not make anything match.
  test "output with no version in it reads as no version" do
    for junk <- ["", "\e[34m\e[39m", "bash: no such file", "\e[1msome other tool v1.2.3\e[0m"] do
      refute Regex.run(@version, uncoloured(junk)), "#{inspect(junk)} was read as a version"
    end
  end

  test "the strip leaves the text itself alone" do
    assert uncoloured(@painted) == "≈ tailwindcss v4.3.2\n\nUsage:\n"
  end
end
