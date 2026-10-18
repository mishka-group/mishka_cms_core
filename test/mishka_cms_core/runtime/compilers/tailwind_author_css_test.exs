# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.TailwindAuthorCssTest do
  @moduledoc """
  What an author's stylesheet may ask of the Tailwind binary that builds the page's CSS.

  A stylesheet row is pasted into the file Tailwind reads, and Tailwind follows what it names:
  `@import` copies a local file into the public CSS, `@source` scans a local file for class names,
  and `@plugin` runs a local JavaScript file. `TailwindCompiler.author_css/1` leaves those out of
  every row before it is pasted, and keeps the rest.

  The second half runs the binary: a row that points `@source` at a file on this machine, compiled
  for a site, must not pull that file's classes into the CSS the site serves.

  `async: false` — the compile writes under the shared temp folder and reads `SiteState`.
  """
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Stylesheet

  @moduletag :integration

  describe "author_css/1" do
    test "leaves out the at-rules that read a file or run code, and names them" do
      css = """
      @import "../private.css";
      @import url("./local.css") layer(base);
      @source "../notes.txt";
      @source not "../other";
      @plugin "../plugin.js";
      @plugin "./p.js" { option: 1 }
      @config "../tailwind.config.js";
      @reference "./app.css";
      .card { color: red }
      """

      assert {cleaned, removed} = TailwindCompiler.author_css(css)

      assert removed ==
               ~w(@import @import @source @source @plugin @plugin @config @reference)

      refute cleaned =~ "private.css"
      refute cleaned =~ "plugin.js"
      refute cleaned =~ "notes.txt"
      assert cleaned =~ ".card { color: red }"
    end

    test "keeps what only names class names or a remote stylesheet" do
      css = """
      @import url("https://fonts.googleapis.com/css2?family=Inter");
      @import "https://fonts.googleapis.com/css2?family=Roboto";
      @import url(http://fonts.example.test/a.css);
      @source inline("underline");
      @source not inline("flex");
      """

      assert TailwindCompiler.author_css(css) == {css, []}
    end

    test "keeps the rest of Tailwind's own language as it was written" do
      css = """
      @theme { --color-brand: oklch(0.6 0.2 250); }
      @layer components { .btn { @apply px-4 py-2; } }
      @custom-variant dark (&:where(.dark, .dark *));
      @utility tab-4 { tab-size: 4; }
      @media (min-width: 40rem) { .a { color: blue } }
      @keyframes spin { to { transform: rotate(360deg) } }
      """

      assert TailwindCompiler.author_css(css) == {css, []}
    end

    test "reads the name in any case, and refuses one written with an escape" do
      assert {_css, ["@import"]} = TailwindCompiler.author_css(~s(@IMPORT "../x.css";))
      assert {_css, ["@plugin"]} = TailwindCompiler.author_css(~s(@Plugin "../x.js";))
      assert {cleaned, [escaped]} = TailwindCompiler.author_css(~s(@\\69mport "../x.css";))
      assert String.starts_with?(escaped, "@")
      refute cleaned =~ "x.css"
    end

    test "leaves out a rule with no closing semicolon at the end of the text" do
      assert {cleaned, ["@import"]} =
               TailwindCompiler.author_css(~s(.a { color: red }\n@import "../x.css"))

      refute cleaned =~ "x.css"
      assert cleaned =~ ".a { color: red }"
    end

    test "is the identity on text with no at-rule" do
      assert TailwindCompiler.author_css("") == {"", []}
      assert TailwindCompiler.author_css(".a { color: red }") == {".a { color: red }", []}
    end
  end

  describe "a stylesheet that names a local file" do
    setup do
      TailwindCompiler.ensure_installed()

      dir = Path.join(System.tmp_dir!(), "author_css_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      name = "author-css-#{System.unique_integer([:positive])}"
      site = create_site!(name: name, host: "#{name}.test", active: true)

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: true
        })

      on_exit(fn -> SiteState.delete(site.id) end)

      %{dir: dir, site: site}
    end

    defp write_stylesheet!(site, content) do
      Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{name: "own-rules", content: content, kind: :custom, site_id: site.id},
        authorize?: false
      )
      |> Ash.create!()
    end

    defp compile(site) do
      log =
        capture_log(fn ->
          capture_io(fn -> send(self(), {:compiled, TailwindCompiler.compile(site.name)}) end)
        end)

      assert_received {:compiled, result}
      {result, log}
    end

    # A class only the file below names. Scanned, Tailwind writes a rule for it.
    @class "p-[37px]"

    test "does not scan the file for classes, and says what it left out", %{dir: dir, site: site} do
      notes = Path.join(dir, "notes.txt")
      File.write!(notes, ~s(<div class="#{@class}">x</div>))

      write_stylesheet!(site, ~s(@source "#{notes}";\n.visible { color: red }))

      {result, log} = compile(site)

      assert {:ok, css} = result
      assert css =~ ".visible"
      refute css =~ "37px", "the file named by @source was scanned"
      assert log =~ "left out @source"
    end

    test "scans it when the rule is written by the compiler itself", %{dir: dir, site: site} do
      notes = Path.join(dir, "notes.txt")
      File.write!(notes, ~s(<div class="#{@class}">x</div>))

      write_stylesheet!(site, "@source inline(\"#{@class}\");\n.visible { color: red }")

      assert {{:ok, css}, _log} = compile(site)
      assert css =~ "37px", "an inline source, which lists class names only, is kept"
    end
  end

  describe "verify_css/2" do
    test "does not read the file a rule names" do
      TailwindCompiler.ensure_installed()
      site = create_site!()

      assert TailwindCompiler.verify_css(
               ~s(@import "/no/such/file.css";\n.a { color: red }),
               site.id
             ) ==
               :ok

      assert TailwindCompiler.verify_css(
               ~s(@plugin "/no/such/plugin.js";\n.a { color: red }),
               site.id
             ) ==
               :ok
    end
  end
end
