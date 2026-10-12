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

    # THE MODULES BUILT HERE ARE NODE-WIDE and outlive the rollback: a later module drawing
    # `chelekom-alert` from its own rows would otherwise be handed this kit's build.
    on_exit(fn -> Enum.each(rows, &ModuleCompiler.unload(&1.component_module)) end)

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

  defp draw(html) do
    %{html: html, site: nil}
    |> LiveViewHelpers.rich_content()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
