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

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler

  @moduletag :unit

  @painted "\e[3m\e[1m\e[34m≈\e[39m\e[22m\e[23m tailwindcss \e[34mv4.3.2\e[39m\n\nUsage:\n"
  @plain "≈ tailwindcss v4.3.2\n\nUsage:\n"

  test "reads the version out of output the binary painted" do
    assert TailwindCompiler.reported_version(@painted) == "4.3.2"
  end

  test "output that was never painted is unaffected" do
    assert TailwindCompiler.reported_version(@plain) == "4.3.2"
  end

  test "a version mismatch is still a mismatch, not a pass" do
    other = String.replace(@painted, "4.3.2", "3.4.17")

    assert TailwindCompiler.reported_version(other) == "3.4.17"
  end

  # A TRUNCATED OR FOREIGN BINARY still has to fail. Stripping escapes must not make anything match.
  test "output with no version in it reads as no version" do
    for junk <- ["", "\e[34m\e[39m", "bash: no such file", "\e[1msome other tool v1.2.3\e[0m"] do
      assert TailwindCompiler.reported_version(junk) == nil,
             "#{inspect(junk)} was read as a version"
    end
  end
end
