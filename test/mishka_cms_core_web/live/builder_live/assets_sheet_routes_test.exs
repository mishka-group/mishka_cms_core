# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.AssetsSheetRoutesTest do
  @moduledoc """
  Every way into the Assets sheet fills it in, not only the top bar's button.

  A sheet's contents are read when it opens, and the Assets sheet's folder rail drew its placeholders
  for as long as the sheet stayed open when it was reached from anywhere else: the image button
  beside an Inspector field, a background, the SEO share image, a file attached to the assistant, the
  mobile tab. Opening it once from the top bar made them load, which is how it hid. So each route is
  driven here, and each is held to the same answer the top bar's is.

  The Use button on a card is held to the other half of that sheet: with a pick in flight it takes
  the card's whole first row, because beside three more actions it was about 50px wide and its
  label came out as "U…".
  """
  use MishkaCmsCore.BuilderLiveCase

  @routes [
    :inspector_image,
    :canvas_prompt,
    :background,
    :seo_share_image,
    :assistant_file,
    :mobile_tab,
    :top_bar
  ]

  setup %{conn: conn, page: page, site: site} do
    folder = create_media_category!(site_id: site.id, name: "Photos")

    create_component!(
      site_id: site.id,
      name: "shot-c",
      attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
    )

    {:ok, view, _html} = open_builder(conn, page)
    view |> element("#pb-comp-shot-c") |> render_click()
    render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

    placed =
      view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :component))

    %{view: view, folder: folder, placed: placed}
  end

  defp go(:inspector_image, view, %{placed: placed}),
    do: render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})

  defp go(:canvas_prompt, view, %{placed: placed}),
    do:
      send(
        view.pid,
        {:builder_session, token(view), {:selection, placed.id, {:canvas, "image_url"}}}
      )

  defp go(:background, view, _context) do
    root = view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) |> List.first()
    render_click(view, "pick_background", %{"node_id" => root, "bucket" => "desktop"})
  end

  defp go(:seo_share_image, view, _context), do: render_click(view, "seo_pick_image", %{})
  defp go(:assistant_file, view, _context), do: render_click(view, "attach", %{"kind" => "file"})

  defp go(:mobile_tab, view, _context),
    do: render_click(view, "set_mob_panel", %{"panel" => "assets"})

  defp go(:top_bar, view, _context), do: render_click(view, "open_sheet", %{"sheet" => "assets"})

  describe "the folder rail" do
    for route <- @routes do
      test "loads when the sheet is opened by #{route}",
           %{view: view, folder: folder} = context do
        go(unquote(route), view, context)
        html = render_async(view)

        assert :sys.get_state(view.pid).socket.assigns.sheet == :assets
        assert html =~ ~s(id="pb-folder-#{folder.id}"), "the folder never arrived"
        refute html =~ ~s(data-role="pb-folder-skeleton"), "the rail is still a placeholder"
      end
    end
  end

  describe "the Studio" do
    test "loads when a node's menu opens it on its snippets", %{view: view} do
      h1 = node_with_tag(view, "h1")

      render_click(view, "ctx", %{"action" => "snippet", "node_id" => h1.id})
      render_async(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.sheet == :studio
      assert is_map(assigns.studio_data), "the Studio is still a skeleton"
    end

    test "loads from the mobile tab", %{view: view} do
      render_click(view, "set_mob_panel", %{"panel" => "studio"})
      render_async(view)

      assert is_map(:sys.get_state(view.pid).socket.assigns.studio_data)
    end
  end

  describe "the card's Use button" do
    setup %{site: site, view: view, placed: placed} do
      create_media!(site_id: site.id, name: "hero-shot", type: :images)
      render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})
      %{html: render_async(view)}
    end

    test "is on the card, and the footer wraps so the button has the row to itself", %{
      html: html
    } do
      grid =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="pb-assets-grid"] > div[phx-update="stream"]))

      [classes] = LazyHTML.attribute(grid, "class")

      # Tailwind reads the class names off the source, so the `\_` is part of the class.
      assert classes =~ ~S"[&_button[phx-value-event=use\_media]]:basis-full"
      assert classes =~ ~S"[&_div:has(>div>div>button[phx-value-event=use\_media])]:flex-wrap"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s(button[phx-value-event="use_media"]))
             |> Enum.count() == 1
    end

    test "the card's other actions are still there, under it", %{html: html} do
      grid = html |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-role="pb-assets-grid"]))

      for title <- ["Preview", "Edit", "Archive"] do
        assert grid |> LazyHTML.query(~s(button[title="#{title}"])) |> Enum.count() == 1,
               "#{title} is gone from the card"
      end
    end
  end
end
