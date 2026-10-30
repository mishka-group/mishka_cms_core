# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.DropRenderableTest do
  @moduledoc """
  A blank the kit's icon refuses must not take a published page down.

  The visual editor places a component with only the attributes it cannot render without, and an
  icon is placed blank on purpose so that the editor can ask for one. What makes that safe is on this
  side: `chelekom-icon`'s own body is `%{name: "hero-" <> _} = assigns` — a function head the kit
  exporter turned into an assertion — so a name that is not an icon raises `MatchError` rather than
  declining to match. The compiler catches a body that refuses its assigns, and the page draws an
  empty icon instead of the runtime's red "Component failed to render!" box.

  Rendering is through `LiveViewCompiler.render_template/2`, which is the PUBLISHED PAGE's path: the
  same tag handler, the same imports, `<.component>` resolving to the real compiled module. What the
  palette writes for every component of the kit, and that each of those survives being dropped, is
  asserted where the palette lives, in the editor's package.
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
    |> MishkaCmsCore.EveryPage.read!(authorize?: false)
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
