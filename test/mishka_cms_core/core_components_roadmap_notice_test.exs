# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.CoreComponentsRoadmapNoticeTest do
  @moduledoc """
  `roadmap_notice/1` is the `tip/1` box with a title, so an extension's admin page can say that a part
  is on the roadmap in the same words and the same style as the builder's Assistant and Audit tabs.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.CoreComponents

  defp notice(assigns, text) do
    slot = [%{__slot__: :inner_block, inner_block: fn _changed, _arg -> text end}]

    (&CoreComponents.roadmap_notice/1)
    |> render_component(Map.put(assigns, :inner_block, slot))
    |> LazyHTML.from_fragment()
  end

  test "draws the title over the text in a note, with the caller's id" do
    html =
      notice(
        %{id: "blog-roadmap", title: "Auto posting is not available yet"},
        "This part of the blog is on our roadmap."
      )

    box = LazyHTML.query(html, "#blog-roadmap")

    assert Enum.count(box) == 1
    assert LazyHTML.attribute(box, "role") == ["note"]
    assert LazyHTML.attribute(box, "data-role") == ["roadmap-notice"]
    assert LazyHTML.text(box) =~ "Auto posting is not available yet"
    assert LazyHTML.text(box) =~ "This part of the blog is on our roadmap."
  end

  test "title and text are free text, so each follows its own direction" do
    html = notice(%{id: "x-roadmap", title: "T"}, "text")

    assert html |> LazyHTML.query("#x-roadmap span[dir=auto]") |> Enum.count() == 2
  end

  test "the caller's classes are added to the tip's own" do
    html = notice(%{id: "x-roadmap", title: "T", class: "mb-3"}, "text")

    [class] = html |> LazyHTML.query("#x-roadmap") |> LazyHTML.attribute("class")
    assert class =~ "mb-3"
    assert class =~ "bg-[#fdf8ef]"
  end

  test "title is required" do
    {_fun, meta} = Enum.find(CoreComponents.__components__(), &(elem(&1, 0) == :roadmap_notice))
    title = Enum.find(meta.attrs, &(&1.name == :title))

    assert title.required == true
  end
end
