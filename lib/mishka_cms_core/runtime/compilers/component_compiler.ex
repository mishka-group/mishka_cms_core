# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.ComponentCompiler do
  @moduledoc """
  Runtime compiler for Phoenix Components with dynamic content compilation.

  This module provides functionality to dynamically compile Phoenix Components at runtime
  from configuration data. It generates complete Phoenix Component modules with proper
  attribute definitions, slot definitions, helper functions, and HEEx template compilation.

  ## Features

  - Dynamic component module generation from configuration
  - Full Phoenix Component attribute and slot support
  - HEEx template compilation with proper context
  - Default value handling for all attribute types including @rest
  - Helper function integration
  - Component metadata and access control information
  - Support for struct-based attributes
  - Proper Phoenix LiveView integration
  - Total `_, …` catch-all appended to narrowed variant dispatchers (`color_variant`, `size_class`, …)
    so a component renders a bare class instead of crashing when a page calls a variant/color the
    install narrowed away

  ## Component Structure

  Generated components include:
  - `__component_information__/0` - Returns component metadata
  - `__component_information__/1` - Returns specific metadata by key
  - Main component function (named after the component title)
  - `update_many/1` and `render/1`, for a stateful component only
  - Helper functions (if defined)
  - Proper attr/slot declarations for Phoenix Component compliance

  ## Usage



      params = %{
        title: "alert_box",
        component_module: MyApp.Components.AlertBox,
        template: ~S'''
        <div class={"alert alert-\#{@type} \#{@class}"} role="alert">
          <h4 :if={@title}><%= @title %></h4>
          <%= render_slot(@inner_block) %>
          <button :if={@closable} class="ml-auto" phx-click={@on_close}>×</button>
        </div>
        ''',
        attrs: [
          %{name: "type", type: "string", opts: [default: "info", values: ["info", "warning", "error", "success"]]},
          %{name: "title", type: "string", opts: [default: nil]},
          %{name: "closable", type: "boolean", opts: [default: false]},
          %{name: "on_close", type: "string", opts: [default: nil]},
          %{name: "class", type: "string", opts: [default: ""]}
        ],
        slots: [
          %{name: "inner_block", opts: [required: true, doc: "Main content of the alert"]}
        ],
        helpers: [
          %{
            name: "format_message",
            args: "message, type",
            code: ~S\"\"\"
            case type do
              "error" -> "⚠️ " <> message
              "success" -> "✅ " <> message
              _ -> message
            end
            \"\"\"
          }
        ]
      }

      ast = ComponentCompiler.build_module(params)
      MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)
  """

  # Compiled modules are built on the host's web entrypoint when it names one, so runtime templates
  # can reach its components and routes. See `MishkaCmsCore.Runtime.CompiledPageBase`.
  @web_module MishkaCmsCore.Runtime.Compilers.Shared.web_module()
  @core_components Application.compile_env(
                     :mishka_cms_core,
                     :core_components,
                     MishkaCmsCore.CoreComponents
                   )

  import Kernel, except: [def: 2, defp: 2]
  import Phoenix.Component.Declarative

  require Logger

  @supported_attr_types ~w(any string atom boolean integer float list map global)

  ####################################################################################
  ############################ (▰˘◡˘▰) Functions (▰˘◡˘▰) #############################
  ####################################################################################

  @doc """
  Main function to build component modules from component data.

  Takes component configuration parameters and returns a complete AST for a Phoenix Component module.
  The function orchestrates the entire compilation process through a pipeline of transformations.

  ## Parameters

  - `params` - Map containing component configuration with keys:
    - `:title` - Component name (required)
    - `:component_module` - Target module name (required)
    - `:template` - HEEx template string (optional)
    - `:body` - Elixir code to execute before rendering (optional)
    - `:attrs` - List of attribute definitions (optional)
    - `:slots` - List of slot definitions (optional)
    - `:helpers` - List of helper function definitions (optional)
    - `:site`, `:site_id`, `:host` - Site context information
    - `:permissions` - Access control permissions
    - `:extra` - Additional metadata

  ## Returns

  Returns the complete AST for the component module that can be compiled using
  `MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module/1`.

  ## Example

      params = %{
        title: "card",
        component_module: MyApp.Components.Card,
        template: ~S(<div class="card {@class}"><%= @content %></div>),
        attrs: [
          %{name: "class", type: "string", opts: [default: ""]},
          %{name: "content", type: "string", opts: [required: true]}
        ]
      }

      ast = build_module(params)
  """
  def build_module(params) do
    MishkaInstaller.Event.Hook.call("runtime:compile:before_component", params,
      meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
      return: false
    )

    :telemetry.span(
      [:mishka_cms, :runtime, :compilers, :component],
      %{name: params[:title] || params["title"], site: params[:site] || params["site"]},
      fn ->
        result =
          MishkaCmsCore.Runtime.Helpers.atomize_keys(params)
          |> build_component_information()
          |> build_module_attributes()
          |> build_attributes()
          |> build_slots()
          |> build_component_function()
          |> build_helpers()
          |> build_event_fallback()
          |> create_module_ast()

        MishkaInstaller.Event.Hook.call("runtime:compile:after_component", params,
          meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
          return: false
        )

        {result, %{}}
      end
    )
  end

  @doc """
  Build component information including metadata.

  Creates AST for the `__component_information__` functions that provide access to component
  metadata, private information, ACL permissions, and extra data. These functions are used
  by the runtime system to introspect component properties.

  ## Parameters

  - `params` - Atomized component parameters map

  ## Returns

  Returns a tuple `{params, functions_ast}` where `functions_ast` contains the AST for:
  - `__component_information__/0` - Returns complete metadata map
  - `__component_information__/1` - Returns metadata by atom key or key path
  - `__component_information__/1` - Returns metadata by string dot-notation path

  ## Metadata Structure

  The metadata includes:
  - `:component` - Public component info (name, timestamp, attrs, slots)
  - `:private` - Private runtime info (id, priority, module, site details)
  - `:acl` - Access control permissions
  - `:extra` - Additional custom metadata
  """
  def build_component_information(params) do
    extra = render_time_extra(params[:extra])

    component_info_ast =
      quote do
        def __component_information__ do
          %{
            component: %{
              name: unquote(params[:title]),
              timestamp: unquote(Macro.escape(params[:timestamp])),
              attrs: unquote(Macro.escape(params[:attrs] || [])),
              slots: unquote(Macro.escape(params[:slots] || []))
            },
            private: %{
              id: unquote(params[:id]),
              priority: unquote(params[:priority] || 0),
              component_module: unquote(params[:component_module]),
              site: unquote(params[:site]),
              site_id: unquote(params[:site_id]),
              host: unquote(params[:host]),
              format: unquote(params[:format]) || :heex,
              # WHAT THIS MODULE IS, asked of the module itself. Dispatch reads this rather than a
              # name pattern or a column at render time: the compiled artefact is the only thing
              # that knows which shape it actually took, and a stale module built before this column
              # existed answers `nil` through `get_in/2`, which is falsy — so it keeps the old path
              # until something rebuilds it.
              stateful: unquote(params[:stateful] == true),
              # Whether the template draws stored content — calls `rich_content`. Such a component
              # is never drawn by a marker inside content, which could be a marker for itself. See
              # `MishkaCmsCore.Runtime.ContentComponents`.
              draws_content:
                unquote(MishkaCmsCore.Runtime.ContentComponents.draws_content?(params[:template]))
            },
            acl: %{permissions: unquote(Macro.escape(params[:permissions] || []))},
            extra: unquote(Macro.escape(extra))
          }
        end

        def __component_information__(key) when is_atom(key) do
          get_in(__component_information__(), [key])
        end

        def __component_information__(keys) when is_list(keys) do
          get_in(__component_information__(), keys)
        end

        def __component_information__(key) when is_binary(key) do
          String.split(key, ".")
          |> Enum.map(&String.to_existing_atom/1)
          |> then(&get_in(__component_information__(), &1))
        rescue
          _ -> nil
        end
      end

    {params, [component_info_ast]}
  end

  # `extra.examples` and `extra.demo_examples` are install/preview metadata (per-option example
  # sources); nothing reads them at render time, so they stay out of every compiled module's
  # bytecode — `demo_examples` alone is multi-megabyte across the Chelekom bundle.
  defp render_time_extra(%{} = extra),
    do: Map.drop(extra, ["examples", :examples, "demo_examples", :demo_examples])

  defp render_time_extra(extra), do: extra

  @doc """
  Build component attributes.

  Generates Phoenix Component attribute declarations from the component configuration.
  Creates proper `attr/3` calls with type validation and options handling.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and accumulated AST functions

  ## Returns

  Returns updated tuple with attribute setup and individual attribute declarations added.
  Each attribute is properly validated and converted to Phoenix Component format with:
  - Proper type conversion (including struct types)
  - Option filtering to valid Phoenix Component options
  - Default value handling

  ## Supported Options

  Valid attribute options that are preserved:
  - `:required` - Whether the attribute is required
  - `:default` - Default value for the attribute
  - `:examples` - Example values
  - `:values` - Allowed values list
  - `:doc` - Attribute documentation
  - `:include` - Global attributes to include
  - `:exclude` - Global attributes to exclude
  """
  # sobelow_skip ["DOS.StringToAtom"]
  # Attr names come from a stored Component row, which only an admin holding the component or code
  # permission can write; Phoenix's `attr/3` takes them as atoms. The two synthetic names are literals.
  def build_attributes({params, functions_ast}) do
    attr_setup_ast =
      quote do
        [] = Phoenix.Component.Declarative.__setup__(__MODULE__, [])

        attr = fn name, type, opts ->
          Phoenix.Component.Declarative.__attr__!(
            __MODULE__,
            name,
            type,
            opts,
            __ENV__.line,
            __ENV__.file
          )
        end
      end

    attributes_ast =
      Enum.map(params[:attrs] || [], fn component_attr ->
        type = attr_type_to_atom(component_attr.type, Map.get(component_attr, :struct_name))
        opts = ignore_invalid_attr_opts(Map.get(component_attr, :opts, []))
        opts = coerce_default_for_type(opts, type)

        quote do
          attr.(
            unquote(String.to_atom(component_attr.name)),
            unquote(type),
            unquote(Macro.escape(opts))
          )
        end
      end)

    # Synthetic attrs every compiled runtime component MUST declare:
    #
    #   :site           — the kit-rewriter emits `site={@site}` in
    #                     parent→child runtime dispatches. Without a
    #                     declared `attr :site, :any, default: nil`, the
    #                     `@site` access in the parent's HEEx raises
    #                     KeyError because Phoenix Component change-
    #                     tracking won't auto-populate undeclared keys.
    #
    #   :component_name — likewise, the parent's template references
    #                     `@component_name` when rewriting children, and
    #                     the runtime helper requires it on the assigns
    #                     map at the call-site. Declare it once here so
    #                     it's always safe to read.
    #
    # Both are declared with `default: nil` so existing Chelekom sources
    # (which don't declare them) still compile cleanly.
    declared_names = Enum.map(params[:attrs] || [], fn a -> a.name end)

    synthetic_attrs =
      [{"site", :any}, {"component_name", :any}]
      |> Enum.reject(fn {n, _} -> n in declared_names end)
      |> Enum.map(fn {n, t} ->
        quote do
          attr.(unquote(String.to_atom(n)), unquote(t), default: nil)
        end
      end)

    {params, functions_ast ++ [attr_setup_ast] ++ attributes_ast ++ synthetic_attrs}
  end

  @doc """
  Build component slots.

  Generates Phoenix Component slot declarations from the component configuration.
  Creates proper `slot/3` calls with nested attribute support for slot parameters.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and accumulated AST functions

  ## Returns

  Returns updated tuple with slot setup and individual slot declarations added.
  Each slot includes:
  - Proper slot declaration with options
  - Nested attribute definitions for slot parameters
  - Option filtering to valid Phoenix Component slot options

  ## Supported Slot Options

  Valid slot options that are preserved:
  - `:required` - Whether the slot is required
  - `:validate_attrs` - Whether to validate slot attributes
  - `:doc` - Slot documentation

  Slot attributes support the same options as regular component attributes.
  """
  # sobelow_skip ["DOS.StringToAtom"]
  # Slot names come from a stored Component row, which only an admin holding the component or code
  # permission can write; Phoenix's `slot/3` takes them as atoms.
  def build_slots({params, functions_ast}) do
    slot_setup_ast =
      quote do
        slot = fn name, opts, block ->
          Phoenix.Component.Declarative.__slot__!(
            __MODULE__,
            name,
            opts,
            __ENV__.line,
            __ENV__.file,
            fn -> nil end
          )
        end
      end

    # Emit slots WITHOUT their nested attr declarations.
    #
    # Phoenix's standard `slot :foo, opts do attr :x, ... end` is a
    # MACRO that scopes inner attrs to the slot. Our runtime-built
    # slots use a fn (`slot = fn name, opts, _block -> __slot__! end`)
    # which doesn't pass the do-block through, so any `attr.()` call
    # inside the block registers at TOP-LEVEL — colliding with same-
    # named top-level attrs (e.g. accordion's :id top-level vs :item.id).
    #
    # Slot-attrs in the bundle are still useful for the test harness
    # to synthesize slot-item shapes; they just can't drive runtime
    # validation. Phoenix is permissive about runtime slot items
    # carrying extra keys, so this is safe.
    slots_ast =
      Enum.map(params[:slots] || [], fn component_slot ->
        quote do
          slot.(
            unquote(String.to_atom(component_slot.name)),
            unquote(ignore_invalid_slot_opts(Map.get(component_slot, :opts, []))),
            do: nil
          )
        end
      end)

    {params, functions_ast ++ [slot_setup_ast] ++ slots_ast}
  end

  @doc """
  Build the main component function with HEEx template compilation and default values.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and accumulated AST functions

  ## Returns

  Returns updated tuple with the main component function added.

  ## Generated Functions

  - `component_name(assigns)` - Main component function named after the title

  It:
  1. Merges default values into assigns
  2. Executes any body code (if present)
  3. Compiles and renders the HEEx template
  4. Returns the rendered output

  ## Default Value Handling

  Default values are extracted from attribute definitions and merged into assigns
  before rendering, ensuring all attributes have proper defaults including @rest
  for global attributes.
  """
  def build_component_function({params, functions_ast}) do
    case {params[:stateful] == true, params[:clauses], reserved_names(params)} do
      # REFUSED RATHER THAN FLATTENED. `build_stateful_function/1` reads the template and never the
      # clause list, so this combination used to compile to a component that rendered only its base
      # branch — with no warning, no log line and nothing for the author to connect it to.
      # `Validations.StatefulShape` refuses it at the action boundary, which is where an author
      # meets it; this is the same refusal for the paths that do not go through an action, and for a
      # row stored before that validation existed.
      {true, list, _taken} when is_list(list) and list != [] ->
        raise ArgumentError,
              "#{params[:title]} is a live component and dispatches through clauses. Each clause " <>
                "has its own root element and a live component must have exactly one."

      # REFUSED RATHER THAN COMPILED, for the same callers. A live component declaring a name
      # LiveView assigns itself, as an attr or as a slot, compiles, passes the root probe because the
      # probe never assigns, and raises on `assign` inside a visitor's LiveView.
      {true, _none, [_name | _more] = taken} ->
        raise ArgumentError,
              "#{params[:title]} is a live component and declares #{Enum.join(taken, ", ")}. " <>
                "A live component cannot declare a name LiveView assigns itself: assigning over " <>
                "one raises."

      {true, _none, []} ->
        build_stateful_function({params, functions_ast})

      {false, list, _taken} when is_list(list) and list != [] ->
        build_multi_clause_function({params, functions_ast}, list)

      {false, _none, _taken} ->
        build_single_clause_function({params, functions_ast})
    end
  end

  defp reserved_names(params) do
    reserved = MishkaCmsCore.Runtime.Resources.Validations.StatefulShape.reserved_names()

    for %{name: name} <- (params[:attrs] || []) ++ (params[:slots] || []),
        to_string(name) in reserved,
        do: to_string(name)
  end

  # WHAT LIVEVIEW PUTS IN A LIVECOMPONENT'S ASSIGNS THAT THE PARENT DID NOT. Dropped before `:rest`
  # is computed, so none of it can be rendered as an HTML attribute. `:id` is on the list and then
  # assigned back by name, because it is LiveView's to require and not the author's to receive
  # through `@rest`.
  @injected_assigns [:__changed__, :__given__, :flash, :myself, :socket, :id]

  # A LIVE COMPONENT IS THE SAME TEMPLATE IN A DIFFERENT MODULE SHAPE, and the shape is not
  # guessable — three of the four anybody would write fail, each differently. See
  # `MishkaCmsCore.Runtime.Compilers.StatefulComponentShapeTest`, which renders all four.
  #
  # WHAT IS EMITTED:
  #
  #   * the BRIDGE, `def :"chelekom-live-search"(assigns)`, keeping every `attr` and `slot`
  #     declaration. A parent still gets defaults, validation and change tracking, and the name a
  #     stored template calls stays the name it calls. ITS BODY IS A CALL TO `render/1`, so the
  #     template is compiled once and not once per function: the declarations' wrapper runs first,
  #     and `render/1` then merges the defaults, runs the body and renders, which is all a copy of
  #     the template in the bridge would do. A copy there makes the compiler do the template's work
  #     twice — and the template is most of a kit component's code — for a function no page calls:
  #     `LiveViewHelpers` mounts a live component and the cold surfaces call `render/1`.
  #     `MishkaCmsCore.Runtime.Compilers.StatefulTemplateOnceTest` draws both shapes on every surface.
  #   * `render/1`, carrying the template and NO declarations. `Phoenix.Component.Declarative`
  #     generates a wrapper that computes the `:global` attr by subtraction, and a LiveComponent's
  #     `render/1` is handed the SOCKET's assigns — so declarations there sweep the lifecycle's own
  #     state and LiveView's `socket`, `myself` and `flash` into `@rest`, and `@n` raises `KeyError`
  #     while `n="0"` appears in the markup. Measured, on a component shaped like 71 of the kit's 74.
  #   * `update_many/1`, which is the half the obvious fix misses: the wrapper that SWEEPS is also
  #     the only thing that BUILDS the global attr, so a bare `render/1` raises `key :rest not
  #     found` on every template that mentions it. This assigns it explicitly — the parent's keys
  #     minus the declared ones — which is subtraction from a KNOWN set, so nothing of LiveView's
  #     can land in it by construction rather than by a shield.
  #   * a `handle_event/3` catch-all, so an event aimed at a component that declares no handler is
  #     ignored rather than crashing the page that hosts it.
  #
  # The kit's own `mount/1`, `update/2` and `handle_event/3` ride `helpers` and are emitted by
  # `build_helpers/1` as they always were. `update_many/1` REPLACES `update/2` rather than running
  # before it — `Phoenix.LiveView.Diff` takes one branch or the other — so a kit that writes one
  # would have had it silently ignored. The emitted `update_many/1` calls it itself, last, once the
  # parent's assigns are already on the socket.
  # sobelow_skip ["DOS.StringToAtom"]
  # The function is named after the stored component's `name`, which only an admin holding the
  # component or code permission can set.
  defp build_stateful_function({params, functions_ast}) do
    {template_ast, body_ast} = compile_template_and_body(params)
    defaults_map = extract_all_defaults(params[:attrs] || [])
    declared = declared_keys(params)
    restored = dispatch_restored(params)
    global = global_name(params)

    quote do
      # sobelow_skip ["DOS.StringToAtom"]
      # The stored component's own name, written only with the component or code permission.
      def unquote(String.to_atom(params[:title]))(var!(assigns)), do: render(var!(assigns))

      # `update_many/1` AND NOT `update/2`, so the name `update/2` stays the kit's to use.
      #
      # AND IT HAS TO CALL THE KIT'S ITSELF. `Phoenix.LiveView.Diff` does
      # `if function_exported?(component, :update_many, 1)` and takes one branch or the other — so
      # `update_many/1` REPLACES `update/2` rather than running before it, and a kit that wrote one
      # would have had it silently ignored. Read out of `diff.ex` rather than assumed; the assumption
      # was wrong.
      #
      # Called after the parent's assigns are carried across, so the kit's clause sees them already
      # on the socket rather than having to do that work again.
      def update_many(var!(pairs)) do
        Enum.map(var!(pairs), fn {var!(assigns), var!(socket)} ->
          given = Map.drop(var!(assigns), unquote(Macro.escape(@injected_assigns)))
          declared = unquote(Macro.escape(declared))

          # A SLOT IS NOT A GLOBAL ATTRIBUTE. Whatever is left after the declared names still has to
          # be split again, because a caller passes slots the component never declared — the
          # builder's canvas hands every component an `inner_block` whether it takes one or not, and
          # `render_slot/1` needs it under its own name. Swept into `:rest` it is rendered as an HTML
          # attribute, and a slot is a map: "lists in Phoenix.HTML may only contain integers
          # representing bytes, binaries or other lists".
          #
          # Split on the VALUE rather than on a list of names, so an undeclared slot and a declared
          # one are treated the same way and no name has to be remembered here.
          {slots, globals} =
            given
            |> Map.drop(declared)
            |> Enum.split_with(fn {_name, value} ->
              case value do
                %{__slot__: _which} -> true
                [%{__slot__: _which} | _rest] -> true
                _ordinary -> false
              end
            end)

          # A DECLARED DEFAULT HAS TO REACH THE SOCKET, not just the render. `render/1` merges the
          # defaults into its own copy of the assigns, which is enough for `{@step}` in the template
          # and nothing else: `update/2` and `handle_event/3` read `socket.assigns`, and a component
          # whose parent left a defaulted attr unset raised `key :step not found` on its first
          # click. Found by driving a kit-exported component rather than a hand-built one, because a
          # hand-built one passes every attr.
          #
          # `assign_new/3` and not a merge, so this only ever FILLS A GAP: the parent's value is
          # assigned below and wins, and a value a handler put there survives the next update rather
          # than being reset to the declaration's default on every parent re-render.
          unquote(Macro.escape(defaults_map))
          |> Enum.reduce(var!(socket), fn {key, value}, seeded ->
            Phoenix.Component.assign_new(seeded, key, fn -> value end)
          end)
          |> Phoenix.Component.assign(Map.take(given, declared))
          |> Phoenix.Component.assign(Map.new(slots))
          # `:id` is what a live component is identified by, and the stored template may read `@id`.
          # credo:disable-for-next-line Jump.CredoChecks.UnusedLiveViewAssign
          |> Phoenix.Component.assign(:id, Map.get(var!(assigns), :id))
          # THE DISPATCH'S OWN KEYS, PUT BACK FROM WHAT THIS MODULE WAS COMPILED WITH. `live/3`
          # drops `site` and `component_name` before calling `live_component/1`, because a live
          # component sweeps every undeclared key into its global attr and both were being rendered
          # onto the component's root element. A function component keeps them — the synthetic
          # `attr :site` and `attr :component_name` declare them on the bridge, and the bridge is
          # not on this path — so a kit component that draws its own siblings with
          # `<.component component_name="…" site={@site} />` worked as a function component and
          # raised `key :site not found` as a live one.
          #
          # Taken from the compiled constants rather than from the call: this module is NAMED for
          # its (name, site) pair, so the site is a property of the module and cannot disagree.
          |> Phoenix.Component.assign(unquote(Macro.escape(restored)))
          |> Phoenix.Component.assign(unquote(global), Map.new(globals))
          |> then(fn carried ->
            case function_exported?(__MODULE__, :update, 2) do
              false -> carried
              true -> __MODULE__.update(var!(assigns), carried) |> elem(1)
            end
          end)
        end)
      end

      # Timed for the component preview's Performance Metrics: a live component is rendered by
      # LiveView itself, so this is the one place every render of it passes through.
      def render(var!(assigns)) do
        MishkaCmsCore.Runtime.RenderMetrics.measure(__MODULE__, fn ->
          var!(assigns) = Map.merge(unquote(Macro.escape(defaults_map)), var!(assigns))
          unquote(body_block(params, body_ast))
          unquote(template_ast)
        end)
      end
    end
    |> then(&{params, functions_ast ++ [&1]})
  end

  @doc """
  Closes a stateful component's `handle_event/3` with a clause that answers anything left over.

  ## Why it is a stage of its own, run last

  A component's `handle_event/3` runs in whatever LiveView renders it, so an event with no matching
  clause is an unmatched function call inside a visitor's whole page rather than inside one widget.
  This makes that a no-op.

  It has to be emitted AFTER the kit's own clauses, and that is the entire reason this is a separate
  stage: Elixir takes the first clause that matches, so a catch-all emitted with the rest of the
  module shape — which is built before `build_helpers/1` runs — swallows every handler the kit
  declared. Measured as a counter that rendered, took a click, and did not move.

  Stateless components get nothing: they have no event channel to answer on.
  """
  def build_event_fallback({params, functions_ast}) do
    case params[:stateful] == true do
      false ->
        {params, functions_ast}

      true ->
        fallback =
          quote do
            def handle_event(_name, _params, var!(socket)), do: {:noreply, var!(socket)}
          end

        {params, functions_ast ++ [fallback]}
    end
  end

  # The names this component declared, which is what separates "the parent sent an attr" from "the
  # parent sent a global". Derived from the declaration rather than a list kept here, so a component
  # that declares nothing gets every passed key as a global and one that declares everything gets
  # none — both correct, neither special-cased.
  defp declared_keys(params) do
    for declaration <- (params[:attrs] || []) ++ (params[:slots] || []),
        name = declaration[:name] || declaration["name"],
        is_binary(name) or is_atom(name),
        do: to_existing_or_new_atom(name)
  end

  defp to_existing_or_new_atom(name) when is_atom(name), do: name
  # sobelow_skip ["DOS.StringToAtom"]
  # A name the stored component's attrs or slots declare, which `attr/3` and `slot/3` intern anyway.
  defp to_existing_or_new_atom(name) when is_binary(name), do: String.to_atom(name)

  # sobelow_skip ["DOS.StringToAtom"]
  # The function is named after the stored component's `name`, which only an admin holding the
  # component or code permission can set.
  defp build_single_clause_function({params, functions_ast}) do
    {template_ast, body_ast} = compile_template_and_body(params)

    defaults_map = extract_all_defaults(params[:attrs] || [])

    # Components written like `def fn(assigns) do; assigns = assigns
    # |> assign_new(...); ~H""" """; end` rebind a LOCAL `assigns`
    # before the template. Our template uses `var!(assigns)` which is
    # a different variable, so without a wrapper the body's effects
    # are invisible to the template.
    #
    # When body has content, we run it inside a block where the local
    # `assigns` aliases `var!(assigns)`, then rebind `var!(assigns)`
    # from whatever the body produced. The body's last expression must
    # be a map (the new assigns) — Chelekom convention guarantees
    # this. When body is empty or doesn't return a map, we fall back
    # to the original `var!(assigns)` so we never accidentally clobber
    # it with `nil` or non-map values.
    body_block = body_block(params, body_ast)

    component_function_ast =
      quote do
        # sobelow_skip ["DOS.StringToAtom"]
        # The stored component's own name, written only with the component or code permission.
        def unquote(String.to_atom(params[:title]))(var!(assigns)) do
          var!(assigns) = Map.merge(unquote(Macro.escape(defaults_map)), var!(assigns))
          unquote(body_block)
          unquote(template_ast)
        end
      end

    {params, functions_ast ++ [component_function_ast]}
  end

  # sobelow_skip ["DOS.StringToAtom"]
  # The function is named after the stored component's `name`, which only an admin holding the
  # component or code permission can set.
  defp build_multi_clause_function({params, functions_ast}, clauses) do
    defaults_map = extract_all_defaults(params[:attrs] || [])
    title_atom = String.to_atom(params[:title])

    # Build each arrow clause as a direct `{:->, [], [[pattern], body]}`
    # AST tuple. Avoids the `quote do x -> y end` form which doesn't
    # reliably produce arrow clauses outside case/fn/cond contexts.
    arrow_asts =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, index} ->
        head = arrow_head(parse_clause_match(Map.get(clause, :match)), clause, index)

        {:->, [], [[head], branch(clause, params, title_atom, index)]}
      end)

    # Construct the case node manually rather than going through
    # `quote do case x do unquote(arrows) end end`, which may not splice
    # arrow lists correctly into the do-block. Direct construction:
    # `{:case, [], [subject, [do: arrow_asts]]}` is unambiguous.
    case_ast =
      {:case, [], [quote(do: var!(assigns)), [do: arrow_asts]]}

    # ONE `def` whose body is a `case assigns do ... end`. Phoenix's
    # auto-generated `-inlined-X-/1-` wrapper sees a single function head
    # (the bare `assigns` arg) so attr/slot declarations + change tracking
    # work normally; dispatch happens inside the case via the same
    # patterns the bundle declared in `clauses[*].match`.
    component_function_ast =
      quote do
        def unquote(title_atom)(var!(assigns)) do
          var!(assigns) =
            Map.merge(unquote(Macro.escape(defaults_map)), var!(assigns))

          unquote(case_ast)
        end
      end

    {params, functions_ast ++ [component_function_ast]}
  end

  # The catch-all pattern is `var!(assigns)` so it binds the same variable
  # the surrounding def already binds — meaning the inner branch can keep
  # reading `@something` via the standard Phoenix.Component.assign path.
  # A clause's guard is as load-bearing as its pattern: chelekom's form
  # fields dispatch on `%{floating: floating} when floating in ["inner",
  # "outer"]`, and the enclosing def merges attr defaults in before the
  # case, so `floating` is always present. Without the guard that pattern
  # matches every call and the floating-label branch swallows the
  # default `floating: "none"`, raising FunctionClauseError downstream.
  # A DELEGATING CLAUSE RENDERS NOTHING. It normalises the assigns and hands them back to the very
  # same function, which is how every kit field turns `field={@form[:email]}` into the `name`,
  # `value`, `id` and translated `errors` its rendering clauses read:
  #
  #     assigns
  #     |> assign(field: nil, id: assigns.id || field.id)
  #     |> assign(:errors, Enum.map(errors, &translate_error(&1)))
  #     |> assign_new(:name, fn -> field.name end)
  #     |> assign_new(:value, fn -> field.value end)
  #
  # The bundle ships that body with its trailing self-call already removed, so the body's VALUE is
  # the normalised assigns and re-entering is this compiler's job. Re-entry terminates because the
  # normalisation clears `field`, so the pattern that matched cannot match a second time — the same
  # guarantee the multi-clause Phoenix function had before it was flattened into a `case`.
  #
  # Without this the clause was exported as an ordinary helper, nothing called it, and a page that
  # passed `field=` fell through to the rendering clause, which reads `@name`, which the caller never
  # set. Every field component in every kit answered that with `(KeyError) key :name not found`.
  #
  # RE-ENTRY IS BOUNDED HERE RATHER THAN TRUSTED TO THE BUNDLE. Termination used to rest on the body
  # clearing the key it matched on, which is a property of a third party's JSON and not of this
  # compiler — `MishkaChelekom.CmsBundleExporter`'s own detector checks only the SHAPE, one
  # map-patterned argument and a self-call, never that the body narrows the pattern. A clause that
  # matched `%{variant: v}` and normalised something else re-entered with assigns the same pattern
  # still matches, and `render/1` spun until the LiveView died on memory, taking the visitor's page
  # with it. Each delegating clause now marks itself spent, so it runs at most once per render and a
  # second entry falls through to a rendering clause; a bundle that clears its own pattern never
  # notices, and a malformed one costs the declaration rather than the process. This is the same rule
  # `MishkaCmsCore.Builder.FormRole` and `MishkaCmsCore.Runtime.PageBuilder.Fields` already follow.
  defp branch(%{delegates: true} = clause, _params, title_atom, index) do
    body_ast = parse_clause_body(Map.get(clause, :body))
    marker = spent_key(index)

    quote do
      normalised = unquote(body_ast)
      apply(__MODULE__, unquote(title_atom), [Map.put(normalised, unquote(marker), true)])
    end
  end

  defp branch(clause, params, _title_atom, _index) do
    body_ast = parse_clause_body(Map.get(clause, :body))
    template_ast = compile_clause_template(Map.get(clause, :template) || "", params)

    quote do
      unquote(body_ast)
      unquote(template_ast)
    end
  end

  # A clause's own guard AND, for a delegating one, the marker test that bounds re-entry — combined
  # into ONE guard rather than stacked as two `when`s, because `pattern when a when b` is Erlang's
  # guard-sequence OR and would have made a spent clause match again whenever its own guard held.
  defp arrow_head(pattern_ast, clause, index) do
    clause
    |> Map.get(:guard)
    |> parse_clause_guard()
    |> both(unspent(clause, index))
    |> applied(pattern_ast)
  end

  defp parse_clause_guard(guard) when guard in [nil, ""], do: nil
  defp parse_clause_guard(guard) when is_binary(guard), do: Code.string_to_quoted!(guard)

  # The other half of the bound on re-entry: a delegating arrow stops matching once its own marker is
  # on the assigns, so the `case` falls through to a clause that actually renders. Only delegating
  # clauses carry it — a rendering clause never re-enters and pays nothing.
  defp unspent(%{delegates: true}, index) do
    quote do
      not :erlang.is_map_key(unquote(spent_key(index)), var!(assigns))
    end
  end

  defp unspent(_clause, _index), do: nil

  defp both(nil, marker), do: marker
  defp both(guard, nil), do: guard
  defp both(guard, marker), do: quote(do: unquote(guard) and unquote(marker))

  defp applied(nil, pattern_ast), do: pattern_ast
  defp applied(guard_ast, pattern_ast), do: {:when, [], [pattern_ast, guard_ast]}

  # PER CLAUSE, NOT PER COMPONENT, so a kit whose component normalises in two steps keeps both.
  # sobelow_skip ["DOS.BinToAtom"]
  defp spent_key(index), do: :"__delegated_#{index}__"

  defp parse_clause_match(nil), do: quote(do: var!(assigns))
  defp parse_clause_match(""), do: quote(do: var!(assigns))
  defp parse_clause_match(str) when is_binary(str), do: Code.string_to_quoted!(str)

  defp parse_clause_body(nil), do: quote(do: nil)
  defp parse_clause_body(""), do: quote(do: nil)
  defp parse_clause_body(str) when is_binary(str), do: Code.string_to_quoted!(str)

  defp compile_clause_template("", _params), do: quote(do: ~H"")

  defp compile_clause_template(str, params) when is_binary(str) do
    opts = [
      line: 1,
      indentation: 0,
      file: "mishka_cms_runtime_component_#{params[:title]}_#{params[:site]}_clause",
      caller: make_env(),
      trim: true,
      tag_handler: Phoenix.LiveView.HTMLEngine
    ]

    str
    |> MishkaCmsCore.Runtime.PageBuilder.Visibility.strip()
    |> Phoenix.LiveView.TagEngine.compile(opts)
  end

  @doc """
  Build module-level attributes (e.g. `@indicator_positions [...]`).

  Reads `params[:module_attributes]` — a list of `%{name, value, when}` maps.
  Emits `Module.put_attribute(__MODULE__, :name, value)` calls inside the
  module body so the resulting attribute is referenceable by subsequent
  `attr/3` `values:` lists.

  When-gating is performed by the Importer before this point — the compiler
  always emits whatever is in the list.
  """
  # sobelow_skip ["DOS.StringToAtom"]
  # Names from the stored component's `extra.module_attributes`, set by a kit install or an admin with
  # the component or code permission; `Module.register_attribute/3` takes atoms.
  def build_module_attributes({params, functions_ast}) do
    attrs_ast =
      Enum.map(params[:module_attributes] || [], fn entry ->
        name =
          entry
          |> Map.get(:name, Map.get(entry, "name"))
          |> String.to_atom()

        value = Map.get(entry, :value, Map.get(entry, "value"))

        quote do
          Module.register_attribute(__MODULE__, unquote(name), persist: true)

          Module.put_attribute(
            __MODULE__,
            unquote(name),
            unquote(Macro.escape(value))
          )
        end
      end)

    {params, functions_ast ++ attrs_ast}
  end

  @doc """
  Build helper functions for the component.

  Processes helper function definitions and creates corresponding function AST.
  Helper functions extend component functionality with custom Elixir code.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and accumulated AST functions

  ## Returns

  Returns updated tuple with helper functions added to the AST.

  ## Helper Function Structure

  Each helper function definition should contain:
  - `:name` - Function name as string
  - `:args` - Function arguments as Elixir code string
  - `:code` - Function body as Elixir code string

  ## Example Helper Definition

      %{
        name: "format_date",
        args: "date, format \\\\ :short",
        code: "Calendar.strftime(date, format)"
      }

  This generates a helper function that can be called within the component template.
  """
  def build_helpers({params, functions_ast}) do
    helpers = params[:helpers] || []
    groups = Enum.group_by(helpers, &helper_signature/1)

    last_index =
      helpers
      |> Enum.with_index()
      |> Map.new(fn {helper, index} -> {helper_signature(helper), index} end)

    helpers_ast =
      helpers
      |> Enum.with_index()
      |> Enum.flat_map(fn {helper, index} ->
        # If the helper carries its own attrs/slots (Chelekom convention:
        # `attr :size, :string, default: "small" ; defp toast_dismiss
        # (assigns) do ~H""" ... """; end`), emit them as `attr.()` /
        # `slot.()` calls IMMEDIATELY before the def. Phoenix's macro
        # associates them with the next def/defp in compilation order,
        # giving the helper its own component contract — defaults flow,
        # `@size` access in the helper template works.
        helper_decls = build_helper_attr_decls(helper)
        clause = [build_helper_def(helper) | helper_decls] |> Enum.reverse()

        signature = helper_signature(helper)

        clause ++
          maybe_total_catch_all(signature, groups[signature], index == last_index[signature])
      end)

    {params, functions_ast ++ helpers_ast}
  end

  defp maybe_total_catch_all(_signature, _clauses, false), do: []

  # NEVER OVER A LIFECYCLE CALLBACK. The catch-all this emits answers `""`, which is right for a
  # markup helper whose clauses narrow on a variant and wrong for `handle_event/3`, where LiveView
  # matches `{:noreply, socket}` — a `""` there takes down the page hosting the component on the
  # first event no clause matched. A stateful component's unmatched events are answered by
  # `build_event_fallback/1`, which is emitted last and returns the tuple.
  # sobelow_skip ["DOS.StringToAtom"]
  # A helper name of the stored component, which `build_helper_def/1` defines as a function anyway.
  defp maybe_total_catch_all({name, arity} = signature, clauses, true) do
    with false <- {String.to_atom(name), arity} in lifecycle_callbacks(),
         true <- is_integer(arity),
         true <- match?([_, _ | _], clauses),
         true <- narrowable_dispatcher?(clauses),
         false <- has_total_catch_all?(clauses) do
      [build_total_catch_all(signature)]
    else
      _leave_it_alone -> []
    end
  end

  # Asked of the behaviour rather than listed, so a callback a later LiveView adds is covered.
  defp lifecycle_callbacks, do: Phoenix.LiveComponent.behaviour_info(:callbacks)

  defp helper_signature(helper) do
    {head, _guard} = split_args_and_guard(helper_field(helper, :args) || "")

    arity =
      case String.trim(head) do
        "" ->
          0

        str ->
          case Code.string_to_quoted("[#{str}]") do
            {:ok, list} when is_list(list) -> length(list)
            _ -> :unknown
          end
      end

    {helper_field(helper, :name), arity}
  end

  defp helper_field(helper, key), do: Map.get(helper, key) || Map.get(helper, to_string(key))

  defp narrowable_dispatcher?(clauses) do
    Enum.any?(clauses, fn helper -> (helper_field(helper, :discriminators) || []) != [] end)
  end

  defp has_total_catch_all?(clauses) do
    Enum.any?(clauses, fn helper ->
      {head, guard} = split_args_and_guard(helper_field(helper, :args) || "")

      guard == nil and
        head
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.all?(&String.starts_with?(&1, "_"))
    end)
  end

  # sobelow_skip ["DOS.StringToAtom"]
  # A helper name of the stored component, which `build_helper_def/1` defines as a function anyway.
  defp build_total_catch_all({name, arity}) do
    wildcards = List.duplicate(quote(do: _), arity)

    quote do
      # sobelow_skip ["DOS.StringToAtom"]
      # The stored helper's own name: this clause closes the function `build_helper_def/1` defines.
      def unquote(String.to_atom(name))(unquote_splicing(wildcards)), do: ""
    end
  end

  # Emit attr/slot decls before the helper. Returns AST nodes in the
  # order they should appear (decls first, then the helper def follows
  # via `build_helper_def`).
  # sobelow_skip ["DOS.StringToAtom"]
  # Attr and slot names a stored helper declares, written only with the component or code permission.
  defp build_helper_attr_decls(%{} = helper) do
    attrs = Map.get(helper, :attrs, []) || []
    slots = Map.get(helper, :slots, []) || []

    attr_nodes =
      Enum.map(attrs, fn raw ->
        a = normalize_attr_map(raw)
        type = attr_type_to_atom(a.type, Map.get(a, :struct_name))
        opts = ignore_invalid_attr_opts(Map.get(a, :opts, []))
        opts = coerce_default_for_type(opts, type)

        quote do
          attr.(unquote(String.to_atom(a.name)), unquote(type), unquote(Macro.escape(opts)))
        end
      end)

    slot_nodes =
      Enum.map(slots, fn raw ->
        s = normalize_slot_map(raw)
        opts = ignore_invalid_slot_opts(Map.get(s, :opts, []))

        quote do
          slot.(unquote(String.to_atom(s.name)), unquote(opts), do: nil)
        end
      end)

    attr_nodes ++ slot_nodes
  end

  # SIGNED CODE RUNS; ANYTHING ELSE DOES NOTHING, AND THE COMPONENT STILL RENDERS.
  #
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` has kept this contract for a page's handlers
  # and helpers since signing existed, and a component's had none — so `helpers`, which is where a
  # stateful component's `mount/1`, `update/2` and `handle_event/3` live, was the one path into a
  # generated `defmodule` that nothing checked. It is also the one that runs in response to a
  # network message rather than to a render.
  #
  # Off unless a key is configured, which is the default: `trusted?/1` then answers true for
  # everything and this is exactly the behaviour it always had.
  #
  # AN INERT CALLBACK HAS TO BE THE RIGHT SHAPE. `nil` is fine for an ordinary helper and fatal for a
  # lifecycle callback — LiveView calls `mount/1` and pattern-matches `{:ok, socket}`, so a nil there
  # crashes the page that hosts the component, which is the outcome inertness exists to avoid.
  defp build_helper_def(%{name: name, args: args, code: code} = helper) do
    {head_args, guard} = split_args_and_guard(args || "")

    body = trusted_code(helper, name, head_args, code)

    src =
      case guard do
        nil ->
          "def #{name}(#{head_args}) do\n#{body}\nend"

        g ->
          "def #{name}(#{head_args}) when #{g} do\n#{body}\nend"
      end

    Code.string_to_quoted!(src)
  end

  defp trusted_code(helper, name, head_args, code) do
    case MishkaCmsCore.Runtime.PageBuilder.CodeSignature.trusted?(helper) do
      true ->
        code

      false ->
        MishkaCmsCore.Runtime.PageBuilder.CodeSignature.warn_untrusted(
          "component helper",
          name
        )

        inert_for(name, head_args)
    end
  end

  # The shape each lifecycle callback must answer with, so an untrusted one declines to act rather
  # than taking down whatever is rendering the component. Keyed off the callbacks
  # `Phoenix.LiveComponent` actually declares; anything else is an ordinary helper and answers `nil`,
  # which is what `LiveViewCompiler` does for a page's.
  @inert_callbacks %{
    {:mount, 1} => "{:ok, socket}",
    {:update, 2} => "{:ok, socket}",
    {:handle_event, 3} => "{:noreply, socket}",
    {:handle_async, 3} => "{:noreply, socket}"
  }

  # sobelow_skip ["DOS.StringToAtom"]
  # A helper name of the stored component, looked up in a fixed map; `build_helper_def/1` defines it
  # as a function anyway.
  defp inert_for(name, head_args) do
    arity = head_args |> String.trim() |> arity_of()

    case Map.get(@inert_callbacks, {String.to_atom(name), arity}) do
      nil -> "nil"
      shape -> inert_socket(head_args) <> shape
    end
  end

  defp arity_of(""), do: 0
  defp arity_of(args), do: args |> String.split(",") |> length()

  # THE LAST ARGUMENT IS THE SOCKET on every one of these, and an inert body must not assume it was
  # NAMED `socket`: a kit writing `def handle_event(_e, _p, sock)` would otherwise compile to a
  # reference to a variable that does not exist.
  defp inert_socket(head_args) do
    bound = head_args |> String.split(",") |> List.last() |> to_string() |> String.trim()

    case bound in ["", "socket"] do
      true -> ""
      false -> "socket = #{String.trim_leading(bound, "_")}\n"
    end
  end

  # Helper attr/slot maps may have string OR atom keys depending on
  # whether they came straight from the converter (atom-keyed) or
  # round-tripped through Ash (`:map`-typed nested values stay
  # string-keyed). Normalize the top-level keys we use.
  defp normalize_attr_map(%{} = a) do
    %{
      name: Map.get(a, :name) || Map.get(a, "name"),
      type: Map.get(a, :type) || Map.get(a, "type") || "any",
      opts: Map.get(a, :opts) || Map.get(a, "opts") || %{},
      struct_name: Map.get(a, :struct_name) || Map.get(a, "struct_name")
    }
  end

  defp normalize_slot_map(%{} = s) do
    %{
      name: Map.get(s, :name) || Map.get(s, "name"),
      opts: Map.get(s, :opts) || Map.get(s, "opts") || %{}
    }
  end

  defp split_args_and_guard(args) when is_binary(args) do
    case String.split(args, " when ", parts: 2) do
      [head] -> {head, nil}
      [head, guard] -> {head, guard}
    end
  end

  @doc """
  Create the final module AST.

  Assembles all component parts into a complete Phoenix Component module AST.
  The generated module includes all necessary imports and uses for proper Phoenix Component operation.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and all accumulated function ASTs

  ## Returns

  Returns the complete module AST ready for compilation via `ModuleCompiler.compile_module/1`.

  ## Generated Module Structure

  The final module includes:
  - `defmodule` declaration with the target module name
  - Required Phoenix Component imports and uses
  - LiveView integration via the configured `:web_module`
  - Runtime component helper imports
  - All accumulated function definitions (info, attrs, slots, helpers, main function)

  The module is fully self-contained and ready for runtime compilation and loading.
  """
  def create_module_ast({params, functions_ast}) do
    prelude_ast =
      case params[:prelude] do
        str when is_binary(str) and byte_size(str) > 0 ->
          Code.string_to_quoted!(str,
            file: "ui_kit_prelude:#{params[:title]}"
          )

        _ ->
          nil
      end

    quote do
      defmodule unquote(params[:component_module]) do
        import Phoenix.Component.Declarative
        unquote(shape_use(params))
        unquote(unshadow_ast(params))

        import MishkaCmsCore.Runtime.LiveViewHelpers,
          only: unquote(MishkaCmsCore.Runtime.LiveViewHelpers.imports(params[:helpers]))

        # Tier-1 hardcoded imports — every UI-kit component needs these.
        alias Phoenix.LiveView.JS
        import Phoenix.LiveView.Utils, only: [random_id: 0]
        use Gettext, backend: MishkaCmsCore.Gettext

        unquote(prelude_ast)
        unquote_splicing(functions_ast)
      end
    end
  end

  @doc """
  Renders a freshly compiled stateful component once, and says whether its root will survive a
  visitor.

  ## The failure this turns into a compile failure

  `Phoenix.LiveView.Diff.component_to_rendered/3` raises

      Stateful components must have a single static HTML tag at the root

  and it raises inside a VISITOR's LiveView, where nothing contains it — the canvas has
  `contain/3`, a published page has nothing. Worse, the compile succeeded, so
  `MishkaCmsCore.Runtime.States.CompileFailureState` holds no entry and the next request does not
  short-circuit to a placeholder either: the page simply dies, again.

  `%Phoenix.LiveView.Rendered{}.root` is `false` for two sibling tags, for leading text, for `{@x}`
  alone and — the one nobody expects — for `<div :if={@x}>`, because a conditional root is not a
  static one. None of those is unusual markup, and none of them is visible as a problem on the
  canvas: `LiveViewHelpers.static_component/1` calls `render/1` as a plain function, which never
  consults `root`.

  ## Why it is a render and not a read of the AST

  Because `root` is computed by the engine, not stated by the author. Reproducing that judgement
  here would be a copy of library internals pinned to a version — the same argument that kept a
  hand-written iodata walker out of the canvas.

  ## What it supplies

  Each declared attr's default, a sentinel for one with none, `[]` for every slot, and an `id`,
  because a component asked for an attribute it declares required would raise for a reason that has
  nothing to do with its root. Wrapped in a rescue: this runs at compile time, where a rescue is
  permitted, and a component that raises for its own reasons is reported as failing to render rather
  than as failing this check.

  ## What it cannot see

  The shape of the root, and nothing else. HEEx compiles every `{…}` into a closure the diff calls
  later, so a fault inside one is not raised by `render/1` at all — which is the same reason the
  builder's canvas needs `contain/3` — and a raise in the eager `body` is already rescued by
  `guarded_body/2`, on purpose. The rescue here is a belt for what neither of those lets through.

  Answers `:ok` for a stateless component, which has no such rule.
  """
  @spec check_root(module()) :: :ok | {:error, String.t()}
  def check_root(module) when is_atom(module) do
    case stateful_module?(module) do
      false -> :ok
      true -> rooted(module)
    end
  end

  defp stateful_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__component_information__, 1) and
      module.__component_information__([:private, :stateful]) == true
  end

  defp rooted(module) do
    case module.render(probe_assigns(module)) do
      %Phoenix.LiveView.Rendered{root: true} ->
        :ok

      %Phoenix.LiveView.Rendered{} ->
        {:error,
         "Stateful components must have a single static HTML tag at the root. " <>
           "A conditional root (:if), two sibling tags, leading text or a bare expression each " <>
           "make the root dynamic, and LiveView refuses one when it renders this on a page."}

      _not_a_render ->
        :ok
    end
  rescue
    error -> {:error, "could not be rendered: " <> Exception.message(error)}
  catch
    kind, reason -> {:error, "could not be rendered: #{inspect({kind, reason})}"}
  end

  # WHAT THE PROBE HANDS IT. Declared defaults where there are any, a sentinel where there are not,
  # `[]` for every slot, and the four keys the lifecycle would have put there — so the only thing
  # this can fail on is the shape of the root.
  defp probe_assigns(module) do
    info = module.__component_information__()
    attrs = get_in(info, [:component, :attrs]) || []
    slots = get_in(info, [:component, :slots]) || []

    declared =
      Map.new(attrs, fn attr ->
        {probe_key(attr), probe_value(attr)}
      end)

    slotted = Map.new(slots, fn slot -> {probe_key(slot), []} end)

    declared
    |> Map.merge(slotted)
    |> Map.merge(%{__changed__: nil, myself: nil, flash: %{}, id: "probe", rest: %{}})
  end

  # sobelow_skip ["DOS.StringToAtom"]
  # Names read back from the module just compiled, whose attr and slot declarations made them atoms.
  defp probe_key(declaration) do
    declaration
    |> Map.get(:name, Map.get(declaration, "name", "unknown"))
    |> to_string()
    |> String.to_atom()
  end

  defp probe_value(attr) do
    opts = Map.get(attr, :opts) || Map.get(attr, "opts") || %{}

    case Map.get(opts, :default, Map.get(opts, "default")) do
      nil -> "probe"
      default -> default
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  # ONE `use` LINE IS THE WHOLE DIFFERENCE AT THIS LEVEL. Stacking both is not an option: it
  # compiles with six `conflicting behaviours` warnings, `LiveComponent` silently wins whichever
  # order they are in, and the CSP-nonce `on_mount` hook becomes dead code.
  #
  # `:live_view` stays on the stateless ones. Nothing in them calls a `Phoenix.LiveView`-only
  # function and `:html` would be more honest, but changing it is churn against every installed
  # component for no benefit here.
  defp shape_use(params) do
    case params[:stateful] == true do
      true -> quote(do: use(unquote(@web_module), :live_component))
      false -> quote(do: use(unquote(@web_module), :live_view))
    end
  end

  # A BODY THAT RAISES IS A BODY THAT DOES NOT APPLY. The `is_map/1` test below has always said so
  # for a body that RETURNS the wrong thing — "we fall back to the original assigns so we never
  # accidentally clobber it" — and a body that blows up on the way is the same statement with more
  # noise: whatever it was going to say about these assigns, it did not say it.
  #
  # A KIT EXPORTER TURNS A FUNCTION HEAD INTO ONE OF THESE. `chelekom-icon` was written
  # `def icon(%{name: "hero-" <> _} = assigns)`, which is a clause that declines to match; exported
  # as `"body": "%{name: \"hero-\" <> _} = assigns = assigns"` it becomes an assertion that RAISES,
  # and a raise here is not contained by anything on a published page — `CanvasLive.contain/2`
  # guards the editor's canvas and there is no equivalent in front of a live render, so one icon
  # whose name an author typed by hand took the visitor's whole page down.
  #
  # Around the body only, not around the template: the template's `dynamic` is a closure LiveView
  # calls when it diffs, so catching THAT would mean rendering it to iodata here and giving up change
  # tracking for every runtime component on every page. This is the half that runs eagerly, and it is
  # the half this class of failure lives in.
  #
  # Logged, because falling back silently is how a component quietly renders the wrong thing for a
  # year. Only on the failure path, so the cost is paid by the broken render and by nothing else.
  defp body_block(params, body_ast) do
    case params[:body] do
      body when is_binary(body) and body != "" -> guarded_body(params[:title], body_ast)
      _nothing_to_run -> quote(do: :ok)
    end
  end

  defp guarded_body(name, body_ast) do
    quote do
      var!(assigns) =
        (
          assigns = var!(assigns)

          new_assigns =
            try do
              unquote(body_ast)
            rescue
              error ->
                require Logger

                Logger.error(
                  "[Runtime] #{unquote(name)}'s body did not apply: " <>
                    String.slice(Exception.message(error), 0, 300) <>
                    " — rendering with the assigns it was given."
                )

                assigns
            catch
              kind, value ->
                require Logger

                Logger.error(
                  "[Runtime] #{unquote(name)}'s body #{kind} " <>
                    String.slice(inspect(value), 0, 300) <>
                    " — rendering with the assigns it was given."
                )

                assigns
            end

          if is_map(new_assigns), do: new_assigns, else: assigns
        )
    end
  end

  # A COMPONENT'S OWN HELPER MAY SHARE A NAME WITH A CORE COMPONENT, and Elixir calls that an error:
  # "imported MishkaCmsCore.CoreComponents.show_modal/1 conflicts with local function". Not a
  # warning — the module does not compile at all, and a component that does not compile renders the
  # runtime's red "Component failed to render!" box wherever it is placed, with nothing anywhere
  # saying why. `chelekom-modal` ships `show_modal/1` and `hide_modal/1`, which is exactly the pair
  # `MishkaCmsCore.CoreComponents` ships, so the kit's modal could be dropped and never rendered.
  #
  # Re-importing the same module with `except:` NARROWS what is in scope, and the local then wins
  # while every other core component stays reachable — checked rather than assumed. The alternative,
  # renaming the kit's helper, would rewrite an author's own code to avoid a collision the compiler
  # can simply stop having.
  #
  # NARROWS THE CONFIGURED `:core_components`, whichever module that is — the key exists precisely to
  # name what the base imports, and both bases here honour it. Nothing is emitted unless that module
  # really exports the name the component is defining, so a host whose base imports something else
  # gets no line at all rather than an import it never asked for.
  defp unshadow_ast(params) do
    case shadowed_helpers(params[:helpers] || []) do
      [] -> nil
      pairs -> quote(do: import(unquote(@core_components), except: unquote(pairs)))
    end
  end

  # BY NAME, ACROSS EVERY ARITY. A helper written `js \\\\ %JS{}, id` is one definition and two
  # functions, and Elixir reports the collision on the arity the DEFAULT generates — `show_modal/1`
  # for the kit's `show_modal/2`. Excluding the arity the signature computes would have missed the
  # one that actually conflicts, so every arity the core module exports under that name goes.
  # Nothing is lost by being broad here: the component defines that name itself, which is the whole
  # reason we are narrowing.
  # THROUGH A VARIABLE, NOT THE ATTRIBUTE. `@core_components` is the host's module, and when this
  # compiles as a dependency the host has not been compiled yet — so a call written against the
  # attribute is a remote call the compiler can resolve and warn about ("module is not available or
  # is yet to be defined"), for a module that is unquestionably there by the time this runs. Binding
  # it first is what makes the question a runtime one, which is what it always was; `ensure_loaded`
  # then answers it honestly, and a module that really is absent narrows nothing.
  defp shadowed_helpers(helpers) do
    module = @core_components

    exported =
      case Code.ensure_loaded(module) do
        {:module, ^module} -> apply(module, :__info__, [:functions])
        _unavailable -> []
      end

    helpers
    |> Enum.map(&helper_signature/1)
    |> Enum.flat_map(&existing_name/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn name -> Enum.filter(exported, fn {n, _a} -> n == name end) end)
    |> Enum.uniq()
  end

  # `String.to_existing_atom/1`, not `to_atom/1`: a helper name arrives from a kit bundle, and a
  # bundle is data. By the time this runs `build_helpers/1` has already interned every name it is
  # about to define, so a name that does not exist as an atom is one nothing defined — and a
  # function nobody defines cannot collide with anything.
  defp existing_name({name, _arity}) when is_binary(name) do
    [String.to_existing_atom(name)]
  rescue
    ArgumentError -> []
  end

  defp existing_name(_signature), do: []

  # Extract default values from attribute definitions.
  #
  # Processes attribute definitions to create a map of default values that will be
  # merged into assigns before rendering. Handles special cases like @rest attributes.
  #
  # ## Parameters
  #
  # - `attrs` - List of attribute definition maps
  #
  # ## Returns
  #
  # Returns a map where keys are attribute names (atoms) and values are the default values.
  #
  # ## Special Handling
  #
  # - Global attributes with name "rest" get an empty map `%{}` as default
  # - Regular attributes use their `:default` or `"default"` option value
  # - Attributes without defaults are not included in the result map
  #
  # DECLARED-AND-FALSY IS NOT THE SAME AS UNDECLARED, and saying so takes a `fetch` rather than a
  # `||`, and a generator rather than a bare assignment. A non-generator clause in a comprehension
  # is a FILTER, so `default = ...` dropped every attribute whose default was `nil` or `false` —
  # `class`, on nearly every component in the kit, and 659 declarations across that one bundle.
  #
  # What it cost: the attribute never reached `defaults_map`, so `update_many/1` never seeded it and
  # `render/1` never merged it. A page that passed the attribute rendered; the first page that left
  # it out raised `key :class not found` inside the visitor's LiveView, where nothing contains it —
  # and the compile had succeeded, so `CompileFailureState` held no entry to explain it.
  # What `LiveViewHelpers.live/3` drops on the way in and nothing else puts back. A component that
  # DECLARES an attribute of either name owns it, exactly as `synthetic_attrs` in
  # `build_attributes/1` steps aside for the same declaration.
  defp dispatch_restored(params) do
    declared_names = Enum.map(params[:attrs] || [], & &1.name)

    %{site: params[:site], component_name: params[:title]}
    |> Map.reject(fn {key, _value} -> to_string(key) in declared_names end)
  end

  # sobelow_skip ["DOS.StringToAtom"]
  # Keys are the stored component's own attr names, the ones `build_attributes/1` declares.
  defp extract_all_defaults(attrs) do
    for attr <- attrs,
        {:ok, default} <- [attr |> Map.get(:opts, []) |> declared_default(attr)],
        reduce: %{} do
      acc ->
        Map.put(acc, String.to_atom(attr.name), decoded_default(default))
    end
  end

  # The declaration path decodes the envelope through `coerce_default_for_type/2`, but this map is
  # merged into assigns at RENDER time and would put the raw envelope straight back. Same decoder,
  # both key shapes — `atomize_keys/1` has already turned `"__atom_map__"` into an atom by here.
  defp decoded_default(%{__atom_map__: pairs}) when is_list(pairs), do: decode_atom_map(pairs)
  defp decoded_default(%{"__atom_map__" => pairs}) when is_list(pairs), do: decode_atom_map(pairs)
  defp decoded_default(default), do: default

  # `{:ok, value}` for a default the author declared — including `nil` and `false` — and `:error` for
  # one they did not. Both key shapes, because a row that came through the bundle carries strings
  # and one built in the admin carries atoms.
  defp declared_default(opts, attr) when is_map(opts) do
    with :error <- Map.fetch(opts, :default),
         :error <- Map.fetch(opts, "default") do
      global_seed(attr)
    end
  end

  defp declared_default(opts, attr) when is_list(opts) and opts != [] do
    with :error <- Keyword.fetch(opts, :default), do: global_seed(attr)
  end

  defp declared_default(_opts, attr), do: global_seed(attr)

  # A global attribute is the one kind that gets a default nobody wrote: `{@rest}` in a template
  # reads an assign the caller may simply not have supplied, and `%{}` is what makes that survivable.
  # ASKED OF THE TYPE AND NOT THE NAME — `attr :html_attrs, :global` is as much a global as the
  # conventional `rest`, and seeding only the conventional one left the other raising on a caller
  # who passed no globals at all.
  defp global_seed(%{type: "global"}), do: {:ok, %{}}
  defp global_seed(_attr), do: :error

  # WHERE THE UNDECLARED KEYS GO, under the name the author actually declared. The stateless path
  # gets this from `Phoenix.Component.Declarative`, which reads the declaration; the stateful path
  # builds the map itself in `update_many/1` and so has to ask the same question. A component with
  # no global attribute keeps the conventional name, which nothing reads and nothing costs.
  # sobelow_skip ["DOS.StringToAtom"]
  # The name of the stored component's own global attr, which `build_attributes/1` declares.
  defp global_name(params) do
    case Enum.find(params[:attrs] || [], &(&1.type == "global")) do
      nil -> :rest
      attr -> String.to_atom(attr.name)
    end
  end

  # Compile template and body code into AST.
  #
  # Processes the component's body code and HEEx template into executable AST.
  # Body code is executed before rendering, while template produces the final output.
  #
  # ## Parameters
  #
  # - `params` - Component parameters containing :body and :template
  #
  # ## Returns
  #
  # Returns a tuple `{template_ast, body_ast}` where:
  # - `template_ast` - Compiled HEEx template AST or empty sigil_H
  # - `body_ast` - Compiled body code AST or `nil`
  #
  # ## Template Compilation
  #
  # Uses Phoenix.LiveView.TagEngine with proper context and options:
  # - Proper file naming for debugging
  # - Import context via make_env/0
  # - Trimming and HTML engine integration
  defp compile_template_and_body(params) do
    body_ast =
      if params[:body] && params[:body] != "" do
        Code.string_to_quoted!(params[:body])
      else
        quote do: nil
      end

    # Compile template using EEx with Phoenix LiveView engine
    template_ast =
      if params[:template] && params[:template] != "" do
        opts = [
          line: 1,
          indentation: 0,
          file: "mishka_cms_runtime_component_#{params[:title]}_#{params[:site]}",
          caller: make_env(),
          trim: true,
          tag_handler: Phoenix.LiveView.HTMLEngine
        ]

        params[:template]
        |> MishkaCmsCore.Runtime.PageBuilder.Visibility.strip()
        |> Phoenix.LiveView.TagEngine.compile(opts)
      else
        quote do: ~H""
      end

    {template_ast, body_ast}
  end

  @doc """
  Create environment for template compilation.

  Builds a compilation environment with necessary imports for HEEx template processing.
  Ensures that Phoenix HTML, Component, and LiveView helpers are available during template compilation.

  ## Returns

  Returns a `Macro.Env` struct with all required imports defined for proper template compilation.

  ## Imported Modules

  - `Phoenix.HTML` - HTML generation helpers
  - `Phoenix.Component` - Component helpers and sigil_H

  Failed imports are logged but don't stop the compilation process, ensuring robustness
  even when some modules aren't available.
  """
  def make_env do
    imports = [
      Phoenix.HTML,
      Phoenix.Component,
      Phoenix.LiveView.Helpers
    ]

    Enum.reduce(imports, __ENV__, fn module, env ->
      with true <- :erlang.module_loaded(module),
           {:ok, env} <- define_import(env, module) do
        env
      else
        {:error, error} ->
          Logger.warning("failed to import #{module}: #{error}")
          env

        _ ->
          env
      end
    end)
  end

  # Define import in the compilation environment.
  #
  # Safely imports a module into the given environment for template compilation.
  # Used by make_env/0 to set up the necessary imports.
  #
  # ## Parameters
  #
  # - `env` - The Macro.Env to import into
  # - `module` - The module to import
  #
  # ## Returns
  #
  # Returns `{:ok, updated_env}` on success or `{:error, reason}` on failure.
  defp define_import(env, module),
    do: MishkaCmsCore.Runtime.Compilers.Shared.define_import(env, module)

  # Convert string attribute type to atom with struct handling.
  #
  # Converts component attribute type strings to proper atoms for Phoenix Component
  # attribute declarations. Handles special case for struct types.
  #
  # ## Parameters
  #
  # - `component_type` - String type name (e.g., "string", "struct")
  # - `struct_name` - Module name for struct types
  #
  # ## Returns
  #
  # Returns the appropriate type atom or module name for attr declarations.
  # Struct-typed attrs come pre-resolved with full module paths
  # (`Phoenix.LiveView.JS`, not the bare alias `JS`) — the converter
  # walks the source's `alias` declarations and emits the fully-
  # qualified name. So `Module.concat([struct_name])` always lands on
  # a real loadable module without needing a runtime lookup table.
  defp attr_type_to_atom(component_type, struct_name) when component_type == "struct" do
    Module.concat([struct_name])
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp attr_type_to_atom(component_type, _struct_name)
       when component_type in @supported_attr_types do
    String.to_atom(component_type)
  end

  # Filter attribute options to only include valid Phoenix Component options.
  #
  # Phoenix Components only accept specific options for attributes. This function
  # filters out any invalid options to prevent compilation errors.
  #
  # ## Parameters
  #
  # - `opts` - Options map, keyword list, or other value
  #
  # ## Returns
  #
  # Returns a keyword list containing only valid Phoenix Component attribute options.
  #
  # ## Valid Options
  #
  # - `:required`, `:default`, `:examples`, `:values`, `:doc`, `:include`, `:exclude`
  # JSON cannot encode atoms, so the converter stringifies atom defaults
  # (`:natural` → `"natural"`). Phoenix's attr/3 macro validates the
  # default's type at compile time and rejects strings for `:atom` typed
  # attrs. Coerce the string back to an atom here.
  #
  # `:values` and `:examples` arrive the same way, as lists of strings, and Phoenix checks every
  # entry against the type too ("expected the values for attr :kind to be an :atom"), so each string
  # in them is coerced as the default is.
  defp coerce_default_for_type(opts, :atom) do
    opts
    |> atom_option(:default)
    |> atom_option(:values)
    |> atom_option(:examples)
  end

  # `:map` defaults like `%{kind: "toast"}` round-trip through the
  # bundle as `%{"__atom_map__" => [["k", v], ...]}` (atoms encoded
  # with leading `:` sentinel — see exporter). Decode back here.
  # The envelope's own key arrives ATOMIZED. `build_module/1` runs `atomize_keys/1` over the whole
  # params map before anything else, so `"__atom_map__"` is `:__atom_map__` by the time it gets here
  # — and matching only the string form meant this decode never ran on a real bundle. The component
  # then received the envelope itself as the attribute's value, and the first thing that
  # interpolated it raised `String.Chars not implemented for Map`.
  defp coerce_default_for_type(opts, :map) do
    case Keyword.fetch(opts, :default) do
      {:ok, %{"__atom_map__" => pairs}} when is_list(pairs) ->
        Keyword.put(opts, :default, decode_atom_map(pairs))

      {:ok, %{__atom_map__: pairs}} when is_list(pairs) ->
        Keyword.put(opts, :default, decode_atom_map(pairs))

      _ ->
        opts
    end
  end

  # Struct-typed attrs (e.g. `attr :on_show, Phoenix.LiveView.JS,
  # default: %JS{}` in the original source). The converter cannot
  # encode `%JS{}` in JSON, so it drops the default — but components
  # then call `JS.remove_class(@on_show, ...)` and `JS.remove_class`
  # has no clause for `nil`. Reinstate a zero-arity struct default
  # `%Module{}` when the attr type points at a real, loadable struct
  # module and no other default was provided.
  # A struct default cannot be written to JSON, so the bundle carries the FACT that there was one —
  # `default_struct: true` — and this rebuilds it from the attribute's declared type. It used to
  # rebuild one for every struct-typed attribute that arrived without a default, which cannot tell
  # `attr :on_show, JS, default: %JS{}` (dropped in transit) from `attr :field, FormField` (never had
  # one). For `JS` the guess is harmless. For `Phoenix.HTML.FormField` it is not: an empty struct is
  # not "no field", it is a field whose `form` is nil, and every field component in the kit opens by
  # calling `Phoenix.Component.used_input?/1` on it — which reads `form.params` and raises
  # `BadMapError` on the spot. An attribute the author gave no default now gets none.
  defp coerce_default_for_type(opts, struct_module) when is_atom(struct_module) do
    cond do
      Keyword.has_key?(opts, :default) ->
        Keyword.delete(opts, :default_struct)

      Keyword.get(opts, :default_struct) == true and struct_module?(struct_module) ->
        opts |> Keyword.delete(:default_struct) |> Keyword.put(:default, struct(struct_module))

      true ->
        Keyword.delete(opts, :default_struct)
    end
  end

  defp coerce_default_for_type(opts, _type), do: opts

  # sobelow_skip ["DOS.StringToAtom"]
  # The default, values and examples of a stored component's `:atom` attr; Phoenix's `attr/3` checks
  # them against the type, so they have to be atoms.
  defp atom_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) ->
        Keyword.put(opts, key, String.to_atom(value))

      {:ok, values} when is_list(values) ->
        Keyword.put(opts, key, Enum.map(values, &atom_entry/1))

      _absent_or_atom ->
        opts
    end
  end

  # sobelow_skip ["DOS.StringToAtom"]
  # One entry of a stored `:atom` attr's `values` or `examples`, as in `atom_option/2` above.
  defp atom_entry(value) when is_binary(value), do: String.to_atom(value)
  defp atom_entry(value), do: value

  defp struct_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0)
  end

  # Decode a JSON `__atom_map__` envelope back into an atom-keyed map.
  # Strings prefixed with `:` were originally atoms; all other values
  # pass through unchanged.
  defp decode_atom_map(pairs) when is_list(pairs) do
    Enum.into(pairs, %{}, fn
      [k, v] -> {decode_atom_term(k), decode_atom_term(v)}
      {k, v} -> {decode_atom_term(k), decode_atom_term(v)}
    end)
  end

  # sobelow_skip ["DOS.StringToAtom"]
  # An atom the kit exporter wrote as `":name"` in a stored attr's map default, decoded back.
  defp decode_atom_term(":" <> rest), do: String.to_atom(rest)

  defp decode_atom_term(list) when is_list(list), do: Enum.map(list, &decode_atom_term/1)

  defp decode_atom_term(other), do: other

  # `:default_struct` is not one of Phoenix's options and never reaches `attr/3` — it survives this
  # filter only so `coerce_default_for_type/2` can read it, and every branch of that function deletes
  # it again.
  @valid_attr_opt_keys [
    :required,
    :default,
    :default_struct,
    :examples,
    :values,
    :doc,
    :include,
    :exclude
  ]

  # Helper attrs round-trip from DB with STRING keys (`%{"default" =>
  # "small"}`); top-level attrs that flow through Ash arrive atom-
  # keyed. Coerce both shapes into an atom-keyed keyword list, then
  # filter to the keys Phoenix's `attr/3` macro accepts.
  defp ignore_invalid_attr_opts(opts) when is_map(opts) do
    opts
    |> Enum.flat_map(fn {k, v} ->
      key = if is_atom(k), do: k, else: safe_atomize(k)
      if key in @valid_attr_opt_keys, do: [{key, v}], else: []
    end)
  end

  defp ignore_invalid_attr_opts(opts) when is_list(opts) do
    Enum.flat_map(opts, fn
      {k, v} when is_atom(k) ->
        if k in @valid_attr_opt_keys, do: [{k, v}], else: []

      {k, v} when is_binary(k) ->
        case safe_atomize(k) do
          nil -> []
          atom -> if atom in @valid_attr_opt_keys, do: [{atom, v}], else: []
        end

      _ ->
        []
    end)
  end

  defp ignore_invalid_attr_opts(_opts), do: []

  # `String.to_existing_atom/1` won't crash on unknown strings — but
  # @valid_attr_opt_keys atoms exist at this point (they're literal
  # atoms in this module), so existing-atom lookup is safe and avoids
  # leaking unknown atoms.
  defp safe_atomize(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  # Filter slot options to only include valid Phoenix Component slot options.
  #
  # Phoenix Components only accept specific options for slots. This function
  # filters out any invalid options to prevent compilation errors.
  #
  # ## Parameters
  #
  # - `opts` - Options map, keyword list, or other value
  #
  # ## Returns
  #
  # Returns a keyword list containing only valid Phoenix Component slot options.
  #
  # ## Valid Slot Options
  #
  # - `:required`, `:validate_attrs`, `:doc`
  defp ignore_invalid_slot_opts(opts) when is_map(opts) do
    opts
    |> Enum.into([])
    |> Keyword.take([:required, :validate_attrs, :doc])
  end

  defp ignore_invalid_slot_opts(opts) when is_list(opts) do
    Keyword.take(opts, [:required, :validate_attrs, :doc])
  end

  defp ignore_invalid_slot_opts(_opts) do
    []
  end
end
