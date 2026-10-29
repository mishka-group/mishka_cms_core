# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.TemplateCompilesTest do
  @moduledoc """
  Markup HEEx will not take, refused where every writer meets it.

  `Validations.PageCodeCompiles` has done this for a `Page` since it existed, which is why a page
  cannot be seeded broken. A layout, a component and an error page had nothing: the row was stored,
  `RuntimeStatus` reported `Ready`, the compile then failed into `CompileFailureState`, and the site
  went on serving the module it already had. Nobody was told at any point.

  `MishkaCmsBuilderWeb.Live.EditorSectionsTest` covers the editor's own gate. This is the other half —
  a seed, an import, the JSON API and the list page's form all write through these actions and none
  of them go anywhere near the builder.

  The three shapes below are exactly the ones that survive the tokenizer AND the serializer:
  `to_heex/1` parses every expression, so `{@a + }` is already caught; what nothing read was the
  HEEx itself.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  @moduletag :integration

  @good ~s(<section id="root"><h1>Title</h1></section>)
  @good_layout ~s(<body class="page"><main>{@inner_content}</main></body>)

  @bad_attr ~s(<section id="root"><div :foo={@a}>x</div></section>)
  @bad_for ~s(<section id="root"><div :for={@a}>x</div></section>)
  @bad_slot ~s(<section id="root"><:header>x</:header></section>)

  setup do
    {:ok, site: create_site!()}
  end

  describe "a layout" do
    test "is stored when its markup compiles", %{site: site} do
      assert %{} = create_layout!(site_id: site.id, template: @good_layout)
    end

    for {name, markup} <- [
          {"an attribute HEEx does not have", @bad_attr},
          {"a :for with no generator", @bad_for},
          {"a slot entry outside a component", @bad_slot}
        ] do
      test "is refused for #{name}", %{site: site} do
        assert_raise Ash.Error.Invalid, fn ->
          create_layout!(site_id: site.id, template: unquote(markup))
        end
      end
    end

    test "and an update is refused the same way", %{site: site} do
      layout = create_layout!(site_id: site.id, template: @good_layout)

      assert {:error, %Ash.Error.Invalid{} = error} =
               layout
               |> Ash.Changeset.for_update(:update, %{template: @bad_attr}, tenant: site.id)
               |> Ash.update(authorize?: false, tenant: site.id)

      assert Exception.message(error) =~ "unsupported attribute",
             "it was refused for some other reason than the markup"
    end

    # A ROW WHOSE MARKUP PREDATES THIS MUST STAY EDITABLE. Refusing every other field on it because
    # the template is old would lock the author out of the screen the template gets fixed in.
    test "but a write that does not touch the template is not judged on it", %{site: site} do
      layout = create_layout!(site_id: site.id, template: @good_layout)

      assert {:ok, renamed} =
               layout
               |> Ash.Changeset.for_update(:update, %{description: "renamed"}, tenant: site.id)
               |> Ash.update(authorize?: false, tenant: site.id)

      assert renamed.description == "renamed"
    end
  end

  describe "a component" do
    test "is stored when its markup compiles", %{site: site} do
      assert %{} = create_component!(site_id: site.id, name: "tc-ok", template: @good)
    end

    test "is refused when it does not", %{site: site} do
      assert_raise Ash.Error.Invalid, fn ->
        create_component!(site_id: site.id, name: "tc-bad", template: @bad_attr)
      end
    end
  end

  describe "an error page" do
    test "is stored when every status compiles", %{site: site} do
      assert %{} =
               create_error_page!(
                 site_id: site.id,
                 error_pages: [
                   %{"status" => 404, "template" => @good, "layout" => %{}},
                   %{"status" => 500, "template" => @good, "layout" => %{}}
                 ]
               )
    end

    # THE FAULT NAMES ITS STATUS, because "line 1" means nothing when the reader has five documents
    # open in one record.
    test "is refused when one of them does not, and says which", %{site: site} do
      error =
        assert_raise Ash.Error.Invalid, fn ->
          create_error_page!(
            site_id: site.id,
            error_pages: [
              %{"status" => 404, "template" => @good, "layout" => %{}},
              %{"status" => 500, "template" => @bad_attr, "layout" => %{}}
            ]
          )
        end

      assert Exception.message(error) =~ "500"
    end
  end

  # A ROOT LAYOUT IS A DIFFERENT LANGUAGE IN THE SAME RECORD. `ErrorCompiler` compiles it with
  # `EEx.compile_string/2` and the classic `Phoenix.HTML.Engine`, precisely because it relies on EEx
  # interpolation inside an attribute — which HEEx rejects and which the shipped seeds use. Judging it
  # as HEEx broke `mix seeds` on the first error page, which is how this was found.
  describe "an error page's root layout" do
    @eex_root ~S|<html><head><meta name="csrf-token" content="<%= token() %>" /></head><body><%= @inner_content %></body></html>|

    test "is EEx, and is not judged as HEEx", %{site: site} do
      assert %{} =
               create_error_page!(
                 site_id: site.id,
                 root_layout_template: @eex_root,
                 error_pages: [%{"status" => 404, "template" => @good, "layout" => %{}}]
               )
    end

    test "while the per-status template beside it still is", %{site: site} do
      assert_raise Ash.Error.Invalid, fn ->
        create_error_page!(
          site_id: site.id,
          root_layout_template: @eex_root,
          error_pages: [%{"status" => 404, "template" => @bad_attr, "layout" => %{}}]
        )
      end
    end
  end

  # AND THE CORPUS THIS RUNS AGAINST IS REAL. Every layout, component, page and error page the seeds
  # produce passes; a validation that refused any of them would be a validation nobody could ship.
  describe "the shipped fixtures" do
    test "a factory layout, component and error page all pass", %{site: site} do
      assert create_layout!(site_id: site.id)
      assert create_component!(site_id: site.id, name: "tc-factory")
      assert create_error_page!(site_id: site.id)
    end
  end
end
