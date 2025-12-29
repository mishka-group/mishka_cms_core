defmodule MishkaCmsCore.Builder.ContributedBlocksTest do
  @moduledoc """
  A block an extension contributes has to behave like one of the built-in ones.

  The palette used to merge contributions in AFTER filtering — `collect_appended(:blocks,
  Blocks.search(cat, query))` — so an extension's card survived every filter: it showed under a
  category it did not belong to, it ignored the search box, and it inflated the header count. Its own
  category had no chip either, because the chip row was built from the core lists alone.

  The whole point of the registries is that a contribution is not a second-class card, so these
  assert it is filtered by the same two questions a built-in one answers.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.Blocks
  alias MishkaCmsCore.Test.Plugins.BuilderBlockPlugin
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  setup do
    {:ok, _} =
      Event.write(%{
        name: BuilderBlockPlugin,
        event: "builder:blocks",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("builder:blocks", :start, false)
    on_exit(fn -> Event.unregister(:name, BuilderBlockPlugin, false) end)

    %{block: BuilderBlockPlugin.block()}
  end

  defp merged, do: MishkaCmsCore.Builder.Events.collect_appended(:blocks, Blocks.all())
  defp ids(entries), do: Enum.map(entries, &Map.get(&1, :id))

  describe "a contributed block in the merged library" do
    test "is there beside the built-in ones", %{block: block} do
      assert block.id in ids(merged())
      assert "hero-centred" in ids(merged())
    end
  end

  describe "the category chips" do
    test "it appears under its own category", %{block: block} do
      assert ids(Blocks.filter(merged(), block.category, "")) == [block.id]
    end

    # THE BUG. Merged after filtering, it survived every filter — so it sat in Layout, in Footer and
    # in every other category at once.
    test "and not under a category it does not belong to", %{block: block} do
      refute block.id in ids(Blocks.filter(merged(), "Layout", ""))
    end

    test "while the built-in blocks keep their own categories" do
      assert "hero-centred" in ids(Blocks.filter(merged(), "Header", ""))
    end

    test "and everything shows under all", %{block: block} do
      all = ids(Blocks.filter(merged(), "all", ""))

      assert block.id in all
      assert "hero-centred" in all
    end
  end

  describe "the search box" do
    test "finds it by its title", %{block: block} do
      assert block.id in ids(Blocks.filter(merged(), "all", "testimonial"))
    end

    test "finds it by its description", %{block: block} do
      assert block.id in ids(Blocks.filter(merged(), "all", "customer quotes"))
    end

    test "and a needle it does not match leaves it out", %{block: block} do
      refute block.id in ids(Blocks.filter(merged(), "all", "zzzznothing"))
    end
  end
end
