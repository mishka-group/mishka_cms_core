defmodule MishkaCmsCore.Builder.CollectionTest do
  @moduledoc """
  An attribute that holds a list, edited as a list.

  `chelekom-filterable-gallery` keeps its whole content in two `list` attributes — the filter
  buttons and the pictures behind them — and thirty-nine attributes across the shipped kit are
  shaped the same way. Every one of them drew a one-line text box, and what that box wrote was a
  STRING: a component that maps over its own attribute raised the moment anything was typed. The
  report reads "we cannot add any image and it's not clear how it works".

  What is pinned here is the round trip. The panel reads the list out of the document, changes one
  item, and writes the whole thing back as source the editor can read again — and an attribute that
  is not data is refused rather than overwritten with whatever could be made of it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.Collection
  alias MishkaCmsCore.Runtime.PageBuilder.Tree

  @moduletag :unit

  defp parsed(markup) do
    {:ok, tree} = Tree.parse(markup)
    tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))
  end

  describe "reading what is there" do
    test "a list written as an expression" do
      node = parsed(~S|<.component component_name="x" filters={["One", "Two"]} />|)

      assert Collection.read(node, "filters") == {:ok, ["One", "Two"]}
    end

    test "a list of maps, keys and all" do
      node = parsed(~S|<.component component_name="x" media={[%{src: "/a.jpg", alt: "A"}]} />|)

      assert Collection.read(node, "media") == {:ok, [%{src: "/a.jpg", alt: "A"}]}
    end

    test "an attribute that is not there falls back to the declared default" do
      node = parsed(~S|<.component component_name="x" />|)

      assert Collection.read(node, "filters", ["All"]) == {:ok, ["All"]}
      assert Collection.read(node, "filters") == {:ok, []}
    end

    # THE ONE ANSWER THAT IS NOT A LIST. `media={@photos}` is an author binding the attribute to
    # something outside the page, and the panel must leave it exactly as written — reading it as an
    # empty list and writing that back would delete their work on the next click.
    test "an attribute bound to something outside the page is refused" do
      node = parsed(~S|<.component component_name="x" media={@photos} />|)

      assert Collection.read(node, "media") == :error
    end

    test "and so is a call, however list-shaped it looks" do
      node = parsed(~S|<.component component_name="x" media={Enum.map(@p, & &1)} />|)

      assert Collection.read(node, "media") == :error
    end
  end

  describe "changing one item" do
    test "adds at the end, removes by index, and replaces in place" do
      assert Collection.add(["a"], "b") == ["a", "b"]
      assert Collection.remove(["a", "b", "c"], 1) == ["a", "c"]
      assert Collection.put(["a", "b"], 1, "B") == ["a", "B"]
      assert Collection.put_in_item([%{src: "x"}], 0, :src, "y") == [%{src: "y"}]
    end

    # A STALE CLICK MUST NOT TAKE THE EDITOR DOWN. The panel and the document disagree for one render
    # after an undo, and a button pressed in that window addresses an item that is no longer there.
    test "an index past the end changes nothing" do
      assert Collection.put(["a"], 4, "b") == ["a"]
      assert Collection.put_in_item(["a"], 4, :src, "b") == ["a"]
      assert Collection.remove(["a"], 4) == ["a"]
      assert Collection.put_in_item(["a"], 0, :src, "b") == ["a"]
    end
  end

  # A MAP IS READ OUT AS ITS PAIRS. `chelekom-flash` holds `%{"info" => "…"}` and
  # `chelekom-pagination` a map of query parameters, and a pair is edited as a pair — one field for
  # each side. Reading one as a single value put a tuple through `to_string/1`, which raised out of
  # LiveView's own diff and took the editor down the moment such a component was selected.
  describe "a map attribute" do
    test "is read as pairs" do
      node = parsed(~S|<.component component_name="x" params={%{"kind" => "banner"}} />|)

      assert Collection.read(node, "params") == {:ok, [{"kind", "banner"}]}
      assert Collection.pair?({"kind", "banner"})
      refute Collection.pair?("kind")
    end

    test "and one side changes without disturbing the other" do
      items = [{"kind", "banner"}, {"size", "large"}]

      assert Collection.put_side(items, 0, :value, "toast") == [
               {"kind", "toast"},
               {"size", "large"}
             ]

      assert Collection.put_side(items, 1, :key, "scale") == [
               {"kind", "banner"},
               {"scale", "large"}
             ]

      assert Collection.put_side(items, 9, :key, "x") == items
      assert Collection.put_side(["plain"], 0, :key, "x") == ["plain"]
    end

    test "and a new row is an empty pair" do
      assert Collection.blank([{"kind", "banner"}]) == {"", ""}
    end
  end

  describe "the row a new one starts as" do
    test "carries the same fields its neighbours do, blank" do
      assert Collection.blank([%{src: "/a.jpg", alt: "A"}]) == %{src: "", alt: ""}
    end

    test "and is a plain value when there is nothing to copy" do
      assert Collection.blank(["One", "Two"]) == ""
      assert Collection.blank([]) == ""
    end
  end

  describe "writing it back" do
    test "is source the editor can read again" do
      items = [%{src: "/a.jpg", alt: "A", category: "Branding"}, %{src: "/b.jpg"}]
      written = Collection.write(items)

      node = parsed(~S|<.component component_name="x" media={| <> written <> ~S|} />|)

      assert Collection.read(node, "media") == {:ok, items}
    end

    # `inspect/1` shortens a long list with an ellipsis by default, and an ellipsis is not Elixir.
    test "and a long one is written whole" do
      items = Enum.map(1..200, &%{src: "/#{&1}.jpg"})

      node =
        parsed(~S|<.component component_name="x" media={| <> Collection.write(items) <> ~S|} />|)

      assert Collection.read(node, "media") == {:ok, items}
    end
  end

  describe "which attributes this is for" do
    @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

    alias MishkaCmsCore.Runtime.PageBuilder.Inspector

    test "every list, map and keyword list the kit declares" do
      components =
        @bundle |> File.read!() |> Jason.decode!() |> Map.fetch!("components")

      collections =
        for entry <- components,
            attr <- Inspector.attrs(entry),
            match?(
              {:collection, _kind},
              Inspector.widget(attr, Inspector.features(entry), entry)
            ),
            do: "#{entry["name"]}.#{Inspector.name(attr)}"

      assert length(collections) >= 30,
             "the kit is full of these and only #{length(collections)} were recognised"

      assert "chelekom-filterable-gallery.media" in collections
      assert "chelekom-filterable-gallery.filters" in collections
    end

    test "and nothing that holds one value" do
      text = %{"name" => "title", "type" => "string", "opts" => %{}}
      number = %{"name" => "total", "type" => "integer", "opts" => %{}}

      refute match?({:collection, _}, Inspector.widget(text))
      refute match?({:collection, _}, Inspector.widget(number))
    end
  end
end
