# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.ClientNamesTest do
  @moduledoc """
  A name the browser sends is looked up among the names the editor knows, never made into an atom.

  A bucket, a panel or a rail that is not one the editor has used to raise out of
  `String.to_existing_atom/1` and take the whole editing session down; now the event is answered
  with the editor as it was, and no atom exists for the name.
  """
  use MishkaCmsCore.BuilderLiveCase

  setup %{conn: conn, site: site} do
    page = create_page!(site_id: site.id, template: ~s(<section><h1>Hi</h1></section>))
    {:ok, view, _html} = open_builder(conn, page)
    %{view: view}
  end

  defp nothing_made_of(name),
    do: assert_raise(ArgumentError, fn -> String.to_existing_atom(name) end)

  defp stray, do: "name_nobody_declared_#{System.unique_integer([:positive])}"

  describe "the shadow control" do
    test "writes the bucket it was given", %{view: view} do
      section = node_with_tag(view, "section")

      render_click(view, "set_shadow", %{
        "node_id" => section.id,
        "bucket" => "base",
        "field" => "blur",
        "value" => "12"
      })

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(section.id)
             |> Map.fetch!(:meta)
             |> get_in([:styles, :base, "shadow"])
    end

    test "leaves the editor alone for a bucket it does not have", %{view: view} do
      section = node_with_tag(view, "section")
      before = editor_html(view)
      name = stray()

      render_click(view, "set_shadow", %{
        "node_id" => section.id,
        "bucket" => name,
        "field" => "blur",
        "value" => "12"
      })

      assert editor_html(view) == before
      nothing_made_of(name)
    end
  end

  describe "the right rail" do
    test "opens a tab it has, and falls back to the layers for one it has not", %{view: view} do
      render_click(view, "set_right_tab", %{"tab" => "assistant"})
      assert :sys.get_state(view.pid).socket.assigns.right_tab == :assistant

      name = stray()
      render_click(view, "set_right_tab", %{"tab" => name})
      assert :sys.get_state(view.pid).socket.assigns.right_tab == :layers
      nothing_made_of(name)
    end
  end

  describe "the mobile panel bar" do
    test "opens the sheet it names", %{view: view} do
      render_click(view, "set_mob_panel", %{"panel" => "studio"})

      assert :sys.get_state(view.pid).socket.assigns.sheet == :studio
    end

    test "opens a panel it has", %{view: view} do
      render_click(view, "set_mob_panel", %{"panel" => "inspector"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.mob_panel == :inspector
    end
  end
end
