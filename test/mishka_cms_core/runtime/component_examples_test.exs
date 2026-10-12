defmodule MishkaCmsCoreWeb.Runtime.ComponentExamplesTest do
  @moduledoc """
  A component can't render on its own (its template needs attrs), so the Component **Preview** tab
  renders ALL of its `examples` (self-contained `<.component … site="Global" …/>` invocations),
  stacked one per line and styled with a real site's CSS bundle. There is no separate Examples tab.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  import Phoenix.LiveViewTest
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.PageBuilder.Icons
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.Resources.Embeddeds.Helper
  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal

  describe "RuntimePreview.render_example/2" do
    test "renders a self-contained snippet to a full standalone document" do
      {doc, note} = RuntimePreview.render_example(~S|<div class="x">hi {"there"}</div>|)

      assert note == nil
      assert String.downcase(doc) =~ "<!doctype html>"
      assert doc =~ ~s(class="x")
      assert doc =~ "hi there"
    end

    # In a `<style>` of their own right after the chrome's, so their layer order precedes any a
    # stylesheet row or the browser generator declares.
    test "carries its icons layered, ahead of the stylesheet rows and the generator" do
      {doc, _note} = RuntimePreview.render_example(~S|<span class="hero-bell size-3"></span>|)

      styles =
        doc
        |> LazyHTML.from_document()
        |> LazyHTML.query("head style")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert [_chrome, icons | _rest] = styles
      assert String.starts_with?(icons, Icons.layer_order() <> "\n@layer components{")
      assert icons =~ ".hero-bell{"
    end

    test "invokes the component system for <.component> — missing component degrades, never crashes" do
      {doc, _note} =
        RuntimePreview.render_example(
          ~S|<.component component_name="does_not_exist_xyz" site="Global" />|
        )

      assert doc =~ "failed to render" or doc =~ "does_not_exist_xyz"
      refute doc =~ "<.component"
    end
  end

  describe "RuntimePreview.render_document/2 for a Component (Preview tab)" do
    test "renders ALL examples stacked (not the bare template, never a missing-assign error)" do
      record =
        struct(Component,
          name: "chelekom-x",
          site: %{name: "Global"},
          # the bare template needs @variant — rendering it directly would raise KeyError
          template: ~S|<div class="bare">{@variant}</div>|,
          examples: [
            ~S|<div class="ex-one">hello {"world"}</div>|,
            ~S|<div class="ex-two">second {"example"}</div>|
          ]
        )

      {doc, note} = RuntimePreview.render_document(record, Component)

      assert note == nil
      refute doc =~ "KeyError"
      refute doc =~ ~s(class="bare")
      # both examples rendered, stacked (two wrappers, no per-example box/border)
      assert doc =~ "hello world"
      assert doc =~ "second example"
      assert length(String.split(doc, ~s(class="mishka-preview-example"))) - 1 == 2
      refute doc =~ "border-bottom:1px solid"
    end

    test "shows a graceful note when a component has no examples" do
      record =
        struct(Component,
          name: "chelekom-y",
          site: %{name: "Global"},
          template: ~S|<div>{@variant}</div>|,
          examples: []
        )

      {doc, note} = RuntimePreview.render_document(record, Component)

      assert note == "no example"
      refute doc =~ "KeyError"
      assert doc =~ "no example"
    end
  end

  describe "examples are narrowed to the options the install actually kept" do
    @bundle_path MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

    # A real kit component, narrowed the way the installer narrows one: `filter_helpers/2` drops
    # every helper clause the selection rules out, so the record's surviving
    # `helpers[].discriminators` ARE the installed option universe.
    setup do
      component = kit_component_with_variants()
      variants = UiKitHandler.component_features(component)["variant"]

      installed_variant = hd(variants)
      helpers = narrow_helpers(component, installed_variant)
      installed = UiKitHandler.component_features(%{"helpers" => helpers})

      missing_variant = Enum.find(variants, &(&1 not in installed["variant"]))

      assert missing_variant,
             "narrowing #{component["name"]} to #{installed_variant} kept every variant — " <>
               "no scenario to test"

      %{
        component: component,
        installed_variant: installed_variant,
        missing_variant: missing_variant,
        helpers: Enum.map(helpers, &struct(Helper, discriminators: &1["discriminators"]))
      }
    end

    defp kit_component_with_variants do
      @bundle_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("components")
      |> Enum.find(fn c ->
        length(UiKitHandler.component_features(c)["variant"] || []) > 1
      end)
    end

    # Mirrors the installer: keep a helper unless one of its `variant` clauses excludes the pick.
    defp narrow_helpers(component, installed_variant) do
      Enum.filter(component["helpers"], fn helper ->
        Enum.all?(helper["discriminators"] || [], fn clause ->
          clause["axis"] != "variant" or installed_variant in clause["values"]
        end)
      end)
    end

    defp example(tag, requires, opts \\ []) do
      %{
        "source" => ~s|<div class="ex-#{tag}">example #{tag}</div>|,
        "label" => tag,
        "section" => tag,
        "base" => Keyword.get(opts, :base, false),
        "requires" => requires
      }
    end

    defp record(rich, overrides) do
      struct(
        Component,
        Keyword.merge(
          [
            name: "chelekom-x",
            site: %{name: "Global"},
            template: ~S|<div class="bare">{@variant}</div>|,
            examples: Enum.map(rich, & &1["source"]),
            extra: %{"ui_kit" => "chelekom", "examples" => rich}
          ],
          overrides
        )
      )
    end

    test "an example whose variant was never installed is dropped; the base survives", ctx do
      rich = [
        example("base-card", %{}, base: true),
        example("kept", %{"variant" => [ctx.installed_variant]}),
        example("dropped", %{"variant" => [ctx.missing_variant]})
      ]

      {doc, note} =
        rich |> record(helpers: ctx.helpers) |> RuntimePreview.render_document(Component)

      assert note == nil
      assert doc =~ "example base-card"
      assert doc =~ "example kept"
      refute doc =~ "example dropped"
      # only the renderable examples are stacked — one wrapper each
      assert length(String.split(doc, ~s(class="mishka-preview-example"))) - 1 == 2
    end

    test "a multi-axis `requires` needs EVERY axis installed", ctx do
      color = hd(UiKitHandler.component_features(ctx.component)["color"])

      rich = [
        example("base-card", %{}, base: true),
        example("both-ok", %{"variant" => [ctx.installed_variant], "color" => [color]}),
        example("one-missing", %{"variant" => [ctx.missing_variant], "color" => [color]})
      ]

      {doc, _note} =
        rich |> record(helpers: ctx.helpers) |> RuntimePreview.render_document(Component)

      assert doc =~ "example both-ok"
      refute doc =~ "example one-missing"
    end

    test "`requires.components` is a sibling list, not an option axis", ctx do
      rich = [
        example("nests-siblings", %{
          "variant" => [ctx.installed_variant],
          "components" => ["#{ctx.component["name"]}-media"]
        })
      ]

      {doc, _note} =
        rich |> record(helpers: ctx.helpers) |> RuntimePreview.render_document(Component)

      assert doc =~ "example nests-siblings"
    end

    test "a component with no discriminators filters nothing out", ctx do
      rich = [
        example("base-card", %{}, base: true),
        example("variant-example", %{"variant" => [ctx.missing_variant]})
      ]

      {doc, _note} = rich |> record(helpers: []) |> RuntimePreview.render_document(Component)

      assert doc =~ "example base-card"
      assert doc =~ "example variant-example"
    end

    test "the base example is shown rather than nothing when narrowing rules every example out",
         ctx do
      rich = [
        example("base-card", %{"variant" => [ctx.missing_variant]}, base: true),
        example("dropped", %{"variant" => [ctx.missing_variant]})
      ]

      {doc, note} =
        rich |> record(helpers: ctx.helpers) |> RuntimePreview.render_document(Component)

      assert note == nil
      assert doc =~ "example base-card"
      refute doc =~ "example dropped"
      assert length(String.split(doc, "margin-bottom:20px")) - 1 == 1
    end

    test "with no base flagged, a fully-narrowed component still falls back to a flat example",
         ctx do
      rich = [
        example("first", %{"variant" => [ctx.missing_variant]}),
        example("second", %{"variant" => [ctx.missing_variant]})
      ]

      {doc, note} =
        rich |> record(helpers: ctx.helpers) |> RuntimePreview.render_document(Component)

      assert note == nil
      assert doc =~ "example first"
      refute doc =~ "example second"
    end

    test "an older bundle without `extra.examples` keeps rendering its flat examples", ctx do
      rich = [example("kept", %{"variant" => [ctx.missing_variant]})]

      {doc, note} =
        rich
        |> record(helpers: ctx.helpers, extra: %{"ui_kit" => "chelekom"})
        |> RuntimePreview.render_document(Component)

      assert note == nil
      assert doc =~ "example kept"
    end

    test "the live draft preview (inner_html/3) narrows the same way", ctx do
      rich = [
        example("base-card", %{}, base: true),
        example("dropped", %{"variant" => [ctx.missing_variant]})
      ]

      html =
        rich |> record(helpers: ctx.helpers) |> RuntimePreview.inner_html(Component)

      assert html =~ "example base-card"
      refute html =~ "example dropped"
    end
  end

  describe "preview modal has no Examples tab" do
    # Merged onto the real shape rather than a copy of it: a copy goes stale the moment a key is
    # added to the modal, and fails as a KeyError from the template instead of a behaviour.
    defp state(overrides) do
      PreviewHelpers.empty()
      |> Map.put(:resource, Component)
      |> Map.put(:active_tab, "preview")
      |> Map.merge(Map.new(overrides))
    end

    test "the Component Overview shows the Details + Performance Metrics layout" do
      record =
        struct(Component,
          id: "comp-2",
          name: "chelekom-button",
          site: %{name: "Global"},
          type: "general",
          format: :heex,
          priority: 92,
          active: true,
          dependencies: ["chelekom-icon"],
          inserted_at: ~U[2026-01-01 10:00:00Z],
          updated_at: ~U[2026-01-02 10:00:00Z]
        )

      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview:
            state(%{record: record, active_tab: "overview", details: [], file_size: "8.7 KB"})
        )

      assert html =~ "Component Details"
      assert html =~ "Performance Metrics"
      assert html =~ "general"
      assert html =~ "HEEX"
      assert html =~ "92"
      assert html =~ "Dynamic"
      assert html =~ "Bundle Size"
      assert html =~ "8.7 KB"
      assert html =~ "chelekom-icon"
    end

    test "the modal never offers an Examples tab (examples live in Preview now)" do
      record =
        struct(Component,
          id: "comp-1",
          name: "chelekom-thing",
          site: %{name: "Global"},
          type: "general",
          dependencies: [],
          examples: [~S|<.component component_name="chelekom-thing" site="Global" />|]
        )

      html = render_component(&RuntimePreviewModal.modal/1, preview: state(%{record: record}))

      refute html =~ ~s(phx-value-tab="examples")
      refute html =~ "component-example-"
      # the standard tabs are present
      assert html =~ ~s(phx-value-tab="preview")
    end
  end
end
