# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.VisibilityTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.Authoring.Visibility`: an element kept in the page and shown to nobody —
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

  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Serializer
  alias MishkaCmsCore.Runtime.Authoring.Visibility

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

    # Stripping parses the template and writes it out again, so every class on an element it keeps
    # has to come back as it was written — a font size beside a colour, both spelt `text-[…]`, used
    # to come back as the colour alone.
    test "keeps every class on the elements it leaves, whatever prefix two of them share" do
      for class <- [
            "text-[14px] text-[#9a96c4] leading-6",
            "text-[clamp(1rem,2vw,2rem)] text-[var(--ink)]",
            "border-[2px] border-[#ccc]",
            "bg-[url(/hero.jpg)] bg-cover bg-center bg-[#111]",
            "bg-[length:200px_100px] bg-[center_top] bg-[#fff]",
            "shadow-[0_0_4px_#000] shadow-[#f00]",
            "bg-white bg-[#000]",
            "text-[#fff] text-[#000]",
            "p-[20px] px-8",
            "text-[14px] [font-size:2rem]",
            "p-[8] grid-cols-[3]"
          ] do
        stripped =
          Visibility.strip(~s(<div><p class="#{class}">Hi</p><p data-pb-hidden>Gone</p></div>))

        refute stripped =~ "Gone"
        assert [_match, kept] = Regex.run(~r/<p class="([^"]*)">Hi/, stripped)

        assert Enum.sort(String.split(kept)) == Enum.sort(String.split(class)),
               "#{class} came back as #{kept}"
      end
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

      assert :ok = MishkaCmsCore.Runtime.Authoring.CodeCheck.template(about)
      assert [%{tag: "div"} = hidden] = Visibility.hidden_roots(tree)

      assert Enum.any?(
               Tree.walk(tree),
               &(&1.kind == :component and &1 in descendants(tree, hidden))
             )

      html =
        LiveViewCompiler.render_template(about, %{
          page: %{language: "en"},
          query_params: %{"lang" => "en"}
        })

      assert html =~ "About localhost"
      refute html =~ "Coming soon: the team"
      refute html =~ "data-pb-hidden"
    end
  end

  defp descendants(tree, %{children: children}),
    do: Enum.flat_map(children, &[Tree.get(tree, &1) | descendants(tree, Tree.get(tree, &1))])

  defp descendants(_tree, _leaf), do: []
end
