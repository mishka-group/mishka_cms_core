defmodule MishkaCmsCore.UiKit.KitCompileTest do
  @moduledoc """
  Every component of both Chelekom kits as `mix mishka.ui.export … --cms` writes them
  (`test/fixtures/cms_ui_kits_export/`, copied from mishka_chelekom, never edited), installed and
  built by the CMS's own compiler, as the first render of each builds it.

  A bundle carries an `atom` attribute's `default`, `values` and `examples` as strings, since JSON
  has no atoms, and Phoenix's `attr/3` checks each of them against the type when the module is
  compiled — so a component whose `kind` lists its values did not compile at all.

  `async: false` — the kits are installed once for the module, and the modules built are global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Component, ContentComponents, LiveViewHelpers}
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.Handlers.{ModuleCompilerHandler, UiKitHandler}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @moduletag :integration
  @moduletag timeout: :infinity

  @export_dir Path.expand("../../fixtures/cms_ui_kits_export", __DIR__)

  setup_all do
    context = module_sandbox()
    kits = UiKitHandler.available_kits(@export_dir)

    for kit <- kits, do: {:ok, _installed} = UiKitHandler.install_kit!(kit.path, site_id: nil)

    rows =
      Component
      |> Ash.Query.filter(is_nil(site_id))
      |> Ash.Query.load([:component_module, :site])
      |> Ash.read!(authorize?: false, page: false)

    Map.merge(context, %{kits: kits, rows: rows})
  end

  defp bundled(kit), do: kit.path |> File.read!() |> Jason.decode!() |> Map.fetch!("components")

  # `Component` slugifies the name it stores: `chelekom_headless-tree` is `chelekom-headless-tree`.
  defp installed_name(name), do: String.replace(name, "_", "-")

  defp build(row) do
    with {:ok, ast} <-
           ModuleCompilerHandler.get_data_from_database_to_ast(
             {{Atom.to_string(row.component_module), row}, %{}}
           ),
         {:ok, module, _diagnostics} <- ModuleCompiler.compile_module(ast) do
      {:ok, module}
    end
  end

  describe "every component of every kit" do
    test "is installed, and compiles", %{kits: kits, rows: rows} do
      assert kits != []
      by_name = Map.new(rows, &{&1.name, &1})

      for kit <- kits do
        names = kit |> bundled() |> Enum.map(&installed_name(&1["name"]))

        assert length(names) == kit.components
        assert Enum.all?(names, &Map.has_key?(by_name, &1)), "#{kit.name} is not all installed"

        failed =
          for name <- names,
              result = build(Map.fetch!(by_name, name)),
              not match?({:ok, _module}, result),
              do: {name, result}

        assert failed == [], "#{kit.name}: #{length(failed)} did not compile: #{inspect(failed)}"
      end
    end

    test "both Chelekom kits are there, at their full size", %{kits: kits} do
      sizes = Map.new(kits, &{&1.name, &1.components})

      assert sizes["chelekom"] == 136
      assert sizes["chelekom_headless"] == 109
    end
  end

  describe "an atom attribute whose values arrive as strings" do
    setup %{rows: rows} do
      alert = Enum.find(rows, &(&1.name == "chelekom-alert"))
      :ok = SiteState.put_component(nil, "chelekom-alert")
      :ok = SiteState.put_component(nil, "chelekom-badge")

      on_exit(fn ->
        SiteState.delete_component(nil, "chelekom-alert")
        SiteState.delete_component(nil, "chelekom-badge")
      end)

      %{alert: alert}
    end

    test "declares its values and its default as atoms", %{alert: alert} do
      {:ok, module} = build(alert)
      %{attrs: attrs} = module.__components__() |> Map.values() |> hd()
      kind = Enum.find(attrs, &(&1.name == :kind))

      assert :danger in kind.opts[:values]
      assert kind.opts[:default] == :natural
    end

    test "kind=\"danger\" in content draws the danger colour, and another kind another" do
      danger = draw(~s([[component chelekom-alert kind="danger" title="Oops"]]Body[[/component]]))
      info = draw(~s([[component chelekom-alert kind="info" title="FYI"]]Body[[/component]]))

      assert danger =~ "bg-danger-light"
      refute danger =~ "bg-info-light"
      assert info =~ "bg-info-light"
    end
  end

  describe "an open attribute" do
    test "takes a class string of the author's own", %{rows: rows} do
      badge = Enum.find(rows, &(&1.name == "chelekom-badge"))

      assert %{size: "leading-5 py-2 px-4"} =
               ContentComponents.cast(badge.attrs, %{"size" => "leading-5 py-2 px-4"})

      assert %{size: "small"} = ContentComponents.cast(badge.attrs, %{"size" => "small"})
    end

    test "draws the class string it is given", %{rows: _rows} do
      :ok = SiteState.put_component(nil, "chelekom-badge")
      on_exit(fn -> SiteState.delete_component(nil, "chelekom-badge") end)

      html = draw(~s([[component chelekom-badge size="leading-5 py-2 px-4"]]New[[/component]]))

      assert html =~ "leading-5 py-2 px-4"
    end
  end

  # The headless button dispatches on the attributes it is given — `%{navigate: _}`, `%{patch: _}`
  # and `%{href: href} when is_binary(href)` draw a link, anything else a `<button>` — so a marker
  # that writes none of them draws the button.
  describe "a headless button in content" do
    setup do
      for name <- ~w(chelekom-headless-button chelekom-headless-button-content) do
        :ok = SiteState.put_component(nil, name)
        on_exit(fn -> SiteState.delete_component(nil, name) end)
      end

      :ok
    end

    test "written with a label alone is a button" do
      html = draw(~s([[component chelekom-headless-button label="Save" /]]))

      assert html |> query("button.chelekom-button") |> Enum.count() == 1
      assert html |> query("a") |> Enum.count() == 0
    end

    test "written with navigate, patch or href is a link to it" do
      for attr <- ~w(navigate patch href) do
        html = draw(~s([[component chelekom-headless-button label="Docs" #{attr}="/docs" /]]))

        assert html |> query("a.chelekom-button") |> LazyHTML.attribute("href") == ["/docs"],
               "#{attr}: #{html}"

        assert html |> query("button") |> Enum.count() == 0
      end
    end
  end

  describe "a list or a map attribute in content, written as JSON" do
    setup do
      for name <-
            ~w(chelekom-headless-tree chelekom-headless-table chelekom-headless-sparkline chelekom-headless-segmented-control chelekom-headless-countdown) do
        :ok = SiteState.put_component(nil, name)
        on_exit(fn -> SiteState.delete_component(nil, name) end)
      end

      :ok
    end

    test "a tree draws its nodes, their children and the ones it opens" do
      nodes =
        ~s([{"value":"src","label":"src","children":[{"value":"app","label":"app.ex"},{"value":"web","label":"web"}]},{"value":"mix","label":"mix.exs"}])

      html =
        draw(
          ~s(<p>[[component chelekom-headless-tree id="t1" nodes='#{nodes}' expanded='["src"]' /]]</p>)
        )

      drawn(html)
      items = query(html, ~s(li[role="treeitem"]))

      assert html |> query(~s(ul[role="tree"])) |> LazyHTML.attribute("id") == ["content-0"]
      assert LazyHTML.attribute(items, "data-value") == ["src", "app", "web", "mix"]

      assert html |> query(~s([data-part="label-text"])) |> Enum.map(&text/1) ==
               ["src", "app.ex", "web", "mix.exs"]

      assert html |> query(~s(li[data-value="src"])) |> LazyHTML.attribute("aria-expanded") ==
               ["true"]

      assert html |> query(~s(ul[role="tree"])) |> LazyHTML.attribute("data-expanded-values") ==
               [~s(["src"])]
    end

    test "a table draws a row for each of its rows, under its columns" do
      rows = ~s([{"id":1,"name":"mix.exs"},{"id":2,"name":"README.md"},{"id":3,"name":"lib"}])

      html =
        draw(
          ~s([[component chelekom-headless-table caption="Files" rows='#{rows}']]) <>
            ~s([[slot col label="Name" key="name"]]a file[[/slot]][[slot col label="Size"]]1 KB[[/slot]]) <>
            ~s([[/component]])
        )

      drawn(html)

      assert html |> query("thead th") |> Enum.map(&text/1) == ["Name", "Size"]
      assert html |> query("tbody tr") |> Enum.count() == 3

      assert html |> query("tbody td") |> Enum.map(&text/1) ==
               List.flatten(List.duplicate(["a file", "1 KB"], 3))

      assert html |> query("caption") |> Enum.map(&text/1) == ["Files"]
    end

    test "a sparkline plots its values, as a line and as bars" do
      line = draw(~s([[component chelekom-headless-sparkline values='[3,5,2,8,6]' /]]))

      drawn(line)
      [d] = line |> query(~s(path[fill="none"])) |> LazyHTML.attribute("d")

      assert d =~ ~r/\AM [\d.]+ [\d.]+( L [\d.]+ [\d.]+){4}\z/

      bars =
        draw(~s([[component chelekom-headless-sparkline values='[3,5,2,8,6]' type="bar" /]]))

      assert bars |> query("rect") |> Enum.count() == 5
    end

    test "a segmented control draws a segment for each option, the chosen one checked" do
      html =
        draw(
          ~s([[component chelekom-headless-segmented-control name="range" options='["Day","Week","Month"]' value="Week" /]])
        )

      drawn(html)
      inputs = query(html, ~s(input[type="radio"]))

      assert LazyHTML.attribute(inputs, "value") == ["Day", "Week", "Month"]
      assert html |> query("input[checked]") |> LazyHTML.attribute("value") == ["Week"]

      assert html |> query(~s([data-part="label"])) |> Enum.map(&text/1) ==
               ["Day", "Week", "Month"]
    end

    test "a countdown shows the units it is given, under the labels it is given" do
      html =
        draw(
          ~s([[component chelekom-headless-countdown seconds="93784" show_labels units='["days","hours"]' labels='{"days":"d","hours":"h"}' /]])
        )

      drawn(html)

      assert html |> query(~s([data-part="digit"])) |> Enum.map(&text/1) == ["1", "2"]
      assert html |> query(~s([data-part="label"])) |> Enum.map(&text/1) == ["d", "h"]
    end
  end

  # Drawn by the component itself, not as the box a raise is drawn as.
  defp drawn(html) do
    assert html |> query(~s([data-role="component-crashed"])) |> Enum.count() == 0, html
    html
  end

  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp draw(html) do
    %{html: html, site: nil}
    |> LiveViewHelpers.rich_content()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
