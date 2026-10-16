# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PreviewHooksTest do
  @moduledoc """
  A hook named for one site, previewed under another.

  A runtime hook is registered in the browser under its site's prefix, because two sites may both
  have a `clipboard` and they are different code. So a template naming `LocalhostClipboard` works on
  the localhost site and nowhere else — on a PUBLISHED page correctly so.

  A draft preview is the one place that answer is useless. It is an editing tool reached by a token,
  and it exists to show whether the page works; a master opening one page under three sites gets a
  button that draws and does nothing on two of them, with `unknown hook found for …` in the console
  and no other sign of it.

  What must NOT happen is another site's code being served to make that true, so the rewrite only
  ever points a name at a hook the previewed site already has.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.PreviewHooks

  @moduletag :unit

  setup do
    site = create_site!(name: "elsewhere", host: "elsewhere.test", active: true)
    other = create_site!(name: "localhost", host: "localhost", active: true)

    hook!(site, "clipboard")
    hook!(other, "clipboard")
    hook!(nil, "console-logger")

    %{site: site, other: other}
  end

  defp hook!(site, name) do
    MishkaCmsCore.Runtime.JsHook
    |> Ash.create!(
      %{name: name, content: "export default {mounted(){}}", site_id: site && site.id},
      action: :master_create,
      authorize?: false,
      context: %{defer_runtime: true}
    )
  end

  describe "a name this site cannot register" do
    test "is pointed at this site's hook of the same base", %{site: site} do
      html = ~s(<button id="b" phx-hook="LocalhostClipboard">c</button>)

      assert PreviewHooks.resolve(html, site) =~ ~s(phx-hook="ElsewhereClipboard")
      refute PreviewHooks.resolve(html, site) =~ "LocalhostClipboard"
    end

    # ONLY THE NAME CHANGES. The preview's stylesheet is compiled from the stored template, so a
    # component whose classes came back re-ordered and marked `!` was drawn with no rule at all.
    test "and every other byte of the template is left as written", %{site: site} do
      html = """
      <.link navigate="/x" id="cta" class="mt-[10px] flex h-11 border-dashed text-[#4f4bcc]">
        <button id="b" phx-hook="LocalhostClipboard">c</button>
      </.link>
      <p class="p-4">Same <b>text</b></p>
      """

      assert PreviewHooks.resolve(html, site) ==
               String.replace(html, "LocalhostClipboard", "ElsewhereClipboard")
    end

    test "a template with nothing to change comes back as it was", %{site: site} do
      html =
        ~s(<.link navigate="/x" class="flex border-dashed" phx-hook="ElsewhereClipboard">y</.link>)

      assert PreviewHooks.resolve(html, site) == html
    end

    # NOTHING IS INVENTED. A base this site does not have is left exactly as written, so the preview
    # shows what production will: a hook nothing registers.
    test "and a base this site does not have is left alone", %{site: site} do
      html = ~s(<div id="d" phx-hook="LocalhostSomethingElse">x</div>)

      assert PreviewHooks.resolve(html, site) =~ ~s(phx-hook="LocalhostSomethingElse")
    end

    test "a name this site DOES register is untouched", %{site: site} do
      html = ~s(<button id="b" phx-hook="ElsewhereClipboard">c</button>)

      assert PreviewHooks.resolve(html, site) =~ ~s(phx-hook="ElsewhereClipboard")
    end

    # A global already carries the name every site uses, so it is not the case this exists for.
    test "and a global is untouched", %{site: site} do
      html = ~s(<div id="d" phx-hook="GlobalConsoleLogger">x</div>)

      assert PreviewHooks.resolve(html, site) =~ ~s(phx-hook="GlobalConsoleLogger")
    end
  end

  describe "what it leaves alone" do
    test "markup with no hooks comes back unchanged in meaning", %{site: site} do
      html = ~s(<section class="p-4"><h1>Hi</h1></section>)

      resolved = PreviewHooks.resolve(html, site)

      assert resolved =~ "<h1>"
      assert resolved =~ "p-4"
    end

    test "no site, nothing to resolve against" do
      html = ~s(<button phx-hook="LocalhostClipboard">c</button>)

      assert PreviewHooks.resolve(html, nil) == html
    end

    test "and nothing at all is not a crash", %{site: site} do
      assert PreviewHooks.resolve(nil, site) == nil
    end

    # A PREVIEW THAT RENDERS THE AUTHOR'S MARKUP IS WORTH MORE THAN ONE THAT REFUSES over a hook
    # name, so anything the tree cannot read comes back as it went in.
    test "markup the tree cannot parse is returned as written", %{site: site} do
      html = ~s(<div><%= if @x do %>)

      assert PreviewHooks.resolve(html, site) == html
    end
  end

  # THE ATTRIBUTE IS AN ATTRIBUTE, not a piece of text. Searching the string would rewrite the name
  # inside a paragraph explaining it.
  test "a hook name written as prose is not a hook", %{site: site} do
    html = ~s(<p>Use LocalhostClipboard for that.</p>)

    assert PreviewHooks.resolve(html, site) =~ "Use LocalhostClipboard for that."
  end
end
