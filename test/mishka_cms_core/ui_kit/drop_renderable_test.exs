defmodule MishkaCmsCore.UiKit.DropRenderableTest do
  @moduledoc """
  Every component in every installed kit must survive being DROPPED, with nothing filled in.

  The editor's own answer to "what did I just place" is whatever the palette writes, and the palette
  writes a component with only the attributes it cannot render without. That is a different markup
  from any example the kit ships, from anything the wizard composes, and from anything a person would
  type — which is why the two renderability suites next door never saw the twelve components that
  did not survive it.

  Twelve of a hundred and thirty-six, in three separate causes:

    * NINE forwarded a seeded `icon=""` to `chelekom-icon`, whose own body is
      `%{name: "hero-" <> _} = assigns` — a function head the kit exporter turned into an assertion,
      so a name that is not an icon raises `MatchError` rather than declining to match. `""` is
      truthy in Elixir, so every `:if={@icon}` guard written for `nil` let it straight through. They
      were seeded at all because `default: nil` and "no default" were the same question to
      `PaletteEntry.seed?/3`, and the kit declares `default: nil` on 584 attributes;
    * `chelekom-icon` itself, which declares `name` required with no default and was therefore
      seeded the blank the assertion rejects;
    * `chelekom-modal`, which never compiled at all: it ships `show_modal/1` and `hide_modal/1`, the
      core components ship the same two, and Elixir refuses to compile a module whose local function
      collides with an import. Nothing said so — a module that does not compile renders the runtime's
      red "Component failed to render!" box wherever it is placed.

  Rendering is through `LiveViewCompiler.render_template/2`, which is the PUBLISHED PAGE's path: the
  same tag handler, the same imports, `<.component>` resolving to the real compiled module. The
  canvas has `CanvasLive.contain/2` around it and a live page has nothing, so this is the harsher of
  the two and the one worth asserting.

  A red placeholder is not rendering, and neither is an empty string. Both are failures here.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.States.CompileFailureState
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  @moduletag timeout: 300_000

  # THE PALETTE'S OWN SHAPE, not a convenient subset. `furnishing` is the difference between a
  # carousel dropped with three real slides and one dropped with `<:slide>First slide</:slide>`,
  # whose slot then reads an `image` nobody supplied — a `KeyError` that is an artefact of building
  # the entry by hand and not a bug in the kit. An entry missing a key the palette carries invents
  # failures as readily as it hides them.
  defp entry(component) do
    %{
      id: component.id,
      key: component.name,
      name: component.name,
      template: component.template,
      type: component.type || "general",
      description: component.description,
      slots: component.slots || [],
      attrs: component.attrs || [],
      reads: PaletteEntry.reads(component),
      furnishing: component.furnishing,
      form: component.form_meta,
      icon: component.icon_name,
      kit: component.ui_kit_label,
      doc_url: component.doc_url,
      has_examples?: component.has_examples == true,
      examples: [],
      global?: is_nil(component.site_id)
    }
  end

  defp installed do
    Component
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.load([
      :icon_name,
      :has_examples,
      :furnishing,
      :doc_url,
      :ui_kit_label,
      :form_meta
    ])
    |> Ash.read!(authorize?: false, page: [limit: 1000])
    |> Map.fetch!(:results)
    |> Enum.sort_by(& &1.name)
  end

  # THE MEMO IS GLOBAL AND THE SANDBOX IS NOT. `LiveViewHelpers` remembers a module that would not
  # resolve so the next render is an ETS lookup instead of a database read, and that table belongs to
  # the node, not to the test: another test that installed a broken `chelekom-card`, or read one
  # before its row existed, leaves a verdict this suite would then report as the KIT's component
  # failing to build. Cleared per component, immediately before rendering it, so a component that
  # really will not compile still fails here — it re-records on the way through.
  defp dropped(component) do
    "Component"
    |> then(&CompilerHelpers.module_name(component.name, "Global", &1))
    |> CompileFailureState.clear()

    markup = PaletteEntry.template(entry(component), "Global")

    outcome =
      case LiveViewCompiler.render_template(markup, %{}) do
        {:error, message} ->
          {:raised, message |> String.split("\n") |> Enum.take(4) |> Enum.join(" | ")}

        html when is_binary(html) ->
          cond do
            html =~ "Component failed to render!" -> {:unresolved, "the module did not build"}
            String.trim(html) == "" -> {:empty, "rendered nothing at all"}
            true -> :ok
          end
      end

    {component.name, outcome, markup}
  end

  describe "every component the palette can place" do
    setup do
      UiKitHandler.install_chelekom!(site_id: nil)
      :ok
    end

    test "is really there to check" do
      assert length(installed()) >= 100
    end

    test "renders when it is dropped with nothing filled in" do
      broken =
        installed()
        |> Enum.map(&dropped/1)
        |> Enum.reject(&match?({_name, :ok, _markup}, &1))
        |> Enum.map(fn {name, {kind, detail}, markup} ->
          "#{name} (#{kind}): #{detail}\n      placed as: #{String.slice(markup, 0, 200)}"
        end)

      assert broken == [],
             "#{length(broken)} component(s) do not survive being dropped:\n" <>
               Enum.join(broken, "\n")
    end

    # A BLANK IS NOT ALWAYS WRONG — a form field is placed with `name=""` and `value=""` on purpose,
    # and `PageForms.FormPlacement` rewrites both into bindings the moment the field joins a form. An
    # icon is placed blank too, so that the editor can ask for one. What makes all of that safe is
    # the guarantee below: a blank the component REFUSES must not take the page down.
    #
    # `chelekom-icon` is the one that refuses. Its body is `%{name: "hero-" <> _} = assigns` — a
    # function head the kit exporter turned into an assertion — so before the compiler caught a
    # raising body, a blank name was a MatchError with nothing in front of it on a published page.
    test "a required value left blank does not raise on a published page" do
      for name <- ["", "fa-star", "not-an-icon"] do
        html =
          LiveViewCompiler.render_template(
            ~s(<.component component_name="chelekom-icon" site="Global" name="#{name}" />),
            %{}
          )

        assert is_binary(html), "name=#{inspect(name)} still raises: #{inspect(html)}"
        assert html =~ "<span", "name=#{inspect(name)} rendered nothing at all: #{html}"
      end
    end

    # `chelekom-icon` IS PLACED BLANK, ON PURPOSE, and that is the whole of report 13. Seeding a real
    # icon stopped the crash by switching off the editor's own answer: a blank required value is what
    # makes the canvas draw "needs name — click to choose name", what marks the row Required in the
    # Inspector, and what refuses the publish. An author got a star they had not chosen and nothing
    # ever asked them to choose one.
    #
    # The crash is answered where it belongs — `ComponentCompiler` catches a body that refuses its
    # assigns — which is what makes leaving this blank safe.
    test "an icon is placed blank, so the editor can ask for one" do
      icon = Enum.find(installed(), &(&1.name == "chelekom-icon"))
      assert icon, "the kit has no chelekom-icon; this test is checking nothing"

      markup = PaletteEntry.template(entry(icon), "Global")

      assert markup =~ ~s( name=""), "the icon was placed already answered: #{markup}"
    end

    # A PREVIEW HAS NOBODY TO WAIT FOR. The wizard and the palette's hover card have to show the
    # component, and "needs name" is not the component — so the same attribute is seeded a real icon
    # there, which is the split every other required string in this module already makes.
    test "but a preview of one shows a real icon" do
      icon = Enum.find(installed(), &(&1.name == "chelekom-icon"))
      seeded = PaletteEntry.seeded(entry(icon), [], :preview)

      assert seeded =~ ~r/name="hero-[a-z0-9-]+"/,
             "a previewed icon has no icon to show: #{seeded}"
    end
  end
end
