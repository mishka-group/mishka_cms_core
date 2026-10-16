# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.StatefulComponentTest do
  @moduledoc """
  A component that keeps state between renders, compiled by the real compiler and driven on a real
  page.

  This is the acceptance case for the whole feature rather than a unit test of one stage: the
  component goes through `MishkaCmsCore.Runtime.Compilers.ComponentCompiler`, the page that hosts it
  through `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler`, both through
  `MishkaCmsCore.Runtime.Compilers.ModuleCompiler`, and the page is then rendered and clicked the
  way a visitor would.

  ## What a stateful component buys that a function component structurally cannot

  Per-instance server state that survives the hosting page's re-renders, an event channel of its own
  through `@myself`, and an independent diff. None of it is expressible by a function component at
  any price: a page can hold a counter for it, but then the page owns the state, the page's handler
  has to know the component exists, and two of the same component on one page share one number.

  ## The shape, and why it is not the obvious one

  `MishkaCmsCore.Runtime.Compilers.StatefulComponentShapeTest` establishes it by rendering the four
  candidates. Briefly: the declarations stay on the BRIDGE, `render/1` carries the template and no
  declarations, and `update/2` assigns `:rest` explicitly — because the wrapper that would sweep the
  lifecycle's state into `@rest` is also the only thing that would build `@rest` at all.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2, live_component: 1]
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Compilers.ComponentCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler

  @moduletag :integration

  # A COUNTER IS THE SMALLEST HONEST EXEMPLAR: it reads a declared attr, carries a global the author
  # wrote, holds a number no page assign is keeping, and changes it from its own handler.
  # `id={@id}` IS THE KIT'S OWN LINE, not something the compiler writes. LiveView needs the `id` to
  # identify the component for diffing and does not put it in the DOM; a component that wants to be
  # addressable there says so, exactly as a hand-written LiveComponent would.
  @template """
  <div id={@id} {@rest} data-role="counter">
    <span data-role="label">{@label}</span>
    <span data-role="count">{@count}</span>
    <button type="button" phx-click="bump" phx-target={@myself}>more</button>
    <button type="button" phx-click="undeclared" phx-target={@myself}>noise</button>
  </div>
  """

  defp compile!(params) do
    module = Module.concat([__MODULE__, "C#{System.unique_integer([:positive])}"])

    ast =
      ComponentCompiler.build_module(
        Map.merge(
          %{
            id: Ash.UUID.generate(),
            title: "counter",
            component_module: module,
            site: "Global",
            template: @template,
            attrs: [
              %{name: "label", type: "string", opts: %{default: "Clicks"}},
              %{name: "rest", type: "global", opts: %{}}
            ],
            slots: [],
            helpers: [
              %{
                name: "mount",
                args: "socket",
                code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
              },
              %{
                name: "handle_event",
                args: ~s|"bump", _params, socket|,
                code:
                  "{:noreply, Phoenix.Component.assign(socket, :count, socket.assigns.count + 1)}"
              }
            ],
            stateful: true
          },
          params
        )
      )

    {:ok, ^module, _diagnostics} = ModuleCompiler.compile_module(ast)
    module
  end

  # `:tick` AND `@ticks` EARN THEIR KEEP. A `send/2` to a LiveView with no matching `handle_info/2`
  # is answered by the channel with the socket untouched, nothing is marked changed, and the next
  # `render/1` in the test hands back the tree it already held — so a re-render test written that
  # way asserts nothing at all. This host takes the message and changes an assign its own template
  # reads, which is what makes the parent actually redraw around the components.
  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> Phoenix.Component.assign(:mod, session["mod"])
       |> Phoenix.Component.assign(:ticks, 0)}
    end

    def handle_info(:tick, socket),
      do: {:noreply, Phoenix.Component.update(socket, :ticks, &(&1 + 1))}

    def render(assigns) do
      ~H"""
      <div id="host">
        <span data-role="ticks">{@ticks}</span>
        <.live_component
          module={@mod}
          id="counter-one"
          label="Presses"
          data-author="kept"
        />
        <.live_component module={@mod} id="counter-two" label="Other" />
      </div>
      """
    end
  end

  defmodule DefaultHost do
    use Phoenix.LiveView

    def mount(_params, session, socket),
      do: {:ok, Phoenix.Component.assign(socket, :mod, session["mod"])}

    def render(assigns) do
      ~H"""
      <div id="host">
        <.live_component module={@mod} id="stepped" />
      </div>
      """
    end
  end

  defp mount_host(module) do
    live_isolated(Phoenix.ConnTest.build_conn(), Host, session: %{"mod" => module})
  end

  defp counts(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="count"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "a compiled stateful component" do
    test "says what it is, and the stateless ones say what they are" do
      live = compile!(%{})
      plain = compile!(%{stateful: false, helpers: []})

      assert live.__component_information__([:private, :stateful]) == true
      assert plain.__component_information__([:private, :stateful]) == false
    end

    # AND THE STATEFUL EMITTER DOES NOT REACH THE OTHER 141. Every component installed before this
    # feature reads `stateful: false`, and the one thing that must stay true of them is that they
    # compile to exactly what they compiled to before: a module of plain arity-1 functions with no
    # `Phoenix.LiveComponent` surface on it. The direct proof is a before/after byte comparison,
    # which cannot be taken once the "before" is gone — so it is asked of the shape instead, which
    # is the property that comparison was standing in for.
    test "and a stateless one carries none of the live surface" do
      plain = compile!(%{stateful: false, helpers: []})

      assert plain.__live__().kind == :view,
             "the base a stateless component has always compiled on, unchanged"

      live = compile!(%{})

      assert live.__live__().kind == :component,
             "and the stateful one is the LiveComponent it claims to be"

      assert function_exported?(live, :update_many, 1),
             "and it really does carry the surface the refutations above say the plain one does not"

      refute function_exported?(plain, :update_many, 1),
             "update_many/1 is the stateful bridge and has no business in a function component"

      refute function_exported?(plain, :mount, 1),
             "mount/1 is a LiveComponent callback, not something a function component exports"

      refute function_exported?(plain, :handle_event, 3),
             "an unasked-for handle_event/3 would shadow nothing here and mean the emitter leaked"

      refute Phoenix.LiveComponent in (plain.module_info(:attributes)[:behaviour] || []),
             "the module declared the behaviour it does not implement"

      assert Map.keys(plain.__components__()) == [:counter],
             "and what it IS, still: one named arity-1 function per component"

      assert Enum.sort(plain.__info__(:functions)) == [
               __component_information__: 0,
               __component_information__: 1,
               __components__: 0,
               __live__: 0,
               counter: 1
             ],
             "the whole exported surface of a stateless component — if this list grew, the stateful " <>
               "emitter reached a row that never asked for it"
    end

    test "renders its template, its declared attr and the author's own global" do
      {:ok, _view, html} = mount_host(compile!(%{}))

      assert html =~ "Presses", "the declared attr the parent passed"
      assert html =~ "Other", "and the second instance's own"
      assert html =~ ~s(data-author="kept"), "the global the author wrote survived into @rest"
      assert html =~ ~s(data-role="counter")
    end

    # THE HALF THAT FAILS QUIETLY. Nothing LiveView injects may be rendered as an HTML attribute —
    # a page carrying `myself="1"` and `count="0"` on a tag looks fine until somebody reads it.
    test "and nothing of LiveView's leaks into the markup" do
      {:ok, _view, html} = mount_host(compile!(%{}))

      for leaked <- ~w(myself= flash= socket= count=) do
        refute html =~ leaked, "#{leaked} reached the DOM through @rest"
      end
    end

    # THE WHOLE POINT. A click reaches the COMPONENT's handler through `@myself`, changes state the
    # page knows nothing about, and the other instance does not move.
    test "keeps its own state, per instance, and a click changes only one" do
      {:ok, view, _html} = mount_host(compile!(%{}))

      assert counts(view) == ["0", "0"]

      view |> element(~s(#counter-one button), "more") |> render_click()
      assert counts(view) == ["1", "0"]

      view |> element(~s(#counter-one button), "more") |> render_click()
      view |> element(~s(#counter-two button), "more") |> render_click()
      assert counts(view) == ["2", "1"]
    end

    # AND IT SURVIVES THE PARENT RE-RENDERING, which is the thing a function component cannot do:
    # its state would be recomputed from the parent's assigns every time.
    test "its state survives a re-render of the page holding it" do
      {:ok, view, _html} = mount_host(compile!(%{}))

      view |> element(~s(#counter-one button), "more") |> render_click()
      assert counts(view) == ["1", "0"]

      send(view.pid, :tick)
      redrawn = render(view)

      assert redrawn =~ ~s(<span data-role="ticks">1</span>),
             "the parent never re-rendered, so this proves nothing about surviving one"

      assert counts(view) == ["1", "0"], "the count was rebuilt from the parent's assigns"
    end

    # THE KIT'S OWN `update/2` RUNS. `Phoenix.LiveView.Diff` does
    # `if function_exported?(component, :update_many, 1)` and takes one branch OR the other, so the
    # compiler's `update_many/1` REPLACES `update/2` rather than running before it — a kit that wrote
    # one would have had it silently ignored, which is the worst shape a lifecycle bug can take. The
    # emitted `update_many/1` calls it itself, after the parent's assigns are on the socket.
    test "a kit's own update/2 runs, and sees the parent's assigns already carried across" do
      module =
        compile!(%{
          helpers: [
            %{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            },
            %{
              name: "update",
              args: "_assigns, socket",
              code:
                "{:ok, Phoenix.Component.assign(socket, :count, String.length(socket.assigns.label))}"
            }
          ]
        })

      {:ok, view, _html} = mount_host(module)

      # "Presses" is 7 characters and "Other" is 5 — so the kit's clause ran, and it could read the
      # declared attr the parent passed because that was assigned before it was called.
      assert counts(view) == ["7", "5"]
    end

    # A SLOT IS NOT A GLOBAL ATTRIBUTE, and a caller passes slots the component never declared: the
    # builder's canvas hands every component an `inner_block` whether it takes one or not. Swept into
    # `@rest` it is rendered as an HTML attribute, and a slot is a map — "lists in Phoenix.HTML may
    # only contain integers representing bytes, binaries or other lists". Found on the canvas, where
    # every component gets one; a page that passes none never reaches it.
    test "a slot it never declared reaches render_slot and not @rest" do
      module =
        compile!(%{
          template: """
          <div id={@id} {@rest} data-role="counter">
            <span data-role="count">{@count}</span>
            <span data-role="body">{render_slot(@inner_block)}</span>
          </div>
          """
        })

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.live_component module={@mod} id="slotted" label="L" data-author="kept">
              inside the slot
            </.live_component>
            """
          end,
          %{mod: module}
        )

      assert html =~ "inside the slot", "the slot never reached render_slot/1"
      assert html =~ ~s(data-author="kept"), "the author's global was lost with it"
      refute html =~ "inner_block=", "the slot was rendered as an HTML attribute"
    end

    # A DECLARED DEFAULT HAS TO REACH THE SOCKET, not only the render. `render/1` merges the
    # defaults into its own copy of the assigns, which is enough for `{@step}` in the template and
    # for nothing else — `update/2` and `handle_event/3` read `socket.assigns`. Before this, a
    # component whose parent left a defaulted attr unset rendered correctly and raised
    # `key :step not found` on its first click.
    #
    # It took a kit-exported component to find, because a hand-built exemplar passes every attr from
    # its host. Every stateful component declaring a default is affected, which is why the assertion
    # lives here rather than beside that export.
    test "a handler reads a declared default the parent never passed" do
      module =
        compile!(%{
          template: """
          <div id={@id} {@rest} data-role="counter">
            <span data-role="count">{@count}</span>
            <button type="button" phx-click="bump" phx-target={@myself}>more</button>
          </div>
          """,
          attrs: [
            %{name: "step", type: "integer", opts: %{default: 5}},
            %{name: "rest", type: "global", opts: %{}}
          ],
          helpers: [
            %{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            },
            %{
              name: "handle_event",
              args: ~s|"bump", _params, socket|,
              code:
                "{:noreply, Phoenix.Component.assign(socket, :count, socket.assigns.count + socket.assigns.step)}"
            }
          ]
        })

      html =
        render_component(
          fn assigns ->
            ~H"""
            <div id="host">
              <.live_component module={@mod} id="stepped" />
            </div>
            """
          end,
          %{mod: module}
        )

      assert html =~ "0", "it did not render at all"

      {:ok, view, _html} =
        live_isolated(Phoenix.ConnTest.build_conn(), DefaultHost, session: %{"mod" => module})

      view |> element(~s(#stepped button), "more") |> render_click()

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="count"]))
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == ["5"],
             "the handler could not see the default the declaration gave it"
    end

    # AND A DECLARED DEFAULT OF `nil` OR `false` IS A DECLARED DEFAULT. `extract_all_defaults/1`
    # asked `opts[:default] || ...` inside a comprehension whose assignment clause is a FILTER, so
    # an attribute defaulting to either one was dropped from the map entirely — it reached neither
    # the socket nor the render, and `@class` raised in the visitor's LiveView the first time a page
    # left it out.
    #
    # `class` carries `default: nil` on nearly every component the kit ships, so this was not an
    # edge: it is 659 declarations in one bundle, and it made the whole export path unusable for a
    # live component while a hand-built exemplar that passes every attr looked fine.
    test "a default of nil or false reaches the socket like any other" do
      module =
        compile!(%{
          template: """
          <div id={@id} {@rest} data-role="counter">
            <span data-role="class">{inspect(@class)}</span>
            <span data-role="open">{inspect(@open)}</span>
            <span data-role="count">{@count}</span>
            <button type="button" phx-click="bump" phx-target={@myself}>more</button>
          </div>
          """,
          attrs: [
            %{name: "class", type: "string", opts: %{default: nil}},
            %{name: "open", type: "boolean", opts: %{default: false}},
            %{name: "rest", type: "global", opts: %{}}
          ],
          helpers: [
            %{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            },
            %{
              name: "handle_event",
              args: ~s|"bump", _params, socket|,
              code: """
              {:noreply,
               Phoenix.Component.assign(
                 socket,
                 :count,
                 if(socket.assigns.open, do: 100, else: 1) + if(socket.assigns.class, do: 10, else: 0)
               )}
              """
            }
          ]
        })

      {:ok, view, html} =
        live_isolated(Phoenix.ConnTest.build_conn(), DefaultHost, session: %{"mod" => module})

      assert html =~ ~s(<span data-role="class">nil</span>),
             "the nil default never reached render"

      assert html =~ ~s(<span data-role="open">false</span>), "the false default never reached it"

      # AND THE SOCKET, not only the render — the handler reads `socket.assigns`, which is the half
      # that raised rather than rendering wrong.
      view |> element(~s(#stepped button), "more") |> render_click()

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="count"]))
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == ["1"],
             "the handler could not read the falsy defaults the declaration gave it"
    end

    # AND `@site` SURVIVES THE DISPATCH. `live/3` drops `site` and `component_name` before calling
    # `live_component/1`, because a live component sweeps every undeclared key into its global attr
    # and both were being rendered onto the component's root element. A function component keeps
    # them through the synthetic declarations on the bridge, which the live path does not call — so
    # a kit component drawing its own siblings with `<.component site={@site} />` worked stateless
    # and raised `key :site not found` the moment it was marked stateful.
    test "the site it was compiled for reaches its template" do
      module =
        compile!(%{
          site: "Global",
          template: """
          <div id={@id} {@rest} data-role="counter">
            <span data-role="site">{@site}</span>
            <span data-role="name">{@component_name}</span>
            <span data-role="count">{@count}</span>
          </div>
          """,
          attrs: [%{name: "rest", type: "global", opts: %{}}],
          helpers: [
            %{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            }
          ]
        })

      {:ok, _view, html} =
        live_isolated(Phoenix.ConnTest.build_conn(), DefaultHost, session: %{"mod" => module})

      assert html =~ ~s(<span data-role="site">Global</span>),
             "the site the module was compiled for never reached the template"

      assert html =~ ~s(<span data-role="name">counter</span>),
             "and neither did the name it was compiled under"

      # AND NEITHER IS RENDERED AS AN HTML ATTRIBUTE, which is why `live/3` drops them in the first
      # place — putting them back on the socket must not put them back in the markup.
      refute html =~ ~s(site="Global"), "site was swept into the global attr after all"
      refute html =~ "component_name=", "component_name reached the DOM"
    end

    # AND THE GLOBAL ATTRIBUTE ANSWERS TO THE NAME THE AUTHOR GAVE IT. `rest` is a convention, not a
    # rule — `attr :html_attrs, :global` is as valid as any — and the stateless path honours it
    # because `Phoenix.Component.Declarative` reads the declaration. The stateful path builds that
    # map itself in `update_many/1`, and it used to write it to a hardcoded `:rest`, so a component
    # declaring any other name raised `key :html_attrs not found` with its caller's globals sitting
    # on the socket under the wrong key.
    test "the global attribute is assigned under its declared name" do
      module =
        compile!(%{
          template: """
          <div id={@id} {@html_attrs} data-role="counter">
            <span data-role="count">{@count}</span>
          </div>
          """,
          attrs: [%{name: "html_attrs", type: "global", opts: %{}}],
          helpers: [
            %{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            }
          ]
        })

      html =
        render_component(
          fn assigns ->
            ~H"""
            <div id="host">
              <.live_component module={@mod} id="named" data-author="kept" />
            </div>
            """
          end,
          %{mod: module}
        )

      assert html =~ ~s(data-author="kept"),
             "the caller's global did not reach the author's own global attr"
    end

    # AN EVENT NOBODY DECLARED A HANDLER FOR IS IGNORED rather than crashing the page that hosts it.
    # A component's handler runs in whatever LiveView renders it, so an unmatched clause there is a
    # visitor's whole page, not one widget.
    test "an event it declares no handler for does not take the page down" do
      {:ok, view, _html} = mount_host(compile!(%{}))

      # AIMED AT THE COMPONENT, through `@myself` — an event aimed at the page would be the page's
      # problem and would prove nothing about this. The component declares `bump` and nothing else.
      assert view |> element(~s(#counter-one button), "noise") |> render_click() =~ "counter"
      assert Process.alive?(view.pid)
      assert counts(view) == ["0", "0"], "an unhandled event changed something"
    end
  end

  # A COMPONENT'S HELPERS ARE THE ONE PATH INTO A GENERATED `defmodule` THAT NOTHING CHECKED.
  # `LiveViewCompiler` has gated a page's handlers and helpers on their signature since signing
  # existed; `ComponentCompiler` did not, and `helpers` is where a stateful component's `mount/1`,
  # `update/2` and `handle_event/3` live — the only code in this runtime that runs in response to a
  # network message rather than to a render, in whatever LiveView renders the component.
  describe "signed lifecycle code" do
    alias MishkaCmsCore.Runtime.PageBuilder.CodeSignature

    @key "a-test-signing-key-that-is-long-enough"

    setup do
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :code_signing_key) end)
      :ok
    end

    defp signing_on, do: Application.put_env(:mishka_cms_core, :code_signing_key, @key)

    defp signed(helper), do: CodeSignature.put(helper)

    # WITH A KEY AND A SIGNATURE, it behaves exactly as it does without one.
    test "runs when it was signed by this deployment" do
      signing_on()

      module =
        compile!(%{
          helpers: [
            signed(%{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 7)}"
            })
          ]
        })

      {:ok, view, _html} = mount_host(module)

      assert counts(view) == ["7", "7"], "a signed mount did not run"
    end

    # AND A TAMPERED ONE DECLINES TO ACT. The shape matters more than the refusal: LiveView calls
    # `mount/1` and matches `{:ok, socket}`, so an inert `nil` there would crash the page that hosts
    # the component — which is the outcome inertness exists to avoid.
    test "an unsigned mount is inert in the right shape, and the page still renders" do
      signing_on()

      module =
        compile!(%{
          helpers: [
            %{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 99)}"
            },
            signed(%{
              name: "update",
              args: "assigns, socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            })
          ]
        })

      {:ok, view, html} = mount_host(module)

      assert html =~ "Presses", "the component did not render at all"
      assert counts(view) == ["0", "0"], "the unsigned mount ran"
    end

    # THE SOCKET IS NOT ALWAYS CALLED `socket`. An inert body that assumed the name would compile to
    # a reference to a variable that does not exist, which is a compile failure rather than an inert
    # clause — worse than what it replaced.
    test "an unsigned handler whose socket is bound under another name still compiles" do
      signing_on()

      module =
        compile!(%{
          helpers: [
            signed(%{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            }),
            %{
              name: "handle_event",
              args: ~s|"bump", _params, sock|,
              code: "{:noreply, Phoenix.Component.assign(sock, :count, 1)}"
            }
          ]
        })

      {:ok, view, _html} = mount_host(module)

      assert counts(view) == ["0", "0"]

      # The clause is there and answers; it simply declines to do what it said.
      view |> element(~s(#counter-one button), "more") |> render_click()
      assert counts(view) == ["0", "0"], "an unsigned handler changed state"
      assert Process.alive?(view.pid)
    end

    # AND AN ORDINARY HELPER IS STILL `nil`, the same answer a page's gets.
    test "an unsigned plain helper answers nil rather than a callback shape" do
      signing_on()

      module =
        compile!(%{
          helpers: [
            signed(%{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            }),
            %{name: "shout", args: "word", code: "String.upcase(word)"}
          ]
        })

      assert module.shout("hi") == nil
    end
  end

  # THE ROOT IS CHECKED AT COMPILE. `Phoenix.LiveView.Diff.component_to_rendered/3` raises "Stateful
  # components must have a single static HTML tag at the root" inside whichever LiveView renders the
  # component — and on a published page nothing contains that. The compile itself succeeded, so
  # nothing was recorded and the next request died the same way.
  #
  # `%Rendered{}.root` is false for a conditional root, two sibling tags, leading text or a bare
  # expression. None of those looks wrong, and the canvas cannot show it: `static_component/1` calls
  # `render/1` as a plain function, which never consults `root`.
  describe "the root a live component must have" do
    alias MishkaCmsCore.Runtime.Compilers.ComponentCompiler

    defp rooted!(template, overrides \\ %{}) do
      module = compile!(Map.merge(%{template: template, helpers: []}, overrides))
      ComponentCompiler.check_root(module)
    end

    test "one static tag passes" do
      assert rooted!(~S|<div id={@id} {@rest}>fine</div>|) == :ok
    end

    test "a conditional root does not — the one nobody expects" do
      assert {:error, why} = rooted!(~S|<div :if={@label != ""} id={@id} {@rest}>x</div>|)
      assert why =~ "single static HTML tag at the root"
    end

    test "nor do two sibling tags" do
      assert {:error, _why} = rooted!(~S|<div id={@id}>a</div><div>b</div>|)
    end

    test "nor leading text" do
      assert {:error, _why} = rooted!(~S|hello <div id={@id} {@rest}>x</div>|)
    end

    test "nor a bare expression" do
      assert {:error, _why} = rooted!(~S|{@label}|)
    end

    # A STATELESS COMPONENT HAS NO SUCH RULE, so it is not asked and nothing about the installed
    # components changes.
    test "and a function component is never asked" do
      module = compile!(%{stateful: false, helpers: [], template: ~S|<div>a</div><div>b</div>|})

      assert ComponentCompiler.check_root(module) == :ok
    end

    # WHAT IT CANNOT SEE, stated rather than assumed. HEEx compiles every `{…}` into a closure the
    # diff calls later, so a fault INSIDE one is not raised by `render/1` and this probe returns a
    # `%Rendered{}` with a perfectly good root. That is the same reason the canvas needs `contain/3`
    # at all. The probe is about the shape of the root and nothing else.
    test "a fault inside a dynamic expression is deferred by HEEx, so this does not see it" do
      assert rooted!(~S|<div id={@id} {@rest}>{@never_declared.boom}</div>|) == :ok
    end

    # Nor a raise in the `body`, which `guarded_body/2` already rescues on purpose — a body that
    # raises is a body that does not apply, and the component renders without it. So the rescue in
    # the probe is a belt for something neither of those two paths lets through, and the answer it
    # gives is about the root.
  end
end
