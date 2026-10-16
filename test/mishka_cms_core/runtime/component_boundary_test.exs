# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ComponentBoundaryTest do
  @moduledoc """
  A component a `[[component …]]` marker names that raises while it draws is drawn as a box, and
  the rest of the page draws — in the HTTP render, in the connected LiveView and in its re-renders,
  and for a marker inside another component's content. A page's own `<.component>` call is not
  wrapped.

  The components are real rows compiled by the runtime on first use, on a site this process renders
  for. `async: false` — `SiteState`, compiled modules and the event registry are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.{ComponentBoundary, CspNonce, LiveViewHelpers, Translations}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.ComponentCrashed

  @moduletag :integration

  @endpoint MishkaCmsCore.TestEndpoint

  @box "[data-role=component-crashed]"

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "boundary-#{n}", host: "boundary-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)
    :ok = Translations.put_site(site.id)

    names = %{
      fine:
        component!(site, "fine-#{n}", ~S|<p class="probe-fine" data-title={@title}>{@title}</p>|),
      boom:
        component!(
          site,
          "boom-#{n}",
          ~S|<div class="probe-boom">{if @explode, do: Map.fetch!(@upload, :entries), else: @title}</div>|,
          [attr("explode", "boolean", false), attr("upload", "any", nil)]
        ),
      broken:
        component!(
          site,
          "broken-#{n}",
          ~S|<div class="probe-broken">{Map.fetch!(@upload, :entries)}</div>|,
          [attr("upload", "any", nil)]
        ),
      example:
        component!(
          site,
          "example-#{n}",
          ~S|<section class="probe-example">{render_slot(@inner_block)}</section>|,
          [],
          [%{"name" => "inner_block", "opts" => %{}}]
        ),
      missing:
        component!(
          site,
          "missing-#{n}",
          ~S|<div>{raise MishkaCmsCore.ErrorsExceptions.NotFoundError, "gone"}</div>|
        ),
      tossed: component!(site, "tossed-#{n}", ~S|<div>{throw(:tossed)}</div>|)
    }

    {:ok, site: site, names: names}
  end

  defp attr(name, type, default),
    do: %{"name" => name, "type" => type, "opts" => %{"default" => default}}

  defp component!(site, name, template, attrs \\ [], slots \\ []) do
    component =
      create_component!(
        name: name,
        template: template,
        attrs: [attr("title", "string", nil) | attrs],
        slots: slots,
        active: true,
        precompile: false,
        site_id: site.id
      )

    :ok = SiteState.put_component(site.id, component.name)
    on_exit(fn -> SiteState.delete_component(site.id, component.name) end)
    component.name
  end

  defp register_plugin(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  defp to_html(rendered), do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defmodule Page do
    use Phoenix.Component

    import MishkaCmsCore.Runtime.LiveViewHelpers, only: [component: 1, rich_content: 1]

    def page(assigns) do
      ~H"""
      <main>
        <.component component_name={@names.fine} site={@site} title="before" />
        <.component component_name={@names.boom} site={@site} explode={true} upload={%{}} />
      </main>
      """
    end

    def content(assigns) do
      ~H"""
      <main><.rich_content id="body" html={@html} site={@site} /></main>
      """
    end
  end

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      :ok = MishkaCmsCore.Runtime.Translations.put_site(session["site_id"])
      {:ok, assign(socket, site: session["site"], html: session["html"])}
    end

    def handle_info({:html, html}, socket), do: {:noreply, assign(socket, :html, html)}

    def render(assigns) do
      ~H"""
      <div id="host"><Page.content html={@html} site={@site} /></div>
      """
    end
  end

  defp mount_page(site, html) do
    {:ok, view, html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"site" => site.name, "site_id" => site.id, "html" => html}
      )

    {view, html}
  end

  defp drawn(site, html) do
    capture_log(fn ->
      send(self(), {:html, to_html(Page.content(%{html: html, site: site.name}))})
    end)

    assert_received {:html, drawn}
    drawn
  end

  defp marker(name, attrs \\ ""), do: "[[component #{name}#{attrs} /]]"

  defp siblings(names, middle) do
    ~s(<p class="probe-intro">Intro</p>) <>
      marker(names.fine, ~s( title="before")) <>
      middle <> marker(names.fine, ~s( title="after")) <> ~s(<p class="probe-outro">After</p>)
  end

  describe "a marker, in the HTTP render" do
    test "draws the box where the component raised, and the content around it", %{
      site: site,
      names: names
    } do
      log =
        capture_log(fn ->
          content = %{html: siblings(names, marker(names.broken)), site: site.name}
          send(self(), {:html, to_html(Page.content(content))})
        end)

      assert_received {:html, html}

      assert count(html, @box) == 1

      assert html |> query(".probe-fine") |> LazyHTML.attribute("data-title") == [
               "before",
               "after"
             ]

      assert count(html, ".probe-intro") == 1
      assert count(html, ".probe-outro") == 1
      assert count(html, ".probe-broken") == 0
      assert html =~ "This component could not be drawn"

      assert log =~ names.broken
      assert log =~ site.name
      assert log =~ "BadMapError"
      assert log =~ ~r/error [0-9a-f]{12}/
      assert log =~ "ComponentBoundary.draw/3"
    end

    test "a component that does not raise is drawn as it always was", %{site: site, names: names} do
      html = drawn(site, siblings(names, marker(names.boom, ~s( title="calm"))))

      assert count(html, @box) == 0
      assert html |> query(".probe-boom") |> LazyHTML.text() == "calm"
      assert count(html, ".probe-fine") == 2
    end

    test "a visitor's box carries no error id; a dashboard admin's does", %{
      site: site,
      names: names
    } do
      ids = fn ->
        site |> drawn(marker(names.broken)) |> query(@box) |> LazyHTML.attribute("data-error-id")
      end

      :ok = CspNonce.put("nonce-#{System.unique_integer([:positive])}")
      on_exit(fn -> CspNonce.put(nil) end)

      :ok = ComponentBoundary.put_viewer(nil)
      assert ids.() == []

      :ok = ComponentBoundary.put_viewer(%{dashboard_admin?: false})
      assert ids.() == []

      :ok = ComponentBoundary.put_viewer(%{dashboard_admin?: true})
      [error_id] = ids.()
      assert error_id =~ ~r/\A[0-9a-f]{12}\z/

      :ok = CspNonce.put("a-later-response")
      assert ids.() == []
    end

    test "the box is drawn with classes only, so a strict CSP allows it", %{
      site: site,
      names: names
    } do
      html = drawn(site, marker(names.broken))
      [box] = html |> query(@box) |> Enum.to_list()

      assert LazyHTML.attribute(box, "style") == []
      assert LazyHTML.attribute(box, "class") == [ComponentBoundary.box_class()]
      refute html =~ "<style"
    end

    test "that raises inside another component's content is boxed there", %{
      site: site,
      names: names
    } do
      html =
        ~s([[component #{names.example}]]<p class="probe-inner">Inside</p>) <>
          marker(names.boom, " explode") <> "[[/component]]"

      drawn = drawn(site, siblings(names, html))

      assert count(drawn, ".probe-example #{@box}") == 1
      assert count(drawn, ".probe-example .probe-inner") == 1
      assert count(drawn, ".probe-fine") == 2
      assert count(drawn, ".probe-outro") == 1
    end
  end

  describe "a marker, in the connected LiveView" do
    test "draws the box and the content around it, and stays up", %{site: site, names: names} do
      {view, html} =
        capture_log_value(fn -> mount_page(site, siblings(names, marker(names.broken))) end)

      assert count(html, @box) == 1
      assert has_element?(view, @box)
      assert has_element?(view, ".probe-fine[data-title=before]")
      assert has_element?(view, ".probe-fine[data-title=after]")
      assert has_element?(view, ".probe-outro")
    end

    test "inside another component's content", %{site: site, names: names} do
      html =
        ~s([[component #{names.example}]]<p class="probe-inner">Inside</p>) <>
          marker(names.boom, " explode") <> "[[/component]]"

      {view, _html} = capture_log_value(fn -> mount_page(site, siblings(names, html)) end)

      assert has_element?(view, ".probe-example #{@box}")
      assert has_element?(view, ".probe-example .probe-inner")
      assert has_element?(view, ".probe-outro")
    end

    test "a re-render whose change makes the component raise is contained", %{
      site: site,
      names: names
    } do
      calm = siblings(names, marker(names.boom, ~s( title="calm")))
      {view, _html} = mount_page(site, calm)
      assert has_element?(view, ".probe-boom", "calm")

      capture_log(fn ->
        send(view.pid, {:html, siblings(names, marker(names.boom, ~s( title="calm" explode)))})
        render(view)
      end)

      assert Process.alive?(view.pid)
      assert has_element?(view, @box)
      assert has_element?(view, ".probe-fine[data-title=before]")
      assert has_element?(view, ".probe-outro")

      capture_log(fn ->
        send(view.pid, {:html, siblings(names, marker(names.boom, ~s( title="changed" explode)))})
        render(view)
      end)

      assert Process.alive?(view.pid)
      assert has_element?(view, @box)

      send(view.pid, {:html, siblings(names, marker(names.boom, ~s( title="changed")))})
      assert has_element?(view, ".probe-boom", "changed")
      refute has_element?(view, @box)
    end
  end

  describe "what it does not contain" do
    test "a page's own <.component> call is not wrapped, and raises as it always did", %{
      site: site,
      names: names
    } do
      rendered =
        LiveViewHelpers.component(%{component_name: names.fine, site: site.name, title: "t"})

      refute :erlang.fun_info(rendered.dynamic, :module) == {:module, ComponentBoundary}

      {error, stacktrace} =
        try do
          to_html(Page.page(%{names: names, site: site.name}))
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert %KeyError{} = error
      refute Enum.any?(stacktrace, &(elem(&1, 0) == ComponentBoundary))
    end

    test "an exception that names a 4xx status is the page's answer, and is raised on", %{
      site: site,
      names: names
    } do
      assert_raise NotFoundError, fn ->
        to_html(Page.content(%{html: marker(names.missing), site: site.name}))
      end
    end

    test "a throw passes through", %{site: site, names: names} do
      assert catch_throw(to_html(Page.content(%{html: marker(names.tossed), site: site.name}))) ==
               :tossed
    end
  end

  describe "runtime:component:crashed" do
    test "a plugin hears the contained raise, with the component, its site and the error", %{
      site: site,
      names: names
    } do
      register_plugin(ComponentCrashed, "runtime:component:crashed")

      drawn(site, marker(names.broken))

      assert_received {:component_crashed, data}
      assert data.component_name == names.broken
      assert data.site == site.name
      assert data.site_id == site.id
      assert %BadMapError{} = data.error
      assert is_list(data.stacktrace)
      assert data.error_id =~ ~r/\A[0-9a-f]{12}\z/
    end

    test "is not fired for a component that draws", %{site: site, names: names} do
      register_plugin(ComponentCrashed, "runtime:component:crashed")

      drawn(site, marker(names.fine))

      refute_received {:component_crashed, _data}
    end
  end

  defp capture_log_value(fun) do
    capture_log(fn -> send(self(), {:value, fun.()}) end)
    assert_received {:value, value}
    value
  end
end
