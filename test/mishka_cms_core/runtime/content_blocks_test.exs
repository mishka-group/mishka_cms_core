# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ContentBlocksTest do
  @moduledoc """
  The ready-made blocks the content editor offers: read from the examples the components carry —
  the shipped kit's and any component's — and written as the markers an author places. A plugin
  adding its own is `MishkaCmsCoreWeb.Test.ContentEditorTest`.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.Furnishing
  alias MishkaCmsCore.Runtime.{ContentBlocks, ContentComponents}
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  @moduletag :unit

  # The kit as the palette would list it, every component global.
  defp kit do
    [UiKitHandler.kits_dir(), "chelekom.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("components")
    |> Enum.map(fn row ->
      ContentComponents.entry(%{
        name: row["name"],
        description: nil,
        type: row["type"],
        stateful: row["stateful"],
        site_id: nil,
        template: row["template"],
        helpers: row["helpers"] || [],
        attrs: row["attrs"] || [],
        slots: row["slots"] || [],
        examples: row["examples"] || [],
        furnishing: get_in(row, ["extra", "furnishing"])
      })
    end)
  end

  defp entry(name, opts) do
    %{
      name: name,
      description: nil,
      type: nil,
      stateful: false,
      global: true,
      inner_block: Keyword.get(opts, :inner_block, true),
      category: Keyword.get(opts, :category, "other"),
      examples: Keyword.get(opts, :examples, []),
      furnishing: furnishing(Keyword.get(opts, :furnishing)),
      attrs: Enum.map(Keyword.get(opts, :attrs, []), &attr/1),
      slots: Keyword.get(opts, :slots, [])
    }
  end

  defp furnishing(nil), do: nil

  defp furnishing(declared) do
    {:ok, furnishing} = Furnishing.build(declared)
    furnishing
  end

  defp attr(name),
    do: %{name: name, type: "string", values: [], default: nil, doc: nil, required: false}

  defp slot(name, attrs),
    do: %{name: name, doc: nil, required: false, inner: true, attrs: Enum.map(attrs, &attr/1)}

  defp blocks(entries), do: ContentBlocks.available(entries, nil, nil)

  describe "the shipped kit's examples" do
    setup do
      {:ok, kit: kit()}
    end

    test "are blocks, each marker reading back as its block", %{kit: kit} do
      blocks = blocks(kit)

      assert length(blocks) > 50
      assert blocks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(blocks)

      for block <- blocks do
        assert {:ok, read} = ContentComponents.read(block.marker), block.id
        assert ContentComponents.write(read) == block.marker
        assert read.name == block.component
        assert block.title != ""
      end
    end

    test "keep a component's components and the attributes they declare", %{kit: kit} do
      tracking = Enum.find(blocks(kit), &(&1.id == "chelekom-timeline-example-1"))

      assert tracking.title == "Order tracking"
      assert tracking.category == Enum.find(kit, &(&1.name == "chelekom-timeline")).category
      assert tracking.tree.attrs == %{"color" => "success", "hide_last_line" => "true"}

      sections = for {:component, section} <- tracking.tree.parts, do: section

      assert length(sections) == 4
      assert Enum.all?(sections, &(&1.name == "chelekom-timeline-section"))
      assert hd(sections).attrs["title"] == "Payment confirmed"
      refute Map.has_key?(hd(sections).attrs, "site")
    end

    test "and their furnishings are the plain blocks, named after their components", %{kit: kit} do
      blocks = blocks(kit)
      plain = Enum.find(blocks, &(&1.id == "chelekom-timeline-plain"))

      assert plain.title == nil
      assert plain.component == "chelekom-timeline"

      assert Enum.map(plain.tree.parts, fn {:component, section} -> section.attrs["title"] end) ==
               ["Order placed", "Packed and labelled", "Out for delivery"]

      timeline =
        blocks |> Enum.filter(&(&1.component == "chelekom-timeline")) |> Enum.map(& &1.id)

      assert hd(timeline) == "chelekom-timeline-plain"
      assert "chelekom-timeline-example-1" in timeline
    end

    test "carry none of the template's indentation as text", %{kit: kit} do
      for block <- blocks(kit), text <- texts(block.tree) do
        refute text =~ "\n", block.id
        assert String.trim(text) != "" or text == " ", block.id
      end
    end
  end

  describe "an example" do
    test "holding HTML keeps it, void elements and all" do
      box =
        entry("box",
          examples: [
            ~S|<.component component_name="box" id="box-greeting"><p class="lead">Hi <b>there</b><br>and<img src="/a.png" alt=""></p></.component>|
          ]
        )

      assert [%{id: "box-example-1", title: "Greeting", marker: marker}] = blocks([box])

      assert marker ==
               ~S|[[component box]]<p class="lead">Hi <b>there</b><br>and<img src="/a.png" alt=""></p>[[/component]]|
    end

    test "filling slots keeps the slots its component declares, and their attributes" do
      player =
        entry("player",
          slots: [slot("source", ~w(src))],
          examples: [
            ~S|<.component component_name="player" muted><:source src="/a.mp4" kind="x" /></.component>|
          ]
        )

      assert [%{title: "Example 1", marker: marker}] = blocks([player])
      assert marker == ~S|[[component player]][[slot source src="/a.mp4" /]][[/component]]|
    end

    test "an expression that is a literal is written as the value it is" do
      badge =
        entry("badge",
          attrs: ~w(pill count ratio),
          examples: [
            ~S|<.component component_name="badge" pill={false} count={3} ratio={0.5} />|
          ]
        )

      assert [%{marker: ~S|[[component badge count="3" pill="false" ratio="0.5" /]]|}] =
               blocks([badge])
    end

    test "a bare attribute it declares is written true" do
      badge =
        entry("badge",
          attrs: ~w(pill),
          examples: [~S|<.component component_name="badge" pill />|]
        )

      assert [%{marker: ~S|[[component badge pill="true" /]]|}] = blocks([badge])
    end

    test "that needs more than a marker holds is not offered" do
      for example <- [
            ~S|<.component component_name="box">{@title}</.component>|,
            ~S|<.component component_name="box"><.component component_name="ghost" /></.component>|,
            ~S|<.component component_name="box"><:nope /></.component>|,
            ~S|<div><.component component_name="box" /></div>|,
            ~S|<.component component_name="box" /><.component component_name="box" />|,
            ~S|<.component component_name="other" />|,
            ~S|<.component component_name="box"|
          ] do
        assert blocks([entry("box", examples: [example]), entry("other", [])]) == [], example
      end
    end

    test "is counted in the order its component lists them" do
      box =
        entry("box",
          examples: [
            ~S|<.component component_name="box" id="x-y">A</.component>|,
            ~S|<.component component_name="box">{@x}</.component>|,
            ~S|<.component component_name="box" id="box">B</.component>|
          ]
        )

      assert box |> List.wrap() |> blocks() |> Enum.map(&{&1.id, &1.title}) == [
               {"box-example-1", "X y"},
               {"box-example-3", "Example 3"}
             ]
    end
  end

  test "a component's furnishing is its plain block, first, with what a marker can hold" do
    player =
      entry("player",
        attrs: ~w(color volume),
        slots: [slot("source", ~w(src))],
        furnishing: %{
          "body" => "<p>Watch it</p>",
          "attrs" => %{"color" => "dark", "items" => [1], "volume" => 7},
          "slots" => [%{"name" => "source", "body" => "", "attrs" => %{"src" => "/a.mp4"}}]
        },
        examples: [~S|<.component component_name="player" id="player-tour">Tour</.component>|]
      )

    assert [plain, example] = blocks([player])

    assert %{id: "player-plain", title: nil, component: "player"} = plain

    assert plain.marker ==
             ~S|[[component player color="dark" volume="7"]]<p>Watch it</p>[[slot source src="/a.mp4" /]][[/component]]|

    assert example.id == "player-example-1"
  end

  test "a furnishing a marker cannot hold is no block" do
    box = entry("box", furnishing: %{"body" => "<.component component_name=\"ghost\" />"})
    assert blocks([box]) == []
  end

  test "an example is named by its id, less the words naming its component" do
    name = "kit-timeline-section"

    ids =
      ~w(timeline-section-order tl-shipped timelinesection-step_two hero-lost-help kit-timeline-section)

    section =
      entry(name,
        examples:
          Enum.map(ids, &~s(<.component component_name="#{name}" id="#{&1}">A</.component>))
      )

    assert section |> List.wrap() |> blocks() |> Enum.map(& &1.title) ==
             ["Order", "Shipped", "Step two", "Hero lost help", "Example 5"]
  end

  test "no palette, no block; a component without examples, none of its own" do
    assert blocks([]) == []
    assert blocks([entry("box", [])]) == []
  end

  defp texts(%{parts: parts}) do
    Enum.flat_map(parts, fn
      {:text, text} -> [text]
      {:component, tree} -> texts(tree)
      {:slot, slot} -> texts(slot)
    end)
  end
end
