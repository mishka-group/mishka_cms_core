defmodule MishkaCmsCore.Runtime.ContentComponentsTest do
  @moduledoc """
  The marker an author writes into content, read back: where one is found and where it is left as
  text, what its attributes become for the component it names, and the marker the editor writes.

  Drawing the components a marker names is `MishkaCmsCore.Runtime.ContentComponentsRenderTest`.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.ContentComponents

  @moduletag :unit

  defp markers(html), do: for({:component, marker} <- ContentComponents.parse(html), do: marker)
  defp texts(html), do: for({:html, text} <- ContentComponents.parse(html), do: text)

  describe "parse/1 — finding markers" do
    test "content with no marker is one piece of HTML" do
      html = "<p>Nothing <b>to</b> see [[ here ]]</p>"

      assert ContentComponents.parse(html) == [{:html, html}]
    end

    test "an opening and a closing marker hold the HTML between them" do
      html =
        ~s(<p>Before</p>[[component chelekom-alert color="info" title="Heads up"]]Text, <b>with</b> HTML[[/component]]<p>After</p>)

      assert ContentComponents.parse(html) == [
               {:html, "<p>Before</p>"},
               {:component,
                %{
                  name: "chelekom-alert",
                  attrs: %{"color" => "info", "title" => "Heads up"},
                  inner: "Text, <b>with</b> HTML",
                  index: 0
                }},
               {:html, "<p>After</p>"}
             ]
    end

    test "a self-closing marker holds nothing" do
      assert [%{name: "chelekom-badge", attrs: %{"label" => "New"}, inner: nil}] =
               markers(~s([[component chelekom-badge label="New" /]]))
    end

    test "counts the markers it finds, in order" do
      assert [%{name: "one", index: 0}, %{name: "two", index: 1}, %{name: "three", index: 2}] =
               markers(
                 "[[component one /]]<p>x</p>[[component two]]y[[/component]][[component three /]]"
               )
    end

    test "an opening marker closed by nothing is not a block" do
      assert markers("[[component lonely]] no end") == []
    end
  end

  describe "parse/1 — attributes" do
    test "takes double, single and bare values, and a bare key as true" do
      assert [%{attrs: attrs}] =
               markers(~s([[component a one="1" two='2' three=3 four /]]))

      assert attrs == %{"one" => "1", "two" => "2", "three" => "3", "four" => true}
    end

    # THE SANITIZER DECODES QUOTE ENTITIES, other editors write them. Either way the marker reads.
    test "takes quotes written as entities" do
      assert [%{attrs: attrs}] =
               markers(
                 ~s([[component a title=&quot;say "hi"&quot; b=&#39;x&#39; c=&#34;y&#34; d=&#x27;z&#x27; /]])
               )

      assert attrs == %{"title" => ~s(say "hi"), "b" => "x", "c" => "y", "d" => "z"}
    end

    test "decodes the entities in a value" do
      assert [%{attrs: %{"t" => "a & b <c> ' ©"}}] =
               markers(~s([[component a t="a &amp; b &lt;c&gt; &#x27; &#169;" /]]))
    end

    test "keeps a value's own brackets, and reads non-breaking spaces as spaces" do
      assert [%{attrs: %{"t" => "a]]b", "u" => "1"}}] =
               markers(~s([[component a t="a]]b"\u00A0u="1"&nbsp;/]]))
    end

    test "an attribute that does not close leaves the marker as text" do
      html = ~s([[component a t="never closes /]])

      assert ContentComponents.parse(html) == [{:html, html}]
    end
  end

  describe "parse/1 — what stays text" do
    test "a marker inside <pre> or <code> is left for the page to show" do
      html = ~s(<pre><code>[[component x a="1" /]]</code></pre><code>[[component y /]]</code>)

      assert ContentComponents.parse(html) == [{:html, html}]
    end

    test "and the one after it is still found" do
      assert [%{name: "after"}] =
               markers(~s(<pre>[[component before /]]</pre>[[component after /]]))
    end

    test "a marker inside a tag's attribute is not touched" do
      html = ~s(<img alt="[[component x /]]" src="a.png">)

      assert ContentComponents.parse(html) == [{:html, html}]
    end

    # MARKERS DO NOT NEST. The outer opening marker would hold another marker, so it is text; the
    # inner block is drawn; the closing marker left over is text.
    test "a nested marker leaves the outer one as text" do
      html = "[[component outer]] x [[component inner]]y[[/component]] z [[/component]]"

      assert [%{name: "inner", inner: "y"}] = markers(html)
      assert texts(html) == ["[[component outer]] x ", " z [[/component]]"]
    end

    test "a closing marker nothing opened is text" do
      assert ContentComponents.parse("a [[/component]] b") == [{:html, "a [[/component]] b"}]
    end

    test "something that only looks like a marker is text" do
      html = ~s([[componentx /]] [[component  /]] [[component -?bad /]] [[component a b]])

      assert markers(html) == []
    end
  end

  # A BLOCK INSIDE A `<p>` IS HTML A BROWSER TAKES APART, and an editor wraps every line it is given
  # in one. A paragraph that holds a marker and nothing else is the marker's.
  describe "parse/1 — a paragraph holding only a marker" do
    test "is drawn as the component alone" do
      assert [{:component, %{name: "a"}}] = ContentComponents.parse("<p>[[component a /]]</p>")

      assert [{:html, "<p>x</p>"}, {:component, %{name: "a", inner: "in <b>b</b>"}}] =
               ContentComponents.parse(
                 ~s(<p>x</p><p class="lead"> &nbsp;[[component a]]in <b>b</b>[[/component]]  </P >)
               )
    end

    test "keeps a paragraph the marker shares with text" do
      assert texts("<p>Before [[component a /]]</p>") == ["<p>Before ", "</p>"]
      assert texts("<p>[[component a /]] after</p>") == ["<p>", " after</p>"]
    end

    test "keeps a paragraph two markers share" do
      assert texts("<p>[[component a /]][[component b /]]</p>") == ["<p>", "</p>"]
    end

    test "leaves a <pre> around a marker alone" do
      html = "<pre>[[component a /]]</pre>"

      assert ContentComponents.parse(html) == [{:html, html}]
    end
  end

  describe "names/1 — what a resource stores beside its content" do
    test "each name once, in the order it first appears" do
      html =
        "[[component b /]]<p>[[component a]]x[[/component]]</p>[[component b /]]<code>[[component c /]]</code>"

      assert ContentComponents.names(html) == ["b", "a"]
    end

    test "nothing for content with no marker, or none at all" do
      assert ContentComponents.names("<p>plain</p>") == []
      assert ContentComponents.names(nil) == []
    end
  end

  describe "cast/2 — the attributes a component takes" do
    @declared [
      %{name: "title", type: "string", opts: %{default: nil}},
      %{name: "count", type: "integer"},
      %{name: "ratio", type: "float"},
      %{name: "open", type: "boolean"},
      %{name: "size", type: "string", opts: %{"values" => ["small", "large"]}},
      %{name: "kind", type: "atom", opts: %{values: ["info", "danger"]}},
      %{name: "free_atom", type: "atom"},
      %{name: "items", type: "list"},
      %{name: "params", type: "map"},
      %{name: "slug", type: "any"},
      %{name: "id", type: "string"},
      %{name: "current_user", type: "any"},
      %{name: "rest", type: "global"}
    ]

    test "casts each to its declared type" do
      given = %{
        "title" => "Hi",
        "count" => "3",
        "ratio" => "1.5",
        "open" => true,
        "size" => "large",
        "kind" => "danger",
        "slug" => "a-post"
      }

      assert ContentComponents.cast(@declared, given) == %{
               title: "Hi",
               count: 3,
               ratio: 1.5,
               open: true,
               size: "large",
               kind: :danger,
               slug: "a-post"
             }
    end

    test "reads a written boolean" do
      assert ContentComponents.cast(@declared, %{"open" => "false"}) == %{open: false}
      assert ContentComponents.cast(@declared, %{"open" => "yes"}) == %{}
    end

    test "drops what does not cast" do
      given = %{"count" => "three", "ratio" => "1.5x", "size" => "huge", "kind" => "boom"}

      assert ContentComponents.cast(@declared, given) == %{}
    end

    test "never takes an atom the component did not list" do
      assert ContentComponents.cast(@declared, %{"free_atom" => "anything"}) == %{}
    end

    test "drops what the component never declared, and what a marker cannot write" do
      given = %{
        "phx-click" => "boom",
        "onclick" => "x",
        "items" => "a,b",
        "params" => "{}",
        "id" => "mine",
        "current_user" => "admin",
        "rest" => "x",
        "title" => true
      }

      assert ContentComponents.cast(@declared, given) == %{}
    end
  end

  describe "marker/3 — what Insert writes" do
    test "writes the attributes in name order and leaves blanks out" do
      assert ContentComponents.marker(
               "chelekom-alert",
               %{"title" => "Heads up", "size" => ""},
               nil
             ) ==
               ~s([[component chelekom-alert title="Heads up" /]])

      assert ContentComponents.marker("a", %{"z" => "1", "b" => "2"}, nil) ==
               ~s([[component a b="2" z="1" /]])
    end

    test "writes inner content between an opening and a closing marker" do
      assert ContentComponents.marker("a", %{}, "Read <b>this</b>") ==
               "[[component a]]Read <b>this</b>[[/component]]"

      assert ContentComponents.marker("a", %{}, "   ") == "[[component a /]]"
    end

    test "picks the quote a value does not hold" do
      assert ContentComponents.marker("a", %{"t" => ~s(say "hi")}, nil) ==
               ~s([[component a t='say "hi"' /]])

      assert ContentComponents.marker("a", %{"t" => ~s(it's "both")}, nil) ==
               ~s([[component a t="it's 'both'" /]])
    end

    test "writes a value's markup as entities, so it is not read as a tag" do
      assert ContentComponents.marker("a", %{"t" => "x < y & z"}, nil) ==
               ~s([[component a t="x &lt; y &amp; z" /]])
    end

    test "reads back as what was written" do
      attrs = %{"title" => ~s(It's "quoted" & <fine>), "count" => "3", "open" => "true"}
      marker = ContentComponents.marker("chelekom-alert", attrs, "<p>inner</p>")

      assert [%{name: "chelekom-alert", attrs: read, inner: "<p>inner</p>"}] = markers(marker)
      assert read["count"] == "3"
      assert read["open"] == "true"
      assert read["title"] == ~s(It's 'quoted' & <fine>)
    end

    test "refuses what it could not read back" do
      assert ContentComponents.marker("bad name", %{}, nil) == nil
      assert ContentComponents.marker("a", %{"phx-click" => "boom"}, nil) == nil
      assert ContentComponents.marker("a", %{"bad key" => "x"}, nil) == nil
      assert ContentComponents.marker("a", "not attributes", nil) == nil
      assert ContentComponents.marker(nil, %{}, nil) == nil
    end

    test "leaves out a value that is not text" do
      assert ContentComponents.marker("a", %{"t" => %{"nested" => "x"}}, nil) ==
               "[[component a /]]"
    end
  end

  describe "append/2" do
    test "puts the marker on a line of its own" do
      assert ContentComponents.append(nil, "[[component a /]]") == "[[component a /]]"
      assert ContentComponents.append("", "[[component a /]]") == "[[component a /]]"

      assert ContentComponents.append("<p>x</p>", "[[component a /]]") ==
               "<p>x</p>\n[[component a /]]"

      assert ContentComponents.append("<p>x</p>\n", "[[component a /]]") ==
               "<p>x</p>\n[[component a /]]"
    end
  end
end
