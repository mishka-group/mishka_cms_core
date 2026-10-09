defmodule MishkaCmsCore.Runtime.ContentPreviewScrubberTest do
  @moduledoc """
  What a content editor preview keeps of what a component drew, and what it takes out
  (`ContentPreviewScrubber`). The preview drawn through it is `MishkaCmsCoreWeb.Test.ContentEditorTest`.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.ContentPreviewScrubber

  @moduletag :unit

  defp kept(html), do: html |> ContentPreviewScrubber.sanitize() |> LazyHTML.from_fragment()

  test "keeps every element a component draws, with its classes and attributes" do
    html =
      ~S|<form class="f"><fieldset class="g"><button type="submit" class="btn bg-primary" aria-label="Go" data-x="1" disabled>Go</button><input type="email" name="e" placeholder="you@x.test" required><select name="s"><option value="a" selected>A</option></select><textarea rows="2">t</textarea></fieldset></form>| <>
        ~S|<figure class="fig"><svg viewBox="0 0 24 24" class="size-4"><path d="M0 0h24"/></svg><figcaption class="cap">C</figcaption></figure>| <>
        ~S|<dl class="dl"><dt class="dt">T</dt><dd class="dd">D</dd></dl><abbr class="ab" title="x">A</abbr><cite class="ci">C</cite><dialog class="dg">D</dialog><p style="width: 40%">w</p>|

    doc = kept(html)

    for selector <- [
          "form.f fieldset.g button.btn.bg-primary[type=submit][aria-label=Go][data-x='1'][disabled]",
          "input[type=email][name=e][placeholder='you@x.test'][required]",
          "select option[value=a][selected]",
          "textarea[rows='2']",
          "figure.fig svg.size-4 path",
          "figure.fig figcaption.cap",
          "dl.dl dt.dt",
          "dl.dl dd.dd",
          "abbr.ab[title=x]",
          "cite.ci",
          "dialog.dg",
          "p[style]"
        ] do
      assert doc |> LazyHTML.query(selector) |> Enum.count() == 1, selector
    end
  end

  test "takes out what runs, what loads another document, and what LiveView would bind" do
    html =
      ~S|<p>a</p><script>alert(1)</script><style>p{}</style><iframe src="https://x.test"></iframe><object data="x"></object><embed src="x"><base href="https://x.test/"><meta http-equiv="refresh" content="0"><link rel="stylesheet" href="https://x.test/a.css"><template><b>t</b></template><!-- note -->| <>
        ~S|<button onclick="alert(1)" phx-click="boom" phx-value-id="1" class="b">B</button><img src="x" onerror="alert(1)">|

    out = ContentPreviewScrubber.sanitize(html)
    doc = LazyHTML.from_fragment(out)

    for selector <- ~w(script style iframe object embed base meta link template),
        do: assert(doc |> LazyHTML.query(selector) |> Enum.empty?(), selector)

    assert doc |> LazyHTML.query("button.b") |> Enum.count() == 1
    refute out =~ "onclick"
    refute out =~ "onerror"
    refute out =~ "phx-"
    refute out =~ "note"
  end

  test "keeps an address to the web, mail, a phone or the page itself, and no other" do
    for href <- ~w(https://x.test http://x.test mailto:a@x.test tel:+1 /path ?q=1 #top page) do
      assert kept(~s(<a href="#{href}">x</a>)) |> LazyHTML.query("a[href]") |> Enum.count() == 1,
             href
    end

    for href <- [
          "javascript:alert(1)",
          "JavaScript:alert(1)",
          "java\tscript:alert(1)",
          " vbscript:x",
          "data:text/html,x"
        ] do
      assert kept(~s(<a href="#{href}">x</a>)) |> LazyHTML.query("a[href]") |> Enum.empty?(),
             inspect(href)
    end

    assert kept(~s(<img src="data:image/png;base64,AA">))
           |> LazyHTML.query("img[src]")
           |> Enum.empty?()

    assert kept(~s(<img srcset="/a.png 1x, https://x.test/b.png 2x">))
           |> LazyHTML.query("img[srcset]")
           |> Enum.count() == 1

    assert kept(~s(<img srcset="/a.png 1x, javascript:x 2x">))
           |> LazyHTML.query("img[srcset]")
           |> Enum.empty?()
  end
end
