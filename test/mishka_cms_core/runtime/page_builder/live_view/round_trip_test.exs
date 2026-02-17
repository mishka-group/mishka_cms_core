defmodule MishkaCmsCore.Runtime.PageBuilder.LiveView.RoundTripTest do
  @moduledoc """
  The builder round-trip: a page's HEEx is turned into AST-JSON by `JsonEncoder`
  (for the visual editor) and back into HEEx by `HeexDecoder` (to persist an edit).
  Editing in the editor must never corrupt the template, for every node kind a page
  can contain — plain HTML, Phoenix components, custom runtime components, EEx
  expressions, EEx blocks (`if`/`for`), and comments.

  Two properties are asserted per node kind:

    * **stability** — `decode(encode(heex))` is a fixed point. The first pass may
      re-indent via `Phoenix.LiveView.HTMLFormatter`; a second pass must produce the
      identical template. A dropped or mangled node breaks this.
    * **fidelity** — the decoded template still contains each tag / attribute / text
      it started with, so "stable" can't mean "stably empty".
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.LiveView.{HeexDecoder, JsonEncoder}

  defp render_fun, do: fn heex -> LiveViewCompiler.render_template(heex, %{}) end

  defp roundtrip(heex) do
    {:ok, ast} = JsonEncoder.encode(heex, render_fun())
    HeexDecoder.decode(ast)
  end

  defp assert_roundtrip(heex, must_contain) do
    once = roundtrip(heex)
    twice = roundtrip(once)

    assert once == twice, """
    round-trip is not stable — editing and saving twice drifts the template.

    after one pass:
    #{once}
    after two passes:
    #{twice}
    """

    for fragment <- must_contain do
      assert once =~ fragment, """
      round-trip dropped #{inspect(fragment)} from the template.

      decoded:
      #{once}
      """
    end

    once
  end

  describe "plain html" do
    test "nested tags with a class and text" do
      assert_roundtrip(~s|<div class="a"><span>hi there</span></div>|, [
        "<div",
        ~s|class="a"|,
        "<span",
        "hi there",
        "</span>",
        "</div>"
      ])
    end

    test "multiple attributes" do
      assert_roundtrip(~s|<a href="/x" class="link" id="go">Go</a>|, [
        "<a",
        ~s|href="/x"|,
        ~s|class="link"|,
        ~s|id="go"|,
        "Go"
      ])
    end

    test "self-closing void element" do
      assert_roundtrip(~s|<div><img src="/a.png" alt="pic" /></div>|, [
        "<img",
        ~s|src="/a.png"|,
        ~s|alt="pic"|
      ])
    end

    # A COMPUTED CLASS IS STILL A CLASS. Overrides are compiled into `class` on the way out, and the
    # code that did it only knew how to read a literal — so a node whose class the component works
    # out at render time had the attribute DELETED on its first save, silently, and came back with
    # no styling at all.
    test "a class that is an expression survives" do
      assert_roundtrip(~s|<div class={@variant}>x</div>|, ["class={@variant}"])

      assert_roundtrip(~s|<div class={["a", @on && "b"]}>x</div>|, [~s|class={["a", @on && "b"]}|])
    end

    test "boolean/valueless attribute" do
      assert_roundtrip(~s|<button disabled type="button">x</button>|, [
        "<button",
        "disabled",
        ~s|type="button"|
      ])
    end
  end

  describe "phoenix components" do
    test "a .link component with attrs and text" do
      assert_roundtrip(~s|<.link navigate="/about" class="hover:underline">About</.link>|, [
        "<.link",
        ~s|navigate="/about"|,
        ~s|class="hover:underline"|,
        "About",
        "</.link>"
      ])
    end
  end

  describe "custom runtime components" do
    test "a self-closing .component reference" do
      assert_roundtrip(~s|<.component component_name="global-footer" site="Global" />|, [
        "<.component",
        ~s|component_name="global-footer"|,
        ~s|site="Global"|
      ])
    end

    test "a .component with body content" do
      assert_roundtrip(
        ~s|<.component component_name="chelekom-card" site="Global"><h2>Title</h2></.component>|,
        ["<.component", ~s|component_name="chelekom-card"|, "<h2", "Title", "</.component>"]
      )
    end
  end

  describe "eex" do
    test "an inline <%= %> expression normalizes to the curly form" do
      # Phoenix's HTMLFormatter rewrites `<%= @name %>` in a tag body to `{@name}`;
      # both are valid HEEx and the round-trip stays stable on the curly form.
      out = assert_roundtrip(~s|<span><%= @name %></span>|, ["<span", "@name", "</span>"])
      assert out =~ "{@name}"
    end

    test "the curly interpolation form is preserved" do
      assert_roundtrip(~s|<span>{@name}</span>|, ["<span", "{@name}", "</span>"])
    end

    test "an if block" do
      assert_roundtrip(~s|<%= if true do %><b>yes</b><% end %>|, [
        "<%= if true do %>",
        "<b",
        "yes",
        "<% end %>"
      ])
    end

    test "a for block with an inner expression" do
      # `<%= x %>` inside the <li> body normalizes to the curly form `{x}`, same as
      # any body expression; the loop header and structure are preserved.
      assert_roundtrip(~s|<ul><%= for x <- [1, 2, 3] do %><li><%= x %></li><% end %></ul>|, [
        "<ul",
        "<%= for x <- [1, 2, 3] do %>",
        "<li",
        "{x}",
        "<% end %>"
      ])
    end
  end

  describe "comments" do
    test "an html comment" do
      assert_roundtrip(~s|<div><!-- a note --></div>|, ["<!-- a note -->"])
    end

    test "an eex comment" do
      assert_roundtrip(~s|<div><%!-- a note --%></div>|, ["<%!-- a note --%>"])
    end
  end

  describe "a full page (mixed node kinds)" do
    test "header nav with links, main with text, and a custom component footer" do
      heex = """
      <div class="min-h-screen">
        <header class="bg-indigo-600">
          <nav class="flex gap-6">
            <.link navigate="/" class="hover:underline">Home</.link>
            <.link navigate="/about" class="hover:underline">About</.link>
          </nav>
        </header>
        <main class="mx-auto">
          <h2 class="text-3xl">Contact Us</h2>
          <p class="text-gray-700">Reach out to us.</p>
        </main>
        <.component component_name="global-footer" site="Global" />
      </div>
      """

      assert_roundtrip(heex, [
        "<div",
        "<header",
        "<nav",
        "<.link",
        ~s|navigate="/"|,
        ~s|navigate="/about"|,
        "Home",
        "About",
        "<main",
        "Contact Us",
        "Reach out to us.",
        "<.component",
        ~s|component_name="global-footer"|
      ])
    end
  end

  describe "edge & bad-path cases" do
    test "an empty template does not crash and decodes to blank" do
      assert String.trim(roundtrip("")) == ""
    end

    test "an unknown/arbitrary component is preserved verbatim" do
      assert_roundtrip(~s|<.totally_made_up foo="bar">hi</.totally_made_up>|, [
        "<.totally_made_up",
        ~s|foo="bar"|,
        "hi"
      ])
    end

    test "an arbitrary custom html tag (in no hardcoded list) round-trips" do
      assert_roundtrip(~s|<my-widget data-x="1"><inner-thing>z</inner-thing></my-widget>|, [
        "<my-widget",
        ~s|data-x="1"|,
        "<inner-thing",
        "z"
      ])
    end

    test "an attribute with an expression value {…} keeps the braces" do
      assert_roundtrip(~s|<div class={@theme}>x</div>|, ["<div", "class={@theme}", "x"])
    end

    test "html entities in text and attributes survive" do
      assert_roundtrip(~s|<p title="a &amp; b">1 &lt; 2 &amp; 3</p>|, ["<p", "&amp;", "&lt;"])
    end

    test "a deeply nested structure round-trips" do
      assert_roundtrip(~s|<a><b><c><d><e>deep</e></d></c></b></a>|, [
        "<a",
        "<b",
        "<c",
        "<d",
        "<e",
        "deep"
      ])
    end

    test "multiple root nodes round-trip" do
      assert_roundtrip(~s|<h1>One</h1><p>Two</p><.link navigate="/">Three</.link>|, [
        "<h1",
        "One",
        "<p",
        "Two",
        "<.link",
        "Three"
      ])
    end

    test "a comment-only template round-trips" do
      assert_roundtrip(~s|<%!-- just a comment --%>|, ["<%!-- just a comment --%>"])
    end
  end

  describe "rendering an AST subtree to HTML (the component re-render endpoint)" do
    test "a container with children renders to HTML that contains them" do
      ast = [
        %{
          "tag" => "div",
          "attrs" => %{"class" => "card"},
          "content" => [
            %{"tag" => "h2", "attrs" => %{}, "content" => ["Title"]},
            %{"tag" => "p", "attrs" => %{}, "content" => ["Body text"]}
          ]
        }
      ]

      html = LiveViewCompiler.render_template(HeexDecoder.decode(ast), %{})

      assert is_binary(html)
      assert html =~ ~s|class="card"|
      assert html =~ "Title"
      assert html =~ "Body text"
    end

    test "a child added to a container appears in the re-rendered HTML" do
      ast = [
        %{
          "tag" => "section",
          "attrs" => %{},
          "content" => [
            %{"tag" => "span", "attrs" => %{"class" => "chip"}, "content" => ["new child"]}
          ]
        }
      ]

      html = LiveViewCompiler.render_template(HeexDecoder.decode(ast), %{})

      assert html =~ "new child"
      assert html =~ ~s|class="chip"|
    end

    test "an unrenderable component degrades to a non-binary result (endpoint returns nil)" do
      ast = [%{"tag" => ".cp", "attrs" => %{}, "content" => ["x"]}]

      refute is_binary(LiveViewCompiler.render_template(HeexDecoder.decode(ast), %{}))
    end
  end

  describe "LV1.2 tokenizer surface — preserve mode, slots, remote components" do
    test "a <pre> block keeps its interior whitespace across round-trips" do
      assert_roundtrip(~s|<pre>keep   the   spaces</pre>|, ["<pre", "keep   the   spaces"])
    end

    test "a phx-no-format block preserves its inner spacing" do
      assert_roundtrip(~s|<div phx-no-format>a   b   c</div>|, [
        "<div",
        "phx-no-format",
        "a   b   c"
      ])
    end

    test "a named slot with an attribute round-trips" do
      assert_roundtrip(
        ~s|<.table rows={@r}><:col label="Name">{@u}</:col></.table>|,
        ["<.table", "<:col", ~s|label="Name"|, "</:col>", "</.table>"]
      )
    end

    test "a remote (dotted, capitalized) component round-trips" do
      assert_roundtrip(
        ~s|<MyMod.button class="x">Go</MyMod.button>|,
        ["<MyMod.button", ~s|class="x"|, "Go", "</MyMod.button>"]
      )
    end
  end
end
