# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.HeadCodesTest do
  @moduledoc """
  What a site's head code may put in a public page's head: only head tags, with no inline handler,
  every script carrying the response's nonce, and nothing that can close its own element.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaCmsCore.Runtime.HeadCodes

  @moduletag :unit

  @plausible ~S"""
  <script defer data-domain="mishka.tools" src="https://plausible.io/js/script.js"></script>
  <script>window.plausible = window.plausible || function() { (window.plausible.q = window.plausible.q || []).push(arguments) }
  const later = () =>
    1;</script>
  """

  defp draw(items, nonce \\ "n0nce"),
    do: rendered_to_string(HeadCodes.tags(%{items: items, csp_nonce: nonce}))

  describe "parse/1" do
    test "keeps the Plausible snippet, its code as written" do
      assert {:ok, [loader, inline]} = HeadCodes.parse(@plausible)

      assert loader.tag == "script"
      assert {"src", "https://plausible.io/js/script.js"} in loader.attrs
      assert {"data-domain", "mishka.tools"} in loader.attrs
      assert inline.content =~ "const later = () =>\n  1;"
    end

    test "drops inline event handlers, nonces and http-equiv" do
      assert {:ok, [meta]} =
               HeadCodes.parse(
                 ~s|<meta name="google-site-verification" content="abc" onload="x()" ONERROR="y()" nonce="old" http-equiv="refresh">|
               )

      assert meta.attrs == [{"name", "google-site-verification"}, {"content", "abc"}]
    end

    test "drops every tag that is not a head tag" do
      assert {:ok, [%{tag: "link"}]} =
               HeadCodes.parse(
                 ~s(<div>x</div><style>a{}</style><iframe src="https://x.io"></iframe><link rel="preconnect" href="https://fonts.example">text)
               )
    end

    test "keeps only the meta and link tags of a noscript" do
      assert {:ok, [noscript]} =
               HeadCodes.parse(
                 ~s(<noscript><img src="https://x.io/p.gif"><meta name="a" content="b"></noscript>)
               )

      assert [%{tag: "meta"}] = noscript.content
    end

    test "drops an address that is not http(s) or a path on the site" do
      assert {:ok, [script]} =
               HeadCodes.parse(~s|<script src="javascript:alert(1)">ok()</script>|)

      assert script.attrs == []
      assert HeadCodes.parse(~s(<link rel="x" href="//evil.example/a.css">)) == :error
      assert {:ok, [_link]} = HeadCodes.parse(~s(<link rel="manifest" href="/site.webmanifest">))
    end

    test "refuses code that keeps nothing, an unclosed script and anything too long" do
      assert HeadCodes.parse("<div>nothing</div>") == :error
      assert HeadCodes.parse("") == :error
      assert HeadCodes.parse("<script>never closed") == :error

      assert HeadCodes.parse(
               ~s(<script src="https://x.io/a.js"></script>) <> String.duplicate(" ", 20_001)
             ) == :error

      assert HeadCodes.parse(nil) == :error
    end
  end

  describe "accept/1, for a plugin's items" do
    test "holds a plugin's items to the same rules" do
      assert [%{tag: "meta", attrs: [{"name", "a"}]}] =
               HeadCodes.accept([
                 %{tag: "meta", attrs: [{"name", "a"}, {"onclick", "x()"}], content: nil},
                 %{tag: "iframe", attrs: [{"src", "https://x.io"}], content: nil},
                 %{tag: "script", attrs: [], content: "  "},
                 "<script>raw</script>"
               ])
    end
  end

  describe "tags/1" do
    test "gives every script the response's nonce and marks every tag with its key" do
      {:ok, items} = HeadCodes.parse(@plausible)
      html = draw(Enum.map(items, &Map.put(&1, :key, "entry-1")))

      assert length(Regex.scan(~r/<script[^>]*nonce="n0nce"/, html)) == 2
      assert length(Regex.scan(~r/data-mishka-head="entry-1"/, html)) == 2
    end

    test "never lets a script's code close its element" do
      html =
        draw([
          %{
            tag: "script",
            attrs: [],
            content: ~s|a("</script><script>alert(1)</script>")|,
            key: "k"
          }
        ])

      assert length(Regex.scan(~r/<\/script>/i, html)) == 1
      assert html =~ ~S|<\/script>|
    end

    test "escapes attribute values" do
      html =
        draw([
          %{tag: "meta", attrs: [{"content", ~s("><script>x</script>)}], content: nil, key: "k"}
        ])

      refute html =~ "<script>x"
    end
  end

  describe "applies?/4" do
    test "places an entry by its scope, on the address or the page's pattern" do
      assert HeadCodes.applies?(:all, [], "/a", "/a")
      assert HeadCodes.applies?(:only, ["/pricing"], "/pricing", "/pricing")
      assert HeadCodes.applies?(:only, ["/blog/:slug"], "/blog/hello", "/blog/:slug")
      refute HeadCodes.applies?(:only, ["/pricing"], "/about", "/about")
      refute HeadCodes.applies?(:except, ["/pricing"], "/pricing", "/pricing")
      assert HeadCodes.applies?(:except, ["/pricing"], "/about", "/about")
    end
  end

  test "an origin is https and a host, with nothing after it" do
    assert HeadCodes.origins?(["https://plausible.io", "https://stats.example.com:8443"])
    refute HeadCodes.origins?(["http://plausible.io"])
    refute HeadCodes.origins?(["https://plausible.io/api/event"])
    refute HeadCodes.origins?(["https://*.example.com"])
  end
end
