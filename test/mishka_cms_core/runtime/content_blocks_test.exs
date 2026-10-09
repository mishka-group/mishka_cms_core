defmodule MishkaCmsCore.Runtime.ContentBlocksTest do
  @moduledoc """
  The ready-made blocks the content editor offers: which of them a palette can place, and the
  markers they are written as. A plugin adding its own is
  `MishkaCmsCoreWeb.Test.ContentEditorTest`.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.{ContentBlocks, ContentComponents}

  @moduletag :unit

  defp entry(name, opts) do
    %{
      name: name,
      description: nil,
      type: nil,
      stateful: false,
      global: true,
      inner_block: Keyword.get(opts, :inner_block, true),
      category: "other",
      attrs: [],
      slots: Keyword.get(opts, :slots, [])
    }
  end

  defp slot(name), do: %{name: name, doc: nil, required: false, inner: true, attrs: []}

  defp ids(entries), do: entries |> ContentBlocks.available(nil, nil) |> Enum.map(& &1.id)

  # Every component and slot the shipped blocks are made of.
  defp kit do
    for block <- ContentBlocks.all(), reduce: %{} do
      kit -> collect(block.tree, kit)
    end
    |> Enum.map(fn {name, slots} -> entry(name, slots: Enum.map(slots, &slot/1)) end)
  end

  defp collect(%{name: name, parts: parts}, kit) do
    kit = Map.put_new(kit, name, MapSet.new())

    Enum.reduce(parts, kit, fn
      {:component, tree}, kit ->
        collect(tree, kit)

      {:slot, %{name: slot, parts: inside}}, kit ->
        inside |> Enum.reduce(Map.update!(kit, name, &MapSet.put(&1, slot)), &collect_part/2)

      {:text, _text}, kit ->
        kit
    end)
  end

  defp collect_part({:component, tree}, kit), do: collect(tree, kit)
  defp collect_part(_part, kit), do: kit

  test "every block is offered where the palette lists all it is made of" do
    assert ids(kit()) == Enum.map(ContentBlocks.all(), & &1.id)
  end

  test "each block's marker reads back as the block" do
    for block <- ContentBlocks.available(kit(), nil, nil) do
      assert {:ok, read} = ContentComponents.read(block.marker), block.id
      assert ContentComponents.write(read) == block.marker
      assert read.name == block.tree.name
    end
  end

  test "a block missing one of its components is not offered" do
    without_li = Enum.reject(kit(), &(&1.name == "chelekom-li"))

    refute "list" in ids(without_li)
    assert "quote" in ids(without_li)
  end

  test "a block filling a slot its component does not declare is not offered" do
    no_source =
      Enum.map(kit(), fn
        %{name: "chelekom-video"} = video -> %{video | slots: []}
        other -> other
      end)

    refute "video" in ids(no_source)
  end

  test "no palette, no block" do
    assert ids([]) == []
  end

  test "the sample text is in the reader's language and the categories are palette headings" do
    for block <- ContentBlocks.all() do
      assert block.title != ""
      assert block.category in ~w(text media layout)
    end
  end
end
