defmodule MishkaCmsCoreWeb.Test.PreviewWarmTest do
  @moduledoc """
  What the runtime preview modal does on its way to showing you something.

  Opening the Preview tab warms the record's runtime module, because a Layout or an Error Page has
  no live URL of its own and would otherwise read "Lazy" forever. Both halves of that had holes that
  only showed once components stopped being compiled at boot — when warming became real work rather
  than a lookup that always hit.

  See `MishkaCmsCore.Runtime.LiveViewHelpers` for the render-time half of the same question.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.{Component, Layout}
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers

  # The keys `set_tab/2` touches, in the shape `open/3` assigns them: a freshly-opened modal has no
  # document yet, which is the whole point of the tests below.
  defp socket_with(record, resource) do
    %Phoenix.LiveView.Socket{}
    |> assign(:preview, %{
      record: record,
      resource: resource,
      active_tab: "overview",
      html: nil,
      error: nil,
      rendering?: false
    })
  end

  describe "opening the Preview tab with no record" do
    # A preview opened while the table is still re-reading — a filter typed a keystroke earlier, a
    # row deleted from under the click — resolves to nothing, and the modal says "Nothing selected."
    # The warm-up ran anyway and took the async load process down with a `BadMapError`.
    test "is a no-op rather than a crash" do
      socket = socket_with(nil, Layout)

      assert %{assigns: %{preview: %{active_tab: "preview"}}} =
               PreviewHelpers.set_tab(socket, "preview")
    end

    test "and the other tabs are unaffected" do
      socket = socket_with(nil, Layout)

      assert %{assigns: %{preview: %{active_tab: "code"}}} =
               PreviewHelpers.set_tab(socket, "code")
    end
  end

  describe "opening it with a real record" do
    test "records the tab and leaves an inactive record alone", %{} do
      site = create_site!(name: "warm-#{unique()}", host: "warm-#{unique()}.test")
      layout = create_layout!(site_id: site.id, active: false)

      assert %{assigns: %{preview: %{active_tab: "preview"}}} =
               PreviewHelpers.set_tab(socket_with(layout, Layout), "preview")

      refute Helpers.loaded?(Helpers.module_name(layout.id, site.name, "Layout"))
    end
  end

  describe "which tab builds the preview document" do
    setup do
      n = unique()
      site = create_site!(name: "doc-#{n}", host: "doc-#{n}.test")

      component =
        create_component!(
          site_id: site.id,
          name: "preview-doc-#{n}",
          template: ~s(<b class="doc-probe">rendered</b>),
          examples: [~s(<.component component_name="preview-doc-#{n}" site="#{site.name}" />)],
          precompile: false
        )

      on_exit(fn ->
        component.name
        |> Helpers.module_name(site.name, "Component")
        |> MishkaCmsCore.Runtime.Compilers.ModuleCompiler.unload()
      end)

      %{site: site, component: component}
    end

    # A COMPONENT MUST NOT BECOME "LIVE" BECAUSE SOMEBODY GLANCED AT THE ROW. Rendering the document
    # runs the component, and a component is built by the first thing that renders it — so building
    # the document on modal open compiled it, and the Pipeline tab then reported "Live" about a
    # component nothing had ever rendered.
    test "not Overview: no document, and nothing compiled", %{site: site, component: component} do
      socket = PreviewHelpers.set_tab(socket_with(component, Component), "overview")

      assert socket.assigns.preview.html == nil
      refute Helpers.loaded?(Helpers.module_name(component.name, site.name, "Component"))
    end

    # THE TAB OPENS FIRST. Building the document renders the component for real, which for one that
    # has never been built means compiling it — so doing that inline left the author staring at the
    # tab they had just left, with nothing to say why.
    test "the Preview tab switches at once and marks itself rendering", %{component: component} do
      socket = PreviewHelpers.set_tab(socket_with(component, Component), "preview")

      assert socket.assigns.preview.active_tab == "preview",
             "the tab must not wait for the render"

      assert socket.assigns.preview.rendering?
      assert socket.assigns.preview.html == nil
    end

    test "and the document lands when the render returns" do
      socket =
        %Phoenix.LiveView.Socket{}
        |> assign(:preview, %{
          record: %{},
          resource: Component,
          active_tab: "preview",
          html: nil,
          error: nil,
          rendering?: true
        })
        |> PreviewHelpers.loaded({:ok, {:document, "<b>doc-probe</b>", nil}})

      assert socket.assigns.preview.html == "<b>doc-probe</b>"
      refute socket.assigns.preview.rendering?
    end

    # Built once. Re-visiting the tab must not start a second render of what is already there, and
    # leaving and returning mid-flight must not start a second one either.
    test "it is not rebuilt on a second visit", %{component: component} do
      built =
        socket_with(component, Component)
        |> then(&assign(&1, :preview, %{&1.assigns.preview | html: "<b>already</b>"}))
        |> PreviewHelpers.set_tab("preview")

      refute built.assigns.preview.rendering?
      assert built.assigns.preview.html == "<b>already</b>"
    end

    test "and no second render is started while one is in flight", %{component: component} do
      in_flight =
        socket_with(component, Component)
        |> then(&assign(&1, :preview, %{&1.assigns.preview | rendering?: true}))
        |> PreviewHelpers.set_tab("preview")

      assert in_flight.assigns.preview.rendering?
      assert in_flight.assigns.preview.html == nil
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
