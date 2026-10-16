# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.DelegatingClauseTest do
  @moduledoc """
  The clause a kit uses to turn `field={@form[:email]}` into a rendered, validated input.

  A kit's field component does not read a form field directly. It opens with a clause that
  NORMALISES one — deriving `name`, `value`, `id` and the translated `errors` from a
  `%Phoenix.HTML.FormField{}` — and then hands the result back to itself for one of the rendering
  clauses to draw:

      def text_field(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
        errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

        assigns
        |> assign(field: nil, id: assigns.id || field.id)
        |> assign(:errors, Enum.map(errors, &translate_error(&1)))
        |> assign_new(:name, fn -> field.name end)
        |> assign_new(:value, fn -> field.value end)
        |> text_field()
      end

  Having no `~H`, that clause used to be exported as an ordinary helper: it arrived on the compiled
  module under its own name, nothing called it, and the dispatch this compiler builds had no arrow
  for it. So a page passing `field=` fell through to a rendering clause that reads `@name`, and every
  field component in every kit answered `(KeyError) key :name not found`. Validation messages were
  not merely absent — they were unreachable.

  It is a real clause now, and the two halves of the contract are tested separately: what the bundle
  has to SAY, and what this compiler has to DO with it. The compiler half uses a hand-written
  component rather than Chelekom's, so it states the contract rather than restating one kit's source.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.ComponentCompiler

  @moduletag :unit

  @bundle_path MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  setup_all do
    bundle = @bundle_path |> File.read!() |> Jason.decode!()
    {:ok, bundle: bundle, components: bundle["components"]}
  end

  defp field_components(components) do
    Enum.filter(components, fn component ->
      Enum.any?(component["attrs"] || [], &(&1["name"] == "field"))
    end)
  end

  defp clauses(component), do: get_in(component, ["extra", "clauses"]) || []

  describe "what the bundle says" do
    test "every component that accepts a form field ships a delegating clause", %{
      components: components
    } do
      missing =
        for component <- field_components(components),
            delegating = Enum.filter(clauses(component), & &1["delegates"]),
            delegating == [],
            do: component["name"]

      assert missing == []
      assert length(field_components(components)) >= 20
    end

    # ORDER IS THE WHOLE POINT. A rendering clause that matches anything — the catch-all every one of
    # these ends with — will swallow a call carrying `field=` if it is tried first, and then the
    # normalisation never runs.
    test "and dispatches it before any clause that renders", %{components: components} do
      for component <- field_components(components) do
        list = clauses(component)
        delegating = Enum.find_index(list, & &1["delegates"])
        rendering = Enum.find_index(list, &(!&1["delegates"]))

        assert delegating < rendering, "#{component["name"]} dispatches rendering first"
      end
    end

    test "a delegating clause carries a body and no template", %{components: components} do
      for component <- field_components(components),
          clause <- Enum.filter(clauses(component), & &1["delegates"]) do
        assert is_nil(clause["template"]), "#{component["name"]} delegating clause has a template"
        assert is_binary(clause["body"]) and clause["body"] != ""
      end
    end

    # The self-call is what the CONSUMER supplies, by re-entering the function it just normalised the
    # assigns for. Left in the body it would be a call to a function the compiled module does not
    # have under that name.
    test "and no trailing self-call, because re-dispatching is the consumer's job", %{
      components: components
    } do
      for component <- field_components(components),
          clause <- Enum.filter(clauses(component), & &1["delegates"]) do
        function = get_in(component, ["extra", "function"])

        refute String.match?(clause["body"], ~r/\|>\s*#{Regex.escape(function)}\(\)\s*$/),
               "#{component["name"]} still ends by calling itself"
      end
    end

    # The same clause used to arrive here instead, where it was dead weight: a public function on the
    # module that nothing calls and that would not terminate if anything did.
    test "and it is no longer also shipped as a helper", %{components: components} do
      duplicated =
        for component <- field_components(components),
            function = get_in(component, ["extra", "function"]),
            Enum.any?(component["helpers"] || [], &(&1["name"] == function)),
            do: component["name"]

      assert duplicated == []
    end

    # A struct default cannot be written to JSON. Dropping it silently made two different things look
    # the same, and the consumer had to guess for both.
    test "a struct default says it was there rather than being silently dropped", %{
      components: components
    } do
      marked =
        for component <- components,
            attr <- component["attrs"] || [],
            (attr["opts"] || %{})["default_struct"] == true,
            do: {component["name"], attr["name"]}

      assert marked != []

      form_fields =
        for component <- components,
            attr <- component["attrs"] || [],
            attr["name"] == "field",
            do: (attr["opts"] || %{})["default_struct"]

      assert Enum.all?(form_fields, &is_nil/1)
    end

    # `file_field`'s first rendering clause was the dropzone, which cannot render without a live
    # socket — and being first, it was what a builder read to decide what a dropped card needs.
    test "the file field leads with the input it can render from attributes alone", %{
      components: components
    } do
      component = Enum.find(components, &(&1["name"] == "chelekom-file-field"))

      assert component["template"] =~ ~s(type="file")
      assert component["template"] =~ "<input"
    end
  end

  describe "what the compiler does with it" do
    # A component of this shape, written here rather than taken from a kit, so the test states the
    # contract a kit has to meet instead of restating Chelekom's source.
    defp probe_params(title) do
      %{
        title: title,
        component_module: Module.concat([Macro.camelize(String.replace(title, "-", "_"))]),
        site: nil,
        template: ~s(<input name={@name} value={@value} id={@id} />),
        body: nil,
        attrs: [
          %{name: "id", type: "string", opts: %{"default" => nil}},
          %{name: "name", type: "any", opts: %{}},
          %{name: "value", type: "any", opts: %{}},
          %{name: "errors", type: "list", opts: %{"default" => []}},
          %{
            name: "field",
            type: "struct",
            struct_name: "Phoenix.HTML.FormField",
            opts: %{}
          }
        ],
        slots: [],
        helpers: [],
        extra: %{},
        clauses: [
          %{
            match: "%{field: %Phoenix.HTML.FormField{} = field} = assigns",
            guard: nil,
            delegates: true,
            template: nil,
            body: """
            assigns
            |> Phoenix.Component.assign(field: nil, id: assigns.id || field.id)
            |> Phoenix.Component.assign(:errors, Enum.map(field.errors, fn {message, _opts} -> message end))
            |> Phoenix.Component.assign_new(:name, fn -> field.name end)
            |> Phoenix.Component.assign_new(:value, fn -> field.value end)
            """
          },
          %{
            match: nil,
            guard: nil,
            delegates: false,
            template:
              ~s|<input name={@name} value={@value} id={@id} data-errors={Enum.join(@errors, ", ")} />|
          }
        ]
      }
    end

    defp compile!(title) do
      params = probe_params(title)

      [{module, _binary} | _rest] =
        params |> ComponentCompiler.build_module() |> Code.compile_quoted()

      {module, String.to_existing_atom(title)}
    end

    defp render(module, function, assigns) do
      module
      |> apply(function, [Map.put(assigns, :__changed__, nil)])
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end

    test "a form field becomes a name, a value and an id" do
      {module, function} = compile!("probe-delegating-basics")
      form = Phoenix.Component.to_form(%{"email" => "ada@example.com"}, as: :contact)

      html = render(module, function, %{field: form[:email]})

      assert html =~ ~s(name="contact[email]")
      assert html =~ ~s(value="ada@example.com")
      assert html =~ ~s(id="contact_email")
    end

    test "and its errors arrive where the component draws them" do
      {module, function} = compile!("probe-delegating-errors")

      form =
        Phoenix.Component.to_form(%{"email" => "nope"},
          as: :contact,
          errors: [email: {"is not a valid address", []}]
        )

      assert render(module, function, %{field: form[:email]}) =~ "is not a valid address"
    end

    # `assign_new/3` fills a key only when it is ABSENT, so a caller that names the field itself
    # keeps their own name. This is why these attributes must not be given defaults.
    test "an explicit name survives the normalisation" do
      {module, function} = compile!("probe-delegating-explicit")
      form = Phoenix.Component.to_form(%{"email" => "x"}, as: :contact)

      html = render(module, function, %{field: form[:email], name: "chosen_by_hand"})

      assert html =~ ~s(name="chosen_by_hand")
    end

    # Re-entry terminates because normalising clears `field`, so the clause that matched cannot match
    # again — the same guarantee the multi-clause Phoenix function had before it was flattened into a
    # `case`. A component that recursed for ever would hang the render rather than fail it.
    test "re-entry happens exactly once" do
      {module, function} = compile!("probe-delegating-terminates")
      form = Phoenix.Component.to_form(%{"email" => "x"}, as: :contact)

      task = Task.async(fn -> render(module, function, %{field: form[:email]}) end)

      assert {:ok, html} = Task.yield(task, 5_000) || Task.shutdown(task)
      assert html =~ "<input"
    end

    test "and a caller who never mentions a field is untouched by any of it" do
      {module, function} = compile!("probe-delegating-plain")

      html = render(module, function, %{name: "plain", value: "", id: "plain"})

      assert html =~ ~s(name="plain")
    end

    # TERMINATION IS NOT THE BUNDLE'S TO PROMISE. `MishkaChelekom.CmsBundleExporter`'s detector
    # checks only the SHAPE — one map-patterned argument and a self-call — never that the body
    # narrows the pattern it matched on. A third-party clause that normalises something it does not
    # clear re-enters with assigns its own pattern still matches, and `render/1` spins until the
    # LiveView dies on memory, taking the visitor's page with it. So the bound lives here: a
    # delegating clause runs at most once per render, and a second entry falls through to a clause
    # that draws something.
    defp looping_params(title) do
      title
      |> probe_params()
      |> Map.put(:clauses, [
        %{
          match: "%{value: _value} = assigns",
          guard: nil,
          delegates: true,
          template: nil,
          body: ~s|Phoenix.Component.assign(assigns, :id, "looped")|
        },
        %{
          match: nil,
          guard: nil,
          delegates: false,
          template: ~s|<input name={@name} value={@value} id={@id} />|
        }
      ])
    end

    test "a clause that never clears its own pattern still renders instead of hanging" do
      params = looping_params("probe-delegating-unbounded")

      [{module, _binary} | _rest] =
        params |> ComponentCompiler.build_module() |> Code.compile_quoted()

      task =
        Task.async(fn ->
          render(module, :"probe-delegating-unbounded", %{
            name: "n",
            value: "v",
            id: "given",
            errors: []
          })
        end)

      assert {:ok, html} = Task.yield(task, 5_000) || Task.shutdown(task)
      assert html =~ ~s(id="looped")
    end
  end
end
