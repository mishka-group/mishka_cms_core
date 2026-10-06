defmodule MishkaCmsCore.Runtime.Compilers.StatefulComponentShapeTest do
  @moduledoc """
  Which module shape a stateful runtime component has to be compiled into, established by rendering
  each candidate rather than by reasoning about it.

  It is settled here rather than in the emitter, because the decision is not guessable: three of the
  four shapes anybody would write fail, each in a different way, and two of them fail only once a
  real parent renders them. Nothing here compiles a component — these are hand-written stand-ins
  for what `ComponentCompiler` will emit — so this is the acceptance criterion for that emitter,
  written before it.

  ## What a compiled component has to satisfy at once

  A kit component declares `attr`s (71 of 74 sources declare `attr :rest, :global`), its template
  reads `@rest` and `@label`, and a stateful one additionally has a lifecycle that computes assigns
  the template reads — `@n` below. So one module must give the template every declared attr, the
  author's own globals, and its own state, and must keep LiveView's injected `socket`, `myself` and
  `flash` out of the markup.

  ## Why `Phoenix.Component.Declarative` cannot be left to do it

  Its generated wrapper computes the `:global` attr by SUBTRACTION: `Map.split(assigns, declared)`
  and everything else becomes `:rest`. For a function component that is right, because the caller's
  assigns are all there is. A `LiveComponent`'s `render/1` is called with the SOCKET's assigns, so
  the subtraction also captures the lifecycle's own state and the four keys LiveView injects.
  """
  use MishkaCmsCore.ConnCase, async: true

  @moduletag :unit

  import Phoenix.LiveViewTest

  # WHAT THE COMPILED MODULE WILL DO. The bridge keeps the declarations, so a parent still gets attr
  # defaults, validation and change tracking; `render/1` carries no declarations, so nothing is ever
  # swept; and `:rest` is assigned EXPLICITLY from the keys the parent sent minus the declared ones,
  # which is information the lifecycle has and subtraction-from-the-socket does not.
  defmodule Explicit do
    use Phoenix.LiveComponent

    @declared [:label, :rest]
    @injected [:__changed__, :__given__, :flash, :myself, :socket, :id]

    attr(:label, :string, default: "hi")
    attr(:rest, :global)

    def label(assigns) do
      ~H"""
      <div {@rest}>{@label}</div>
      """
    end

    def mount(socket), do: {:ok, Phoenix.Component.assign(socket, :n, 0)}

    def update(assigns, socket) do
      given = Map.drop(assigns, @injected)

      {:ok,
       socket
       |> Phoenix.Component.assign(Map.take(given, @declared))
       |> Phoenix.Component.assign(:id, assigns[:id])
       |> Phoenix.Component.assign(:rest, Map.drop(given, @declared))}
    end

    def render(assigns) do
      ~H"""
      <div data-n={@n} {@rest}>{@label}/{@n}</div>
      """
    end
  end

  # THE OBVIOUS SHAPE: declarations on `render/1`.
  defmodule OnRender do
    use Phoenix.LiveComponent

    def mount(socket), do: {:ok, Phoenix.Component.assign(socket, :n, 0)}

    attr(:label, :string, default: "hi")
    attr(:rest, :global)

    def render(assigns) do
      ~H"""
      <div data-n={@n} {@rest}>{@label}/{@n}</div>
      """
    end
  end

  # TAKING THEM OFF `render/1`: declarations on the bridge, `render/1` bare and nothing else.
  defmodule BareRender do
    use Phoenix.LiveComponent

    attr(:label, :string, default: "hi")
    attr(:rest, :global)

    def label(assigns) do
      ~H"""
      <div {@rest}>{@label}</div>
      """
    end

    def mount(socket), do: {:ok, Phoenix.Component.assign(socket, :n, 0)}

    def render(assigns) do
      ~H"""
      <div data-n={@n} {@rest}>{@label}/{@n}</div>
      """
    end
  end

  # AND DELEGATING TO THE BRIDGE, which looks like it should restore the wrapper's work.
  defmodule Delegating do
    use Phoenix.LiveComponent

    attr(:label, :string, default: "hi")
    attr(:rest, :global)

    def label(assigns) do
      ~H"""
      <div data-n={@n} {@rest}>{@label}/{@n}</div>
      """
    end

    def mount(socket), do: {:ok, Phoenix.Component.assign(socket, :n, 0)}

    def render(assigns), do: label(assigns)
  end

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket),
      do: {:ok, Phoenix.Component.assign(socket, :mod, session["mod"])}

    def render(assigns) do
      ~H"""
      <div id="host">
        <.live_component module={@mod} id="probe" label="written" data-author="kept" />
      </div>
      """
    end
  end

  defp render_with(mod) do
    {:ok, _view, html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host, session: %{"mod" => mod})

    {:ok, html}
  rescue
    error -> {:raised, Exception.message(error)}
  end

  describe "the shape a stateful component compiles into" do
    test "gives the template its declared attrs, the author's globals and its own state" do
      assert {:ok, html} = render_with(Explicit)

      assert html =~ "written/0", "the declared attr and the lifecycle assign are both readable"
      assert html =~ ~s(data-n="0"), "the lifecycle assign reached render/1"
      assert html =~ ~s(data-author="kept"), "the author's own global survived into @rest"
    end

    # NOTHING OF LIVEVIEW'S REACHES THE MARKUP. This is the half that fails silently rather than
    # loudly — a page that renders with `n="0"` and `myself="1"` on the tag looks fine until
    # somebody reads the HTML.
    test "and keeps the lifecycle's state and LiveView's own keys out of the markup" do
      assert {:ok, html} = render_with(Explicit)

      refute html =~ ~s( n="0"), "the lifecycle assign leaked through @rest"

      for leaked <- ~w(myself= flash= socket=) do
        refute html =~ leaked, "#{leaked} reached the DOM"
      end
    end
  end

  # EACH OF THESE IS A SHAPE SOMEBODY WILL WRITE, and each fails for its own reason. Pinned so that
  # the emitter cannot quietly become one of them.
  describe "the shapes that do not work" do
    # `Map.split` against the SOCKET's assigns sweeps the lifecycle's state into the global attr,
    # so `@n` is gone from where the template looks for it and is rendered as an HTML attribute
    # instead.
    test "declarations on render/1 lose the lifecycle's assigns to the global attr" do
      assert {:raised, message} = render_with(OnRender)
      assert message =~ "key :n not found"
      assert message =~ "rest:"
      assert message =~ "n: 0", "`n` was swept into :rest, which is the whole failure"
    end

    # MOVING THE DECLARATIONS TO THE BRIDGE, and it does not work: with none on `render/1` there is
    # no wrapper, which is what moving them was for — but the wrapper is also the only thing that
    # was building `:rest`, and 71 of 74 kit templates read it.
    test "a bare render/1 never gets a :rest to read" do
      assert {:raised, message} = render_with(BareRender)
      assert message =~ "key :rest not found"
    end

    # Delegating puts the wrapper back, and with it the sweep.
    test "delegating to the bridge is the same failure as declaring on render/1" do
      assert {:raised, message} = render_with(Delegating)
      assert message =~ "key :n not found"
    end
  end
end
