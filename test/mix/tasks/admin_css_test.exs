# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.AdminCssTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir

  alias Mix.Tasks.AdminCss

  defp write!(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp build(root) do
    input = Path.join(root, "in.css")
    output = Path.join(root, "out.css")
    File.write!(input, AdminCss.admin_input(root))

    assert 0 =
             Tailwind.install_and_run(:mishka_cms_core_css, [
               "--input=#{input}",
               "--output=#{output}"
             ])

    File.read!(output)
  end

  test "a class a source only quotes in a comment gets no rule, a class it renders still does", %{
    tmp_dir: root
  } do
    write!(root, "lib/screen.ex", ~S|def render, do: ~s(<div class="bg-red-500 p-4"></div>)|)

    write!(
      root,
      "lib/mishka_cms_core/runtime/authoring/tree/styles.ex",
      "# `bg-[url(/hero.jpg)]` is read back as a background and `bg-red-700` is not a class\n"
    )

    write!(
      root,
      "__extensions/mishka_cms_builder/lib/mishka_cms_builder/classes.ex",
      "# an arbitrary value carries brackets and parens, `bg-[url('/a.png')]`\n"
    )

    css = build(root)

    assert css =~ "bg-red-500"
    refute css =~ "hero"
    refute css =~ "a\\.png"
    refute css =~ "bg-red-700"
  end
end
