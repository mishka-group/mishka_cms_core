# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.TopBarLayoutTest do
  @moduledoc """
  The editor's top bar has to fit the screen whatever the document is called.

  `Phoenix.LiveViewTest` has no layout engine, so these pin the markup that makes it fit and not the
  pixels: the identity block is the one child of the bar that gives way, everything the record
  supplies as text inside it can shrink, and nothing on its right does. A block that was `flex-none`
  grew with the name of the page and pushed Publish off the screen — only in the Published stage,
  where the status line is at its longest (measured in a browser: the bar was 1537px wide at a 1440px
  window).
  """
  use MishkaCmsCore.BuilderLiveCase

  @long_name Enum.join(List.duplicate("pricing-comparison-landing", 3), "-")

  defp top_bar(view),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("header.h-14")

  defp classes(element) do
    element |> LazyHTML.attribute("class") |> Enum.join(" ") |> String.split()
  end

  defp class_of(view, selector),
    do: view |> top_bar() |> LazyHTML.query(selector) |> classes()

  # Every element the bar's selector finds, each as its own list of classes.
  defp class_lists(view, selector),
    do: view |> top_bar() |> LazyHTML.query(selector) |> Enum.map(&classes/1)

  # The bar's own children, in order, as `{id, classes}`.
  defp children(view) do
    [{"header", _attrs, kids}] = view |> top_bar() |> LazyHTML.to_tree()

    for {_tag, attrs, _kids} <- kids do
      {attr(attrs, "id"), String.split(attr(attrs, "class") || "")}
    end
  end

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  describe "the bar's children" do
    test "the identity block is the only one that gives way", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      kids = children(view)

      [identity] = for {_id, kid} <- kids, "min-w-0" in kid and "flex-1" in kid, do: kid
      assert "flex-none" not in identity

      # Everything else is fixed: the hidden leave guard, the controls and the avatars.
      for {id, kid} <- kids, id != "pb-leave-guard", "flex-1" not in kid do
        assert "flex-none" in kid, "#{inspect(id || kid)} would shrink or grow with the bar"
      end

      refute Enum.any?(kids, fn {_id, kid} -> kid == ["flex-1"] end),
             "a bare spacer lets the identity block keep its full width"
    end

    test "nothing the record supplies can hold the identity block open", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      # The name, the status, the site's badge and the draft chip — and the title row's own text.
      for selector <- [
            "[data-role=pb-identity] .truncate",
            "#pb-settings-open span.truncate",
            "[data-role=pb-status]",
            "[data-role=pb-scope]",
            "#pb-draft-target"
          ] do
        found = class_lists(view, selector)
        assert found != [], "#{selector} is not in the bar"

        for kid <- found do
          assert "flex-none" not in kid, "#{selector} cannot shrink"
          assert "truncate" in kid or "min-w-0" in kid, "#{selector} cannot shrink"
        end
      end

      assert "truncate" in class_of(view, "[data-role=pb-scope]")
    end
  end

  describe "in the Published stage, with long names" do
    setup %{site: site} do
      %{page: create_page!(site_id: site.id, name: @long_name)}
    end

    test "the status wording is the first thing to go, and its dot keeps the words", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      status = class_of(view, "[data-role=pb-status]")
      assert "max-[1180px]:hidden" in status

      # What the words said is still one hover away at any width.
      html = render(view)
      assert html =~ ~s(title="recorded, not saved to the page")
    end

    test "the name is the page's own, however long, and truncates", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      assert has_element?(view, "#pb-settings-open span.truncate", @long_name)
    end

    test "Publish is a fixed control, so it stays on screen", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      assert "flex-none" in class_of(view, "[data-role=pb-publish]")
      assert "flex-none" in class_of(view, "[data-role=pb-actions]")
      assert has_element?(view, "#pb-stage", "Publish")
    end
  end
end
