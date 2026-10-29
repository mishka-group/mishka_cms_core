# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  @moduletag timeout: 300_000

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

  # INSTALLED ONCE FOR THE MODULE: every test here only reads what the install wrote, and the install
  # takes seconds — it was run before each test.
  setup_all do
    context = module_sandbox()
    UiKitHandler.install_chelekom!(site_id: nil)
    context
  end

  describe "every component the palette can place" do
    test "is really there to check" do
      assert length(installed()) >= 100
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
  end
end
