defmodule MishkaCmsCore.Runtime.PageBuilder.VisibilityTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.PageBuilder.Visibility`: an element kept in the page and shown to nobody —
  the marker in the markup, what the compilers leave out, and the one edit that toggles it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.{
    ComponentCompiler,
    ErrorCompiler,
    LayoutCompiler,
    LiveViewCompiler,
    ModuleCompiler
  }

  alias MishkaCmsCore.Runtime.PageBuilder.{EditorSession, Visibility}
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @page ~S"""
  <main>
    <section data-pb-hidden>
      <h2>Coming soon</h2>
      <p data-pb-hidden>Not even then</p>
    </section>
    <p :if={@open?}>Open today</p>
    <footer>Always</footer>
  </main>
  """

  defp node(tree, tag), do: Enum.find(Tree.walk(tree), &(&1.tag == tag))
  defp nodes(tree, tag), do: Enum.filter(Tree.walk(tree), &(&1.tag == tag))

  describe "the marker" do
    test "is markup: it survives a parse and a serialize unchanged, as a bare attribute" do
      tree = Tree.parse!(@page)
      html = Serializer.serialize(tree)

      assert html =~ ~s(<section data-pb-hidden>)
      assert Serializer.serialize(Tree.parse!(html)) == html
      assert Visibility.hidden?(node(tree, "section"))
      refute Visibility.hidden?(node(tree, "footer"))
    end

    test "is offered on an element, a component and a slot, never on text or a document's root" do
      tree = Tree.parse!(~S(<body><div><.link navigate="/">go</.link>words</div></body>))

      assert Visibility.hideable?(node(tree, "div"))
      assert Visibility.hideable?(Enum.find(Tree.walk(tree), &(&1.kind == :component)))
      refute Visibility.hideable?(Enum.find(Tree.walk(tree), &(&1.kind == :text)))
      refute Visibility.hideable?(node(tree, "body"))
    end
  end

  describe "what hides a node" do
    test "is the node itself, else its nearest hidden ancestor" do
      tree = Tree.parse!(@page)
      section = node(tree, "section")
      own = Enum.find(nodes(tree, "p"), &Visibility.hidden?/1)

      assert Visibility.hidden_by(tree, node(tree, "h2").id).id == section.id
      assert Visibility.hidden_by(tree, own.id).id == own.id
      assert Visibility.hidden_by(tree, node(tree, "footer").id) == nil
    end

    test "the roots are the hidden nodes no hidden ancestor covers" do
      tree = Tree.parse!(@page)

      assert [%{tag: "section"}] = Visibility.hidden_roots(tree)
    end
  end

  describe "the template a compiler compiles" do
    test "leaves out every hidden element and what is inside it, and nothing else" do
      stripped = Visibility.strip(@page)

      refute stripped =~ "Coming soon"
      refute stripped =~ "Not even then"
      refute stripped =~ "data-pb-hidden"
      assert stripped =~ "Open today"
      assert stripped =~ "Always"
    end

    test "is the stored template itself when nothing is hidden, unparsed" do
      template = "<p>{@unclosed"
      assert Visibility.strip(template) == template
      assert Visibility.strip(nil) == nil
    end

    test "keeps a template it cannot read rather than failing the compile" do
      broken = ~S(<div data-pb-hidden>{@unclosed</div>)

      assert {:error, _reason} = Tree.parse(broken)

      assert ExUnit.CaptureLog.capture_log(fn -> assert Visibility.strip(broken) == broken end) =~
               "Hidden elements were kept in a template that does not parse"
    end

    test "is what a render draws: nothing for a hidden element, its siblings and their conditions as written" do
      html = LiveViewCompiler.render_template(@page, %{open?: true})

      refute html =~ "Coming soon"
      refute html =~ "data-pb-hidden"
      assert html =~ "Open today"
      assert html =~ "Always"

      refute LiveViewCompiler.render_template(@page, %{open?: false}) =~ "Open today"
    end
  end

  describe "every compiler" do
    defp built?(ast, text), do: Macro.to_string(ast) =~ text

    test "builds a page that renders without it" do
      module = :"Elixir.VisibilityTestPage#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Hidden",
          page_module: module,
          template: @page,
          events: []
        })

      {:ok, ^module, _diagnostics} = ModuleCompiler.compile_module(ast)

      html =
        %{__changed__: nil, flash: %{}, open?: true}
        |> module.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      refute html =~ "Coming soon"
      refute html =~ "data-pb-hidden"
      assert html =~ "Open today"
    end

    test "builds a layout, an error page's render and a component without it" do
      body =
        ~S(<body><header data-pb-hidden>Coming soon</header>{@inner_content}<footer>Always</footer></body>)

      layout =
        LayoutCompiler.build_module(%{
          title: "hidden_layout",
          layout_module: VisibilityTest.Layout,
          template: body
        })

      {_params, errors} =
        ErrorCompiler.build_render_functions(
          {%{site: "test", error_pages: [%{status: 404, template: @page}]}, []}
        )

      component =
        ComponentCompiler.build_module(%{
          "id" => "visibility-test",
          "title" => "hidden_card",
          "component_module" => VisibilityTest.Component,
          "template" => @page,
          "attrs" => [%{"name" => "open?", "type" => "boolean", "opts" => %{}}],
          "slots" => [],
          "site" => "Test",
          "priority" => 50
        })

      for ast <- [layout, errors, component] do
        refute built?(ast, "Coming soon")
        assert built?(ast, "Always")
      end
    end
  end

  describe "the dev seed's about page" do
    test "compiles as stored, hides one container, and renders without it" do
      about = MishkaCmsCore.Dev.LocalhostPages.about()
      tree = Tree.parse!(about)

      assert :ok = MishkaCmsCore.Runtime.PageBuilder.CodeCheck.template(about)
      assert [%{tag: "div"} = hidden] = Visibility.hidden_roots(tree)

      assert Enum.any?(
               Tree.walk(tree),
               &(&1.kind == :component and &1 in descendants(tree, hidden))
             )

      html = LiveViewCompiler.render_template(about, %{query_params: %{"lang" => "en"}})

      assert html =~ "About localhost"
      refute html =~ "Coming soon: the team"
      refute html =~ "data-pb-hidden"
    end
  end

  defp descendants(tree, %{children: children}),
    do: Enum.flat_map(children, &[Tree.get(tree, &1) | descendants(tree, Tree.get(tree, &1))])

  defp descendants(_tree, _leaf), do: []

  describe "the edit" do
    test "hides an element, shows it again, and each is one entry in the history, undone as one" do
      {:ok, session} =
        EditorSession.open(%{section: "page", template: ~S(<div><p>Hello</p></div>)})

      p = node(session.tree, "p")

      {:ok, hidden} = EditorSession.toggle_visibility(session.token, p.id)
      assert Visibility.hidden?(Tree.get(hidden.tree, p.id))
      assert Serializer.serialize(hidden.tree) =~ "<p data-pb-hidden>Hello</p>"
      assert %{label: "Hidden from visitors"} = hd(hidden.past)

      {:ok, shown} = EditorSession.toggle_visibility(session.token, p.id)
      refute Visibility.hidden?(Tree.get(shown.tree, p.id))
      assert %{label: "Shown to visitors"} = hd(shown.past)

      {:ok, undone} = EditorSession.undo(session.token)
      assert Visibility.hidden?(Tree.get(undone.tree, p.id))
    end

    test "is refused for text, and for an element hidden only because its container is" do
      {:ok, session} =
        EditorSession.open(%{
          section: "page",
          template: ~S(<section data-pb-hidden><h2>Title</h2>words</section>)
        })

      text = Enum.find(Tree.walk(session.tree), &(&1.kind == :text and &1.text =~ "words"))
      h2 = node(session.tree, "h2")

      assert {:error, "Only an element can be hidden." <> _} =
               EditorSession.toggle_visibility(session.token, text.id)

      assert {:error, "It is hidden with the element around it." <> _} =
               EditorSession.toggle_visibility(session.token, h2.id)
    end

    test "is the right-click menu's visibility entry" do
      {:ok, session} =
        EditorSession.open(%{section: "page", template: ~S(<div><p>Hello</p></div>)})

      p = node(session.tree, "p")

      assert {:ok, hidden} = EditorSession.context_action(session.token, "visibility", p.id)
      assert Visibility.hidden?(Tree.get(hidden.tree, p.id))
    end
  end
end
