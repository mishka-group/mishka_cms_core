defmodule MishkaCmsCore.UiKit.ExportedLiveComponentTest do
  @moduledoc """
  A live component written as a UI-kit source, exported by the kit, installed here, compiled and
  clicked.

  ## What this covers that the other stateful tests do not

  `MishkaCmsCore.UiKit.StatefulInstallTest` writes its bundle by hand, and
  `MishkaCmsCore.Runtime.StatefulComponentTest` builds its compiler params by hand. Both prove this
  side of the boundary works when handed the right shape. Neither says anything about whether the
  kit exporter PRODUCES that shape — which is where this feature was open: nothing wrote `stateful`
  into a bundle, `use Phoenix.LiveComponent` was spliced into the generated module's prelude, and
  every live component in a kit was named `<kit>-render`.

  ## The fixture

  `test/fixtures/cms_v3_live_seed.json` is output, not hand-writing. It was produced by running the
  Chelekom-side `MishkaChelekom.CmsBundleExporter.convert/5` over
  `test/fixtures/cms_bundle/sample_live_counter.{exs,eex}` in the `mishka_chelekom` repository, with
  kit name `livekit`. Regenerate it the same way if the exporter's shape changes; a hand-edit here
  would defeat the only thing this file is for.

  The source it came from is a plain `Phoenix.LiveComponent`: `mount/1` seeds a count,
  `handle_event/3` raises it by a declared `step`, a `defp` picks a class from the count, and the
  template targets `@myself`.

  `async: false` — installs write global runtime rows and compiled modules live in the VM's code
  table.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2, live_component: 1]
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler, as: Installer
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.LiveViewHelpers

  require Ash.Query

  @moduletag :integration

  @bundle_path Path.expand("../../fixtures/cms_v3_live_seed.json", __DIR__)
  @name "livekit-sample-live-counter"

  setup do
    Installer.uninstall_kit!(@bundle_path)
    {:ok, _installed} = Installer.install_kit!(@bundle_path)
    on_exit(fn -> Installer.uninstall_kit!(@bundle_path) end)
    :ok
  end

  defp row do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^@name)
    |> Ash.read_one!()
  end

  defp loaded_module do
    assert LiveViewHelpers.ensure_component_loaded(@name, nil),
           "the installed row did not compile"

    Helpers.module_name(@name, nil, "Component")
  end

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket),
      do: {:ok, Phoenix.Component.assign(socket, :mod, session["mod"])}

    def render(assigns) do
      ~H"""
      <div id="host">
        <.live_component module={@mod} id="counter-one" size="large" step={2} data-kept="yes" />
        <.live_component module={@mod} id="counter-two" size="small" />
      </div>
      """
    end
  end

  defp mount_host(module),
    do: live_isolated(Phoenix.ConnTest.build_conn(), Host, session: %{"mod" => module})

  defp counts(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#counter-one span, #counter-two span")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "a live component the kit exporter produced" do
    test "installs as a live component, under its own name" do
      assert component = row()
      assert component.stateful == true

      refute Component
             |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
             |> Ash.Query.filter(name == "livekit-render")
             |> Ash.read_one!(),
             "the row was named after render/1, so a kit of these would upsert over each other"
    end

    # The exporter drops `use Phoenix.LiveComponent` from the prelude because this CMS emits
    # `use <Web>, :live_component` itself. Left in, the generated module says both and does not
    # compile — so a prelude carrying it is a component that can never be drawn.
    test "carries no `use` line of its own, and compiles" do
      refute to_string(row().extra["prelude"]) =~ "Phoenix.LiveComponent"

      assert loaded_module().__component_information__([:private, :stateful]) == true
    end

    test "its lifecycle rode the bundle as helpers" do
      names = Enum.map(row().helpers, & &1.name)

      assert "mount" in names
      assert "handle_event" in names
      assert "counter_class" in names, "the private helper the template calls"
    end

    test "renders, with the attrs the page passed and the global the author wrote" do
      {:ok, _view, html} = mount_host(loaded_module())

      assert html =~ ~s(data-kept="yes"), "the author's global survived into @rest"
      assert html =~ "large", "the declared attr the page passed"
      assert html =~ "text-zinc-500", "the defp the template calls ran"

      for leaked <- ~w(myself= flash= socket= count=) do
        refute html =~ leaked, "#{leaked} reached the DOM through @rest"
      end
    end

    # THE WHOLE POINT OF THE FEATURE, reached from a kit source rather than from hand-built params:
    # a click goes to the COMPONENT, its own state changes, and the other instance does not move.
    test "keeps per-instance state a click changes" do
      {:ok, view, _html} = mount_host(loaded_module())

      assert counts(view) == ["0", "0"]

      view |> element(~s(#counter-one button), "Bump") |> render_click()
      assert counts(view) == ["2", "0"], "the declared `step` the page passed was used"

      view |> element(~s(#counter-two button), "Bump") |> render_click()
      assert counts(view) == ["2", "1"], "the second instance uses its own default step"
    end
  end
end
