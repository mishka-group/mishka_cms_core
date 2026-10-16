# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest do
  @moduledoc """
  Several icon sets, one catalogue.

  `MishkaCmsCore.Runtime.PageBuilder.Icons` used to BE the heroicon set. It is now a facade, because
  an install that wants Lucide as well as Heroicons had nowhere to say so — and the class name
  already namespaces itself (`hero-check`, `lucide-check`), so the sets can coexist in one document.

  The contract that matters: with ONE library registered, every answer is that library's answer, so
  nothing about a stock install changes.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.Icons
  alias MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons

  @moduletag :unit

  setup do
    original = Application.get_env(:mishka_cms_core, :icon_libraries)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:mishka_cms_core, :icon_libraries)
        libraries -> Application.put_env(:mishka_cms_core, :icon_libraries, libraries)
      end
    end)

    :ok
  end

  defp register(libraries), do: Application.put_env(:mishka_cms_core, :icon_libraries, libraries)

  describe "with only heroicons, which is the stock install" do
    test "the facade answers exactly what the library answers" do
      register([Heroicons])

      assert Icons.all() == Heroicons.all()
      assert Icons.variants() == Heroicons.variants()
      assert Icons.available?()
      assert Icons.known?("hero-bell")
      assert Icons.css(["hero-bell"]) =~ Heroicons.css(["hero-bell"])
    end

    test "a class no set claims is unknown, and draws nothing" do
      register([Heroicons])

      refute Icons.known?("lucide-bell")
      assert Icons.svg("lucide-bell", 15) == nil
      assert Icons.css(["lucide-bell"]) == ""
    end
  end

  describe "with a second set registered" do
    test "both catalogues are offered" do
      register([Heroicons, MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake])

      assert Icons.known?("hero-bell")
      assert Icons.known?("fake-star")
      assert "fake-star" in Icons.all()
    end

    # Routing by prefix is what lets the facade stay ignorant of which set a value came from.
    test "each class is drawn and styled by the set that owns it" do
      register([Heroicons, MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake])

      assert Icons.css(["fake-star"]) =~ "fake-star"
      assert Icons.css(["fake-star"]) =~ "FAKE"
      assert {:safe, _svg} = Icons.svg("fake-star", 15)

      # And heroicons is untouched by its presence.
      assert Icons.css(["hero-bell"]) =~ Heroicons.css(["hero-bell"])
    end

    test "a search spans both, and the cap applies to the merged list" do
      register([Heroicons, MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake])

      assert "fake-star" in Icons.search("star", limit: 200)
      assert length(Icons.search("", limit: 5)) <= 5
    end

    test "one set can be asked for on its own" do
      register([Heroicons, MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake])

      only =
        Icons.search("",
          limit: 200,
          library: MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake
        )

      assert only == ["fake-star"]
    end

    # STORED CONTENT IS READ BY EVERY REGISTERED PREFIX, so a site's stylesheet carries the icons
    # its posts name from whichever set they come from.
    test "content names an icon of each set, and none a set does not ship" do
      register([Heroicons, MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake])

      html =
        ~s([[slot item icon="fake-star"]]x[[/slot]]<span class="hero-bell fake-moon"></span>)

      assert MishkaCmsCore.Runtime.ContentComponents.icons(html) == ["fake-star", "hero-bell"]

      register([Heroicons])

      assert MishkaCmsCore.Runtime.ContentComponents.icons(html) == ["hero-bell"]
    end

    # A variant button half the results cannot honour reads as broken, so only shared weights show.
    test "only the weights both sets ship are offered" do
      register([Heroicons, MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake])

      assert Icons.variants() == [{"", "Outline"}]
    end
  end

  test "a library that is not loaded is ignored rather than fatal" do
    register([Heroicons, NoSuch.IconLibrary])

    assert Icons.libraries() == [Heroicons]
  end

  # The point of the whole exercise: installing a kit that ships its own glyphs is enough. No module
  # to write, no config line to add. `mix mishka.ui.export` writes them under a top-level `icons`
  # key and `MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled` reads them out of the installed bundle.
  describe "a set that arrived inside a kit" do
    alias MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled

    @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

    setup do
      path = Path.join(@kits_dir, "zz_icontest.json")

      File.write!(
        path,
        Jason.encode!(%{
          "name" => "icontest",
          "components" => [],
          "icons" => %{
            "prefix" => "zzz-",
            "label" => "ZZZ",
            "variants" => [["", "Outline"], ["-solid", "Solid"]],
            "glyphs" => %{
              "zzz-rocket" => ~s(<svg viewBox="0 0 24 24" width="24" height="24"><path/></svg>),
              "zzz-rocket-solid" => ~s(<svg viewBox="0 0 24 24"><path/></svg>)
            }
          }
        })
      )

      Bundled.refresh()

      on_exit(fn ->
        File.rm(path)
        Bundled.refresh()
      end)

      :ok
    end

    test "it registers itself without being configured" do
      register([Heroicons])

      assert Bundled in Icons.libraries()
      assert Icons.known?("zzz-rocket")
    end

    test "its glyphs are drawn and styled from the bundle" do
      register([Heroicons])

      assert {:safe, svg} = Icons.svg("zzz-rocket", 15)
      assert IO.iodata_to_binary(svg) =~ ~s(width="15")

      css = Icons.css(["zzz-rocket"])
      assert css =~ ".zzz-rocket{"
      assert css =~ "mask:"
    end

    test "it is searchable, by weight" do
      register([Heroicons])

      assert "zzz-rocket" in Icons.search("rocket", limit: 200)
      assert "zzz-rocket-solid" in Icons.search("rocket", limit: 200, variant: "-solid")
      refute "zzz-rocket-solid" in Icons.search("rocket", limit: 200, variant: "")
    end

    test "content naming its glyphs stores them beside the heroicons it names" do
      register([Heroicons])

      html = ~s(<span class="zzz-rocket-solid"></span>[[slot item icon="hero-bell" /]]zzz-gone)

      assert MishkaCmsCore.Runtime.ContentComponents.icons(html) == [
               "zzz-rocket-solid",
               "hero-bell"
             ]
    end

    # Heroicons keeps answering for its own classes with a second set present.
    test "the sets do not tread on each other" do
      register([Heroicons])

      assert Icons.css(["hero-bell"]) =~ Heroicons.css(["hero-bell"])
      refute Icons.known?("zzz-nothing")
    end

    # AN UNLAYERED RULE BEATS EVERY LAYERED ONE, so `size-3` on an icon never applied.
    test "every set's rules sit inside the components layer, after Tailwind's layer order" do
      register([Heroicons, MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake])

      assert Enum.sort(Icons.libraries()) ==
               Enum.sort([
                 Heroicons,
                 MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake,
                 Bundled
               ])

      for names <- [
            ["hero-bell"],
            ["fake-star"],
            ["zzz-rocket"],
            ["hero-bell", "fake-star", "zzz-rocket"]
          ] do
        css = Icons.css(names)

        assert [order, "@layer components{" <> body] = String.split(css, "\n", parts: 2)
        assert order == Icons.layer_order()
        assert closes_at(body) == byte_size(body) - 1, "a rule escaped the block: #{css}"
        for name <- names, do: assert(body =~ ".#{name}{")
      end
    end
  end

  # Where the `{` already open at the start of `body` closes.
  defp closes_at(body) do
    body
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(1, fn
      {?{, _at}, depth -> {:cont, depth + 1}
      {?}, at}, 1 -> {:halt, at}
      {?}, _at}, depth -> {:cont, depth - 1}
      _char, depth -> {:cont, depth}
    end)
  end

  # Chelekom's bundle ships the `hero-` set so that a host WITHOUT `deps/heroicons` can still draw a
  # picker. A host that has both must not end up with two: every heroicon would be listed twice and
  # the picker would grow a library row offering a choice between two identical sets.
  describe "a bundled set whose prefix is already claimed" do
    alias MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled

    @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

    setup do
      path = Path.join(@kits_dir, "zz_dupetest.json")

      File.write!(
        path,
        Jason.encode!(%{
          "name" => "dupetest",
          "components" => [],
          "icons" => %{
            "prefix" => "hero-",
            "label" => "Heroicons (bundled)",
            "variants" => [["", "Outline"]],
            "glyphs" => %{"hero-bell" => "<svg/>"}
          }
        })
      )

      Bundled.refresh()

      on_exit(fn ->
        File.rm(path)
        Bundled.refresh()
      end)

      :ok
    end

    test "the compiled set wins and the bundled copy is not registered" do
      register([Heroicons])

      refute Bundled in Icons.libraries()
      assert Icons.libraries() == [Heroicons]
    end

    # The case the bundle exists FOR: no compiled heroicons, so the bundled copy is the only source.
    test "with nothing else claiming the prefix, the bundle supplies it" do
      register([])

      assert Icons.libraries() == [Bundled]
      assert Icons.known?("hero-bell")
    end
  end
end
