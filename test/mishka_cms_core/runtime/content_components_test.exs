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

    test "a marker inside another is part of the outer one's inner content" do
      html = "<p>a</p>[[component outer]] x [[component inner]]y[[/component]] z [[/component]]"

      assert [%{name: "outer", inner: " x [[component inner]]y[[/component]] z "}] =
               markers(html)

      assert texts(html) == ["<p>a</p>"]
    end

    test "an opening marker nothing closes is text, and what it held is outermost" do
      html = "[[component open]] x [[component inner]]y[[/component]] z"

      assert [%{name: "inner", inner: "y", index: 0}] = markers(html)
      assert texts(html) == ["[[component open]] x ", " z"]
    end

    test "a closing marker closes what is open of its kind" do
      html = "[[component a]][[slot s]]x[[/component]]"

      assert [%{name: "a", inner: "[[slot s]]x"}] = markers(html)
    end

    test "a slot marker outside a component is text, and what it holds is outermost" do
      html = "[[slot item]]a [[component b /]][[/slot]][[slot x /]]"

      assert [%{name: "b", index: 0}] = markers(html)
      assert texts(html) == ["[[slot item]]a ", "[[/slot]][[slot x /]]"]
      assert ContentComponents.parse("[[slot x /]]") == [{:html, "[[slot x /]]"}]
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

    test "the components inside other markers and inside slot markers too" do
      html =
        "[[component card]][[component title /]][[slot item]][[component badge /]][[/slot]][[/component]][[component title /]]"

      assert ContentComponents.names(html) == ["card", "title", "badge"]
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

  describe "category/2 — the palette heading a component is listed under" do
    test "a kit's own type names it, under one spelling" do
      assert ContentComponents.category("acme-x", "forms") == "forms"
      assert ContentComponents.category("acme-x", "form") == "forms"
      assert ContentComponents.category("acme-x", "Navigations") == "navigation"
      assert ContentComponents.category("acme-x", "data display") == "data"
      assert ContentComponents.category("acme-x", "data-display") == "data"
      assert ContentComponents.category("chelekom-headless-code", "typography") == "text"
    end

    test "a general one is placed by the words of its name, read in order" do
      assert ContentComponents.category("chelekom-h2", "general") == "text"
      assert ContentComponents.category("chelekom-list-group", "general") == "text"
      assert ContentComponents.category("chelekom-table-content", "general") == "text"
      assert ContentComponents.category("chelekom-card-title", "general") == "layout"
      assert ContentComponents.category("chelekom-avatar-group", "general") == "media"
      assert ContentComponents.category("chelekom-button-link", nil) == "buttons"
      assert ContentComponents.category("chelekom-form-wrapper", "misc") == "forms"
    end

    test "a type of the kit's own keeps its name, and what nothing places is Other" do
      assert ContentComponents.category("acme-hero", "marketing") == "marketing"
      assert ContentComponents.category("acme-thing", "general") == "other"
      assert ContentComponents.category("acme-thing", nil) == "other"
    end

    test "sort_categories/1 puts text first, a kit's own after the known ones, Other last" do
      assert ContentComponents.sort_categories(~w(other forms zebra marketing media text forms)) ==
               ~w(text media forms marketing zebra other)
    end

    test "category_label/1 names a kit's own heading from its words" do
      assert ContentComponents.category_label("text") == "Text"
      assert ContentComponents.category_label("data_display") == "Data display"
    end
  end

  describe "slot_marker/3" do
    test "writes a slot entry as a component marker is written" do
      assert ContentComponents.slot_marker("source", %{"src" => "/a.mp4", "type" => ""}, nil) ==
               ~s([[slot source src="/a.mp4" /]])

      assert ContentComponents.slot_marker("item", %{"title" => "Q"}, "The <b>answer</b>") ==
               ~s([[slot item title="Q"]]The <b>answer</b>[[/slot]])

      assert ContentComponents.slot_marker("bad name", %{}, nil) == nil
    end
  end

  describe "inert/3 — a setting the others switch off" do
    defp clause(helper, discriminators),
      do: %{
        "name" => helper,
        "discriminators" =>
          for({axis, values} <- discriminators, do: %{"axis" => axis, "values" => values})
      }

    defp boxed(template) do
      ContentComponents.entry(%{
        name: "probe-box",
        description: nil,
        type: nil,
        stateful: false,
        site_id: nil,
        examples: [],
        template: template,
        slots: [%{"name" => "inner_block", "opts" => %{}}],
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "base", "values" => ~w(base default)}
          },
          %{
            "name" => "color",
            "type" => "string",
            "opts" => %{"default" => "white", "values" => ~w(white dark)}
          },
          %{
            "name" => "size",
            "type" => "string",
            "opts" => %{"default" => "small", "values" => ~w(small large)}
          }
        ],
        helpers: [
          clause("color_variant", [{"variant", ["base"]}]),
          clause("color_variant", [{"variant", ["default"]}, {"color", ["white"]}]),
          clause("color_variant", [{"variant", ["default"]}, {"color", ["dark"]}]),
          clause("color_variant", []),
          clause("size_class", [{"size", ["small"]}]),
          clause("size_class", [{"size", ["large"]}])
        ]
      })
    end

    @template ~S|<div class={[color_variant(@variant, @color), size_class(@size)]}>{render_slot(@inner_block)}</div>|

    test "is the clause the others pick, when it matches every value of the setting alike" do
      box = boxed(@template)

      assert ContentComponents.inert(box, "color", %{}) == %{"variant" => "base"}

      assert ContentComponents.inert(box, "color", %{"variant" => "base", "size" => "large"}) ==
               %{"variant" => "base"}

      assert ContentComponents.inert(box, "color", %{"variant" => "default"}) == nil
      assert ContentComponents.inert(box, "variant", %{}) == nil
      assert ContentComponents.inert(box, "size", %{}) == nil
    end

    test "is nothing it cannot tell: a setting the template uses anywhere else" do
      box =
        boxed(
          ~S|<div class={[color_variant(@variant, @color), size_class(@size)]} data-c={@color}></div>|
        )

      assert ContentComponents.inert(box, "color", %{}) == nil
    end

    test "is nothing a component with no such helpers can say" do
      plain = %{boxed(@template) | switches: %{helpers: [], through: []}}

      assert ContentComponents.inert(plain, "color", %{}) == nil
      assert ContentComponents.inert(%{}, "color", %{}) == nil
    end
  end

  describe "read/1 and write/1 — a marker as a tree" do
    @card ~s([[component card padding="small"]][[component card-title title="Hi" /]]Some <b>text</b>[[slot item label="One"]]first [[component badge /]][[/slot]][[slot item /]][[/component]])

    test "reads the components and slot entries a marker holds, in order" do
      assert {:ok,
              %{
                name: "card",
                attrs: %{"padding" => "small"},
                parts: [
                  {:component, %{name: "card-title", attrs: %{"title" => "Hi"}, parts: []}},
                  {:text, "Some <b>text</b>"},
                  {:slot,
                   %{
                     name: "item",
                     attrs: %{"label" => "One"},
                     parts: [
                       {:text, "first "},
                       {:component, %{name: "badge", attrs: %{}, parts: []}}
                     ]
                   }},
                  {:slot, %{name: "item", attrs: %{}, parts: []}}
                ]
              }} = ContentComponents.read(@card)
    end

    test "writes back the marker it read" do
      {:ok, tree} = ContentComponents.read(@card)

      assert ContentComponents.write(tree) == @card
      assert ContentComponents.read("<p>" <> @card <> "</p>") == {:ok, tree}
    end

    test "a changed tree writes the change" do
      {:ok, tree} = ContentComponents.read(~s([[component row]][[component a /]][[/component]]))

      tree = %{
        tree
        | parts: tree.parts ++ [{:component, %{name: "b", attrs: %{"k" => "v"}, parts: []}}]
      }

      assert ContentComponents.write(tree) ==
               ~s([[component row]][[component a /]][[component b k="v" /]][[/component]])
    end

    test "is not one marker" do
      assert ContentComponents.read("<p>text</p>") == :error
      assert ContentComponents.read("[[component a /]][[component b /]]") == :error
      assert ContentComponents.read("text [[component a /]]") == :error
      assert ContentComponents.read(nil) == :error
    end

    test "a tree holding a name a marker cannot carry writes nothing" do
      tree = %{
        name: "row",
        attrs: %{},
        parts: [{:component, %{name: "bad name", attrs: %{}, parts: []}}]
      }

      assert ContentComponents.write(tree) == nil
    end
  end

  describe "segments/1 — what the editor holds as blocks" do
    defp joined(segments),
      do:
        Enum.map_join(segments, fn
          {:html, html} -> html
          {:component, c} -> c.source
        end)

    test "content with no marker is one piece of HTML" do
      assert ContentComponents.segments("<p>Just text</p>") == [{:html, "<p>Just text</p>"}]
    end

    test "a marker alone in its paragraph is a block, the paragraph with it" do
      marker = ~s([[component chelekom-alert title="Heads up"]]Read <b>this</b>[[/component]])
      html = "<p>Intro</p><p>#{marker}</p><p>After</p>"

      assert ContentComponents.segments(html) == [
               {:html, "<p>Intro</p>"},
               {:component,
                %{
                  name: "chelekom-alert",
                  attrs: %{"title" => "Heads up"},
                  inner: "Read <b>this</b>",
                  marker: marker,
                  source: "<p>#{marker}</p>"
                }},
               {:html, "<p>After</p>"}
             ]
    end

    test "a marker inside no element is a block" do
      html = "<p>Intro</p>\n[[component chelekom-badge /]]"

      assert [
               {:html, "<p>Intro</p>\n"},
               {:component, %{marker: "[[component chelekom-badge /]]"}}
             ] =
               ContentComponents.segments(html)
    end

    test "a marker sharing its paragraph stays in the HTML" do
      html = "<p>Hello [[component chelekom-badge /]] world</p>"

      assert ContentComponents.segments(html) == [{:html, html}]
    end

    test "a marker in a list item's text, or in code, stays in the HTML" do
      html = "<ul><li>One [[component a /]]</li></ul><pre>[[component b /]]</pre>"

      assert ContentComponents.segments(html) == [{:html, html}]
    end

    test "a paragraph inside a quote holding only a marker is a block" do
      html = "<blockquote><p>[[component a /]]</p></blockquote>"

      assert [
               {:html, "<blockquote>"},
               {:component, %{name: "a", source: "<p>[[component a /]]</p>"}},
               {:html, "</blockquote>"}
             ] = ContentComponents.segments(html)
    end

    test "joined back in order, the pieces are the content they came from" do
      for html <- [
            "<p>a</p>",
            "<p>[[component a /]]</p>",
            "<p>x</p><p> [[component a k='v']]<i>in</i>[[/component]] </p><p>y</p>",
            "[[component a /]][[component b /]]<h2>t</h2>\n[[component c x=1 /]]",
            "<p>inline [[component a /]]</p><p>[[component b]]open",
            "<div><p>[[component a /]]</p></div><img src=\"x.png\"><p>[[component b /]]</p>"
          ] do
        assert html |> ContentComponents.segments() |> joined() == html
      end
    end

    test "a marker holding others is one block, its marker the whole of it" do
      marker = "[[component row]][[component a /]][[component b]]x[[/component]][[/component]]"

      assert [
               {:html, "<p>i</p>"},
               {:component, %{name: "row", marker: ^marker, source: ^marker}}
             ] = ContentComponents.segments("<p>i</p>" <> marker)
    end

    test "each block's marker is the marker as written" do
      html = ~s(<p>[[component a title=&quot;Hi&quot; /]]</p>)

      assert [{:component, %{marker: ~s([[component a title=&quot;Hi&quot; /]]), attrs: attrs}}] =
               ContentComponents.segments(html)

      assert attrs == %{"title" => "Hi"}
    end
  end
end
