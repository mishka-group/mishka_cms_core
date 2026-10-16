# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.StatefulPreviewSurfacesTest do
  @moduledoc """
  The surfaces that render a runtime template to a STRING, and what they do with a live component.

  ## What was wrong

  Calling a stateful component builds a `%Phoenix.LiveView.Component{}`, which only a LiveView's
  diff turns into HTML — asked for iodata it raises "cannot convert component … to HTML". Four
  surfaces render to a string and hand it somewhere that is not a LiveView: the admin's Preview tab
  and its version previews, the palette's card thumbnails, the examples encoder, and the public
  draft-preview URL. Every one of them showed that sentence instead of a picture.

  ## Why one import is the whole fix

  `LiveViewCompiler.render_template/2` builds its own eval environment, and that environment is OUR
  code rather than a generated module — so which dispatch a template gets is decided by the caller's
  import list, and nothing a kit or an author writes can reach past it.
  `MishkaCmsCore.Runtime.StaticHelpers` renders the component's own markup cold; a compiled page
  module still imports the live `LiveViewHelpers`, because a published page IS a LiveView and must
  get the real thing.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Translations

  @moduletag :integration

  setup do
    SiteState.clear()
    n = System.unique_integer([:positive])
    site = create_site!(name: "surface#{n}", host: "surface#{n}.test", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> SiteState.clear() end)

    create_component!(
      name: "surface-live",
      site_id: site.id,
      stateful: true,
      template: ~s(<div id={@id} {@rest} data-role="surfaced">{@label}</div>),
      attrs: [
        %{"name" => "label", "type" => "string", "opts" => %{"default" => "cold"}},
        %{"name" => "rest", "type" => "global", "opts" => %{}}
      ],
      helpers: [
        %{
          "name" => "mount",
          "args" => "socket",
          "code" => "{:ok, Phoenix.Component.assign(socket, :n, 0)}"
        }
      ]
    )

    assert LiveViewHelpers.ensure_component_loaded("surface-live", site.name)

    # Every surface that renders to a string names the site it renders for, and so does this one —
    # a site's component is drawn only there. See `LiveViewHelpers.component/1`.
    :ok = Translations.put_site(site.id)

    {:ok, site: site}
  end

  defp calls(site, extra \\ "") do
    ~s(<div><.component component_name="surface-live" site="#{site.name}" id="s1"#{extra} /></div>)
  end

  describe "a template rendered to a string" do
    test "draws the live component's own markup rather than an error", %{site: site} do
      result = LiveViewCompiler.render_template(calls(site), %{})

      assert is_binary(result),
             "a string surface refused a live component: #{inspect(result, limit: 3)}"

      assert result =~ ~s(data-role="surfaced")
      assert result =~ ~s(id="s1")
    end

    test "and the attributes the caller set reach it", %{site: site} do
      result = LiveViewCompiler.render_template(calls(site, ~s( label="written")), %{})

      assert result =~ "written"
    end

    # COLD, AND SAYING NOTHING IT CANNOT DO. `@myself` is nil, so a component's own `phx-target`
    # renders away — a preview is a picture of a page, and a picture does not answer clicks.
    test "with no target for its own events", %{site: site} do
      result = LiveViewCompiler.render_template(calls(site), %{})

      refute result =~ "phx-target"
    end

    # AND THE DISPATCH'S OWN KEYS ARE NOT THE COMPONENT'S. `component_name` and `site` are how the
    # template names what it wants; a live component sweeps every undeclared key into its global
    # attr, so both used to be rendered onto its root element.
    test "and the dispatch's own keys are not rendered as attributes", %{site: site} do
      result = LiveViewCompiler.render_template(calls(site), %{})

      refute result =~ "component_name="
      refute result =~ "site="
    end

    # A FUNCTION COMPONENT TAKES THE SAME PATH IT ALWAYS DID.
    test "and a function component is unchanged", %{site: site} do
      create_component!(
        name: "surface-plain",
        site_id: site.id,
        template: ~s(<div data-role="plain">plain</div>)
      )

      result =
        LiveViewCompiler.render_template(
          ~s(<div><.component component_name="surface-plain" site="#{site.name}" /></div>),
          %{}
        )

      assert is_binary(result)
      assert result =~ ~s(data-role="plain")
    end
  end

  describe "the static helpers" do
    # THE EVAL ENVIRONMENT IMPORTS THE WHOLE MODULE, so a function missing from it is a function a
    # template can no longer call — which is how a preview surface breaks silently.
    test "delegate everything a template may reach for" do
      for {name, arity} <- [{:component, 1}, {:component, 3}, {:ensure_component_loaded, 2}] do
        assert function_exported?(MishkaCmsCore.Runtime.StaticHelpers, name, arity),
               "StaticHelpers is missing #{name}/#{arity}, which templates can call"
      end
    end
  end
end
