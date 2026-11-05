# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.AdminCssTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir

  test "the core's own sources compile no rule for a picture they only mention", %{tmp_dir: dir} do
    input = Path.join(dir, "in.css")
    output = Path.join(dir, "out.css")
    lib = Path.expand("../../../lib", __DIR__)

    File.write!(input, """
    @import "tailwindcss" source(none);
    @source "#{lib}/**/*.{ex,heex,eex}";
    """)

    assert 0 =
             Tailwind.install_and_run(:mishka_cms_core_css, [
               "--input=#{input}",
               "--output=#{output}"
             ])

    css = File.read!(output)

    assert css =~ "flex"
    refute css =~ "hero.jpg"
    refute css =~ "a\\.png"
  end
end
