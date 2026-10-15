defmodule MishkaCmsCore.Runtime.Compilers.CssClosureTest do
  @moduledoc """
  A UI kit is installed once and shared, so the CSS compiler used to glob the whole global component
  directory — 244 templates and 2.1 MB of Chelekom — into every site's stylesheet. This walk is what
  replaces that glob, and both directions of it are load-bearing:

    * miss a reachable component and it renders with NO CSS, in production, on a page that looked
      fine in the editor;
    * keep an unreachable one and the saving never arrives.

  So the tests below assert the boundary from both sides, and separately assert that an unresolvable
  reference gives up entirely rather than guessing.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Runtime.Compilers.CssClosure
  alias MishkaCmsCore.Runtime.Handlers.BootHandler

  setup do
    root = Path.join(System.tmp_dir!(), "css_closure_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write(root, scope, kind, name, source) do
    dir = Path.join([root, scope, kind])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.template"), source)
  end

  defp global_component(root, name, source),
    do: write(root, "__global__", "component", name, source)

  defp reference(name), do: ~s|<.component component_name="#{name}" site="acme">x</.component>|

  defp closure(root, site \\ "acme", opts \\ []) do
    CssClosure.for_site(site, Keyword.put(opts, :runtime_dir, root))
  end

  # A COMPONENT FILE AS BOOT WRITES IT, attribute lines and all — so the walk reads exactly what
  # `BootHandler.build_component_class_content/1` produces from the row.
  defp component_row(root, name, row) do
    global_component(root, name, BootHandler.build_component_class_content(row))
  end

  defp attribute(name, default \\ ""),
    do: %{name: name, type: "string", opts: %{default: default}}

  defp named_through(attribute),
    do: ~s|<.component component_name={@#{attribute}} site="acme" id="x" />|

  defp call(name, given), do: ~s|<.component component_name="#{name}" site="acme" #{given} />|

  # `kit-list` draws each item with the component its caller names as `card`.
  defp card_list(root, default \\ "") do
    component_row(root, "kit-list", %{
      template: ~s|<div class="grid">#{named_through("card")}</div>|,
      attrs: [attribute("card", default)]
    })
  end

  defp unbounded_naming(fun) do
    log = capture_log(fn -> assert fun.() == :unbounded end)
    log
  end

  describe "reachability" do
    test "a component a page names is reached", %{root: root} do
      global_component(root, "kit-alert", "<div class='p-2'></div>")
      global_component(root, "kit-carousel", "<div class='p-3'></div>")
      write(root, "acme", "page", "home", reference("kit-alert"))

      assert %{components: ["kit-alert"]} = closure(root)
    end

    test "nothing is reached from a site with no references", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")
      write(root, "acme", "page", "home", "<p>plain</p>")

      assert %{components: []} = closure(root)
    end

    # Components compose: a form wrapper renders an error, which renders an icon. Stopping at the
    # first hop would style the wrapper and leave the icon blank.
    test "the walk is transitive", %{root: root} do
      global_component(root, "kit-wrapper", reference("kit-error"))
      global_component(root, "kit-error", reference("kit-icon"))
      global_component(root, "kit-icon", "<span></span>")
      global_component(root, "kit-unused", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-wrapper"))

      assert %{components: ["kit-error", "kit-icon", "kit-wrapper"]} = closure(root)
    end

    # Two components that render each other inside opposite branches are legal markup.
    test "a cycle terminates", %{root: root} do
      global_component(root, "kit-a", reference("kit-b"))
      global_component(root, "kit-b", reference("kit-a"))
      write(root, "acme", "page", "home", reference("kit-a"))

      assert %{components: ["kit-a", "kit-b"]} = closure(root)
    end

    test "another site's pages do not widen this site's closure", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")
      global_component(root, "kit-modal", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-alert"))
      write(root, "other", "page", "home", reference("kit-modal"))

      assert %{components: ["kit-alert"]} = closure(root)
    end

    # An error page is the template that renders when everything else has failed, and a visitor
    # reaches it by URL like any page, so it is a root. A LAYOUT is not: it is chosen by a database
    # relation, so nothing in the tree says which of a site's thirty layouts its five pages use, and
    # the caller passes the ones that do.
    test "error pages are roots, layouts are not", %{root: root} do
      global_component(root, "kit-nav", "<nav></nav>")
      global_component(root, "kit-sad", "<div></div>")

      write(root, "acme", "layout", "main", reference("kit-nav"))
      write(root, "acme", "error", "404", reference("kit-sad"))

      assert %{components: ["kit-sad"]} = closure(root)
    end

    # THE SITE'S OWN COMPONENTS ARE WALKED, NOT ASSUMED. They used to be roots, so all of them were
    # reachable by definition: a real install has 167 of them and its pages name two, and the other
    # 165 put their classes in the stylesheet every visitor downloads.
    test "an unreferenced site component is not reached", %{root: root} do
      global_component(root, "kit-inner", "<span></span>")
      write(root, "acme", "component", "site-orphan", reference("kit-inner"))
      write(root, "acme", "page", "home", "<p>plain</p>")

      assert %{components: [], templates: templates} = closure(root)
      refute Enum.any?(templates, &String.contains?(&1, "component"))
    end

    test "a site component a page names is reached, and so is what it names", %{root: root} do
      global_component(root, "kit-inner", "<span></span>")
      write(root, "acme", "component", "site-card", reference("kit-inner"))
      write(root, "acme", "page", "home", reference("site-card"))

      assert %{components: ["kit-inner", "site-card"]} = closure(root)
    end

    # Two sites on one install answer differently — which is the whole point of walking per site.
    test "two sites reach their own components and not each other's", %{root: root} do
      write(root, "acme", "component", "acme-hero", "<div></div>")
      write(root, "other", "component", "other-hero", "<div></div>")
      write(root, "acme", "page", "home", reference("acme-hero"))
      write(root, "other", "page", "home", reference("other-hero"))

      assert %{components: ["acme-hero"]} = closure(root)
      assert %{components: ["other-hero"]} = closure(root, "other")
    end

    # An install overrides a kit by giving a component of its own the same name.
    test "a site component shadows the global one it is named after", %{root: root} do
      global_component(root, "kit-alert", "<div class='global'></div>")
      write(root, "acme", "component", "kit-alert", "<div class='mine'></div>")
      write(root, "acme", "page", "home", reference("kit-alert"))

      assert %{components: ["kit-alert"], templates: templates} = closure(root)
      assert [template] = Enum.filter(templates, &String.contains?(&1, "/component/"))
      assert template =~ "/acme/component/kit-alert.template"
      assert File.read!(template) =~ "mine"
    end

    # The paths are what the compiler emits `@source` lines from, so they have to point at the file
    # that was actually resolved rather than at a guessed directory.
    test "templates are the resolved paths, in whichever scope they were found", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")
      write(root, "acme", "component", "site-card", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-alert") <> reference("site-card"))

      assert %{templates: templates} = closure(root)

      assert Enum.any?(
               templates,
               &String.ends_with?(&1, "/__global__/component/kit-alert.template")
             )

      assert Enum.any?(templates, &String.ends_with?(&1, "/acme/component/site-card.template"))
    end

    # BEING GLOBAL IS NOT BEING USED. Every global layout used to be a root of every site's walk, so
    # a footer component reached only by a layout no page on this site picks still shipped its CSS
    # here — and did so on every install, to every visitor.
    test "a global layout nothing on this site uses contributes nothing", %{root: root} do
      global_component(root, "kit-footer", "<footer></footer>")
      write(root, "__global__", "layout", "shared", reference("kit-footer"))
      write(root, "acme", "page", "home", "<p>plain</p>")

      assert %{components: []} = closure(root)
    end

    test "a reference to an uninstalled component is dropped rather than raising", %{root: root} do
      write(root, "acme", "page", "home", reference("kit-gone"))

      assert %{components: []} = closure(root)
    end
  end

  # A POST'S MARKERS NAME COMPONENTS NO TEMPLATE SHOWS. Whoever stores the content says which, and a
  # template that draws content reaches exactly those — see `MishkaCmsCore.Runtime.ContentComponents`.
  describe "components named in stored content" do
    test "a template that draws content reaches the components its content names", %{root: root} do
      global_component(
        root,
        "kit-article",
        ~s|<div><.rich_content html={@body} site="acme" /></div>|
      )

      global_component(root, "kit-alert", reference("kit-icon"))
      global_component(root, "kit-icon", "<span></span>")
      global_component(root, "kit-carousel", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-article"))

      assert %{components: ["kit-alert", "kit-article", "kit-icon"]} =
               closure(root, "acme", content_components: ["kit-alert", "kit-gone"])
    end

    test "none of them when nothing reached draws content", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")
      write(root, "acme", "page", "home", "<p>plain</p>")

      assert %{components: []} = closure(root, "acme", content_components: ["kit-alert"])
    end

    test "and none when the content names none", %{root: root} do
      global_component(root, "kit-article", ~s|<div><.rich_content html={@body} /></div>|)
      global_component(root, "kit-alert", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-article"))

      assert %{components: ["kit-article"]} = closure(root)
    end
  end

  describe "giving up" do
    # `component_name={@name}` names something only the request knows. Scanning the whole directory
    # then is the ONLY safe answer: an under-approximation ships a page with no CSS.
    test "a component named by an expression makes the closure unbounded", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")
      write(root, "acme", "page", "home", ~s|<.component component_name={@name} site="acme" />|)

      assert closure(root) == :unbounded
    end

    test "a dynamic reference inside a REACHED component also gives up", %{root: root} do
      global_component(root, "kit-alert", ~s|<.component component_name={@inner} site="acme" />|)
      write(root, "acme", "page", "home", reference("kit-alert"))

      assert closure(root) == :unbounded
    end
  end

  # `component_name={@card}` NAMES WHATEVER THE CALLER HANDS OVER AS `card`. When the component
  # declares `card` and never assigns it itself, that is its default and the literals its reached
  # callers write — a closed set, walked like any literal. Anything the walk cannot read gives up.
  describe "a component named through its own attribute" do
    test "callers that hand nothing over resolve to nothing, and the site stays bounded",
         %{root: root} do
      card_list(root)
      global_component(root, "kit-card", "<div class='p-9'></div>")
      write(root, "acme", "page", "home", reference("kit-list"))

      assert %{
               components: ["kit-list"],
               resolved: [%{component: "kit-list", attribute: "card", names: []}]
             } = closure(root)
    end

    test "the literals reached callers write are walked, and what those reach", %{root: root} do
      card_list(root)
      global_component(root, "kit-a", reference("kit-icon"))
      global_component(root, "kit-b", "<div></div>")
      global_component(root, "kit-icon", "<span></span>")
      global_component(root, "kit-c", "<div></div>")
      write(root, "acme", "page", "home", call("kit-list", ~s|card="kit-a"|))
      write(root, "acme", "page", "about", call("kit-list", ~s|heading="Docs" card="kit-b"|))

      assert %{
               components: ["kit-a", "kit-b", "kit-icon", "kit-list"],
               resolved: [%{component: "kit-list", attribute: "card", names: ["kit-a", "kit-b"]}]
             } = closure(root)
    end

    test "a caller that is not reached hands nothing over", %{root: root} do
      card_list(root)
      global_component(root, "kit-c", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-list"))
      write(root, "other", "page", "home", call("kit-list", ~s|card="kit-c"|))

      assert %{components: ["kit-list"]} = closure(root)
      assert %{components: ["kit-c", "kit-list"]} = closure(root, "other")
    end

    test "the declared default counts", %{root: root} do
      card_list(root, "kit-default")
      global_component(root, "kit-default", "<div></div>")
      global_component(root, "kit-a", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-list"))
      write(root, "acme", "page", "about", call("kit-list", ~s|card="kit-a"|))

      assert %{
               components: ["kit-a", "kit-default", "kit-list"],
               resolved: [%{names: ["kit-a", "kit-default"]}]
             } = closure(root)
    end

    # The component a name reaches may hand a name on through its own attribute, and only once the
    # first is walked does the second have a caller.
    test "a name handed on by a component reached through an attribute is followed",
         %{root: root} do
      component_row(root, "kit-outer", %{
        template: ~s|<.component component_name={@card} site="acme" inner="kit-leaf" />|,
        attrs: [attribute("card")]
      })

      component_row(root, "kit-mid", %{
        template: named_through("inner"),
        attrs: [attribute("inner")]
      })

      global_component(root, "kit-leaf", "<b></b>")
      write(root, "acme", "page", "home", call("kit-outer", ~s|card="kit-mid"|))

      assert %{components: ["kit-leaf", "kit-mid", "kit-outer"]} = closure(root)
    end

    test "a site component of that name is the one reached", %{root: root} do
      card_list(root)
      global_component(root, "kit-a", "<div class='global'></div>")
      write(root, "acme", "component", "kit-a", "<div class='mine'></div>")
      write(root, "acme", "page", "home", call("kit-list", ~s|card="kit-a"|))

      assert %{templates: templates} = closure(root)
      assert Enum.any?(templates, &String.ends_with?(&1, "/acme/component/kit-a.template"))
      refute Enum.any?(templates, &String.ends_with?(&1, "/__global__/component/kit-a.template"))
    end

    test "one caller handing the attribute an expression makes it unbounded, naming that caller",
         %{root: root} do
      card_list(root)
      global_component(root, "kit-a", "<div></div>")
      write(root, "acme", "page", "home", call("kit-list", ~s|card="kit-a"|))
      write(root, "acme", "page", "chooser", call("kit-list", ~s|card={@which}|))

      log = unbounded_naming(fn -> closure(root) end)

      assert log =~ "chooser.template"
      refute log =~ "kit-list.template"
    end

    test "a caller spreading attributes into the tag can hand anything over", %{root: root} do
      card_list(root)
      write(root, "acme", "page", "spreader", call("kit-list", ~s|{@rest}|))

      assert unbounded_naming(fn -> closure(root) end) =~ "spreader.template"
    end

    # A post's marker writes the attributes, and the walk is handed only the names.
    test "a component drawn from stored content is handed what an author wrote", %{root: root} do
      card_list(root)
      global_component(root, "kit-article", ~s|<div><.rich_content html={@body} /></div>|)
      write(root, "acme", "page", "home", reference("kit-article"))

      log = unbounded_naming(fn -> closure(root, "acme", content_components: ["kit-list"]) end)

      assert log =~ "kit-article.template"
    end

    test "a template that calls a component from code can hand anything over", %{root: root} do
      card_list(root)

      write(
        root,
        "acme",
        "page",
        "coded",
        reference("kit-list") <> ~s|{component(%{component_name: "kit-list", card: "kit-x"})}|
      )

      assert unbounded_naming(fn -> closure(root) end) =~ "coded.template"
    end

    test "an attribute the component does not declare stays unbounded", %{root: root} do
      component_row(root, "kit-loose", %{template: named_through("card"), attrs: []})
      write(root, "acme", "page", "home", call("kit-loose", ~s|card="kit-a"|))

      assert unbounded_naming(fn -> closure(root) end) =~ "kit-loose.template"
    end

    test "a page names nothing through an attribute, whatever its file says", %{root: root} do
      write(
        root,
        "acme",
        "page",
        "home",
        named_through("card") <> "\n<%!-- css-closure attr=card --%>"
      )

      assert closure(root) == :unbounded
    end

    test "any other expression in a component_name stays unbounded", %{root: root} do
      global_component(root, "kit-a", "<div></div>")

      for expression <- [~s|{@card <> "-x"}|, "{pick(@card)}", "{@card.name}", "{assigns.card}"] do
        component_row(root, "kit-list", %{
          template:
            ~s|<.component component_name=#{expression} site="acme" />| <> named_through("card"),
          attrs: [attribute("card")]
        })

        write(root, "acme", "page", "home", call("kit-list", ~s|card="kit-a"|))

        assert unbounded_naming(fn -> closure(root) end) =~ "kit-list.template", expression
      end
    end

    test "a tag that names nothing and spreads a map names an expression", %{root: root} do
      write(root, "acme", "page", "home", ~s|<.component {@attrs} />|)

      assert closure(root) == :unbounded
    end

    # `:if={@total > 0}` holds a `>`, and a string in an expression may hold a brace.
    test "a tag is read through expressions holding > and braces", %{root: root} do
      card_list(root)
      global_component(root, "kit-a", "<div></div>")

      write(
        root,
        "acme",
        "page",
        "home",
        ~s|<.component :if={@total > 0} component_name="kit-list" label={"a } \#{%{b: 1}}"} | <>
          ~s|site="acme" card="kit-a" />|
      )

      assert %{components: ["kit-a", "kit-list"]} = closure(root)
    end
  end

  describe "attribute_marks/1" do
    test "marks a declared attribute the markup names a component through, with its default" do
      assert CssClosure.attribute_marks(%{
               template: named_through("card"),
               attrs: [attribute("card", "kit-card"), attribute("heading", "Docs")]
             }) == ~s|<%!-- css-closure attr=card default="kit-card" --%>|
    end

    test "an empty default writes no default" do
      assert CssClosure.attribute_marks(%{
               template: named_through("card"),
               attrs: [attribute("card")]
             }) == "<%!-- css-closure attr=card --%>"
    end

    test "nothing to mark when the markup names no component through an attribute" do
      assert CssClosure.attribute_marks(%{
               template: ~s|<.component component_name="kit-a" />|,
               attrs: [attribute("card")]
             }) == ""
    end

    test "an attribute the component does not declare is not marked" do
      assert CssClosure.attribute_marks(%{template: named_through("card"), attrs: []}) == ""
    end

    # IT WOULD NO LONGER BE THE CALLER'S. A component that assigns `card` itself draws whatever it
    # assigned, which no caller wrote down.
    test "an attribute the component's own code assigns is not marked" do
      for code <- [
            ~s|{:ok, assign(socket, :card, "kit-other")}|,
            ~s|{:ok, assign(socket, card: "kit-other", page: 1)}|,
            ~s|{:ok, socket \|> assign(:page, 1) \|> assign(:card, "kit-other")}|,
            ~s|{:ok, Phoenix.Component.assign(socket, %{card: "kit-other"})}|,
            ~s|{:ok, assign_new(socket, :card, fn -> "kit-other" end)}|,
            ~s|{:ok, update(socket, :card, &String.trim/1)}|,
            ~s|Map.put(assigns, :card, "kit-other")|,
            ~s|%{assigns \| card: "kit-other"}|
          ] do
        assert CssClosure.attribute_marks(%{
                 template: named_through("card"),
                 attrs: [attribute("card")],
                 helpers: [%{name: "update", args: "assigns, socket", code: code}]
               }) == "",
               code
      end
    end

    test "a body that assigns the attribute marks nothing" do
      assert CssClosure.attribute_marks(%{
               template: named_through("card"),
               attrs: [attribute("card")],
               body: ~s|assign(assigns, :card, "kit-other")|
             }) == ""
    end

    test "an assign whose name is worked out at runtime marks nothing" do
      for code <- [
            "{:ok, assign(socket, key, value)}",
            "{:ok, assign(socket, values)}",
            "Map.put(assigns, key, value)",
            "put_in(socket.assigns.card, 1)"
          ] do
        assert CssClosure.attribute_marks(%{
                 template: named_through("card"),
                 attrs: [attribute("card")],
                 helpers: [%{name: "update", code: code}]
               }) == "",
               code
      end
    end

    # A `{@card}` inside a helper's `~H` reads THAT function's assigns, which its caller built.
    test "an attribute read inside a helper's markup is not marked" do
      assert CssClosure.attribute_marks(%{
               template: named_through("card") <> "{row(%{card: @other})}",
               attrs: [attribute("card")],
               helpers: [%{name: "row", code: ~s|~H"#{named_through("card")}"|}]
             }) == ""
    end

    test "code that does not parse marks nothing" do
      assert CssClosure.attribute_marks(%{
               template: named_through("card"),
               attrs: [attribute("card")],
               helpers: [%{name: "broken", code: "assign(socket, "}]
             }) == ""
    end

    # The shape of the Mishka Document kit's list: a body-level `rescue`, writes to other assigns
    # and to a map that is not `assigns`, and the stock `assign(socket, assigns)`.
    test "writes to other assigns and other maps leave the attribute marked" do
      helpers = [
        %{name: "fetch_now", code: "fetch(asked)\nrescue\n  error -> {:error, error}"},
        %{name: "href", code: "Map.put(extra, key, code)"},
        %{
          name: "load",
          code: "socket |> assign(loading: false) |> assign(:asked, %{asked | page: 2})"
        },
        %{name: "update", code: "{:ok, assign(socket, assigns)}"}
      ]

      assert CssClosure.attribute_marks(%{
               template: named_through("card"),
               attrs: [attribute("card")],
               helpers: helpers
             }) == "<%!-- css-closure attr=card --%>"
    end

    test "a record decoded from a job, with string keys, is read the same" do
      assert CssClosure.attribute_marks(%{
               "template" => named_through("card"),
               "attrs" => [
                 %{"name" => "card", "type" => "string", "opts" => %{"default" => "kit-a"}}
               ],
               "helpers" => [%{"name" => "load", "code" => "assign(socket, :page, 1)"}]
             }) == ~s|<%!-- css-closure attr=card default="kit-a" --%>|
    end

    test "boot writes the lines into the component's template file" do
      content =
        BootHandler.build_component_class_content(%{
          template: named_through("card"),
          attrs: [attribute("card", "kit-a")]
        })

      assert content =~ ~s|<%!-- css-closure attr=card default="kit-a" --%>|
    end

    # The content editor offers both as ready blocks, and the HTML they place carries its own classes.
    test "boot writes what the component is placed with: its examples and its furnishing" do
      content =
        BootHandler.build_component_class_content(%{
          template: "<div></div>",
          examples: [
            ~s|<.component component_name="kit-hero"><h1 class="py-16">Hi</h1></.component>|
          ],
          extra: %{
            "furnishing" => %{
              "body" => ~s|<p class="tracking-tight">Body</p>|,
              "slots" => [
                %{"name" => "actions", "body" => ~s|<span class="opacity-70">Go</span>|}
              ]
            }
          }
        })

      assert content =~ "py-16"
      assert content =~ "tracking-tight"
      assert content =~ "opacity-70"
    end
  end

  describe "roots the caller supplies" do
    # Which layouts a site uses lives in `pages.layout_id`, so the compiler passes them —
    # `TailwindCompiler.closure_roots/2`. Here that is simply "a path the caller named".
    test "a layout passed as a root brings what it references", %{root: root} do
      global_component(root, "kit-nav", "<nav></nav>")
      global_component(root, "kit-elsewhere", "<div></div>")
      write(root, "acme", "layout", "main", reference("kit-nav"))
      write(root, "acme", "layout", "unused", reference("kit-elsewhere"))
      write(root, "acme", "page", "home", "<p>plain</p>")

      roots = [
        Path.join([root, "acme", "page", "home.template"]),
        Path.join([root, "acme", "layout", "main.template"])
      ]

      assert %{components: ["kit-nav"]} = closure(root, "acme", roots: roots)
    end

    # The roots carry classes of their own — a page's markup is most of what a site looks like — so
    # they have to be in the answer, not merely a source of edges.
    test "the roots are part of the answer, not only a source of edges", %{root: root} do
      write(root, "acme", "page", "home", "<p>plain</p>")
      page = Path.join([root, "acme", "page", "home.template"])

      assert %{templates: templates} = closure(root, "acme", roots: [page])
      assert page in templates
    end

    test "a root that does not exist is ignored rather than raising", %{root: root} do
      write(root, "acme", "page", "home", "<p>plain</p>")
      gone = Path.join([root, "acme", "layout", "gone.template"])

      assert %{components: []} = closure(root, "acme", roots: [gone])
    end
  end

  describe "entry_templates/2" do
    # What a bare directory can work out on its own: the pages and error pages a visitor can ask for
    # by URL. Not layouts, and not components.
    test "collects pages and error pages, and nothing else", %{root: root} do
      write(root, "acme", "page", "home", "")
      write(root, "acme", "error", "404", "")
      write(root, "acme", "layout", "main", "")
      write(root, "acme", "component", "card", "")
      write(root, "acme", "js_hook", "copy", "")

      kinds =
        root
        |> CssClosure.entry_templates(["acme"])
        |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
        |> Enum.sort()

      assert kinds == ["error", "page"]
    end

    test "covers every scope it is given, which is how a draft is included", %{root: root} do
      write(root, "acme", "page", "home", "")
      write(root, "preview_abc", "page", "draft", "")

      assert length(CssClosure.entry_templates(root, ["acme"])) == 1
      assert length(CssClosure.entry_templates(root, ["acme", "preview_abc"])) == 2
    end
  end

  describe "draft previews" do
    # The draft is usually the ONLY thing referencing the component being previewed — that is what
    # makes it a draft. A walk over the saved site alone leaves it unstyled in the one view whose
    # entire job is showing what it will look like.
    test "an extra scope's references are reached", %{root: root} do
      global_component(root, "kit-modal", "<div></div>")
      write(root, "acme", "page", "home", "<p>saved</p>")
      write(root, "preview_abc", "page", "draft", reference("kit-modal"))

      assert %{components: []} = closure(root)
      assert %{components: ["kit-modal"]} = closure(root, "acme", extra_scopes: ["preview_abc"])
    end
  end

  describe "reached_components/2" do
    defp reached(root, site \\ "acme"),
      do: CssClosure.reached_components(site, runtime_dir: root)

    test "names each reached component with the site a tag draws it for", %{root: root} do
      global_component(root, "kit-icon", "<i></i>")
      write(root, "acme", "component", "card", reference("kit-icon"))
      global_component(root, "kit-unused", "<div></div>")
      write(root, "acme", "page", "home", reference("card"))

      assert reached(root) == %{
               complete?: true,
               components: [%{name: "kit-icon", site: "Global"}, %{name: "card", site: "acme"}]
             }
    end

    test "a site component shadowing a global one is the site's", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")
      write(root, "acme", "component", "kit-alert", "<div></div>")
      write(root, "acme", "page", "home", reference("kit-alert"))

      assert %{components: [%{name: "kit-alert", site: "acme"}]} = reached(root)
    end

    # `for_site/2` gives up on the whole answer here, because a stylesheet built from part of it
    # leaves a component unstyled. Part of it is still what is certainly reached.
    test "a reference the walk cannot resolve still answers what it did reach", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")

      write(
        root,
        "acme",
        "page",
        "home",
        reference("kit-alert") <> ~s|<.component component_name={@pick} />|
      )

      assert unbounded_naming(fn -> closure(root) end) =~ "cannot resolve"

      assert reached(root) == %{
               complete?: false,
               components: [%{name: "kit-alert", site: "Global"}]
             }
    end

    test "nothing is reached from a site with no references", %{root: root} do
      global_component(root, "kit-alert", "<div></div>")
      write(root, "acme", "page", "home", "<p>plain</p>")

      assert reached(root) == %{complete?: true, components: []}
    end
  end

  describe "all_components/1" do
    test "lists every installed global component, reachable or not", %{root: root} do
      global_component(root, "kit-a", "")
      global_component(root, "kit-b", "")
      write(root, "acme", "page", "home", reference("kit-a"))

      assert CssClosure.all_components(runtime_dir: root) == ["kit-a", "kit-b"]
    end
  end
end
