# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.SiteIconCssTest do
  @moduledoc """
  A kit's own glyphs reaching the page, not just the picker.

  Two holes, and the second was the one visitors saw. `canvas_live.ex` filtered on the literal class
  prefix `hero-`, so only heroicons reached `Icons.css/1`; and the site compilers appended
  `heroicons_plugin()` and nothing else, so a published page carried rules for one library however
  many were installed.

  A kit shipping Lucide got a picker that worked perfectly — the library row appeared, search found
  `lucide-heart`, the swatch drew it — and a blank box on the canvas an inch away. Then the page was
  published and every visitor saw the same holes, permanently. Chelekom's icons rendered fine in the
  same modal, so it read as "my kit is broken".

  `async: false` — the bundled-icon cache and the kits directory are process-global.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Authoring.Icons

  @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()
  @fixture Path.join(@kits_dir, "icontest.json")

  setup do
    File.write!(
      @fixture,
      Jason.encode!(%{
        "$schema" => "mishka.ui_kit.bundle.v3",
        "name" => "icontest",
        "components" => [],
        "icons" => %{
          "prefix" => "icontest-",
          "label" => "Icon Test",
          "variants" => [["", "Outline"]],
          "glyphs" => %{
            "icontest-star" =>
              ~s|<svg viewBox="0 0 24 24"><path d="M12 2l3 7h7l-6 4 2 7-6-4-6 4 2-7-6-4h7z"/></svg>|
          }
        }
      })
    )

    Icons.Bundled.refresh()

    on_exit(fn ->
      File.rm(@fixture)
      Icons.Bundled.refresh()
    end)

    :ok
  end

  describe "a kit that ships its own glyphs" do
    test "registers a prefix of its own beside heroicons" do
      assert "icontest-" in Enum.flat_map(Icons.libraries(), & &1.prefixes())
    end

    # THE FIX. `Icons.css/1` routes a class to whichever library claims its prefix, so the canvas
    # guard on `hero-` only ever excluded other people's icons.
    test "produces mask rules for its own class" do
      css = Icons.css(["icontest-star"])

      assert css =~ "icontest-star"
      assert css =~ "mask", "an icon is a CSS mask, not a glyph in the markup"
    end

    test "a heroicon and a bundled icon can be asked for together" do
      css = Icons.css(["hero-check", "icontest-star"])

      assert css =~ "icontest-star"
      assert css =~ "hero-check"
    end

    # THE LIBRARY BUTTON WAS DEAD. `:icon_library` was assigned on the LiveView and defaulted in the
    # panel, then never reached `Icons.search/2` — while `icon_variant`, threaded one line above,
    # did. Clicking a library left the grid on the same heroicons.
    test "search can be restricted to one library" do
      # Heroicons is its own module and owns nothing a bundle registered, so restricting to it is
      # what proves the filter is consulted at all.
      heroicons = Icons.search("star", library: Icons.Heroicons, limit: 60)

      assert heroicons != []
      refute Enum.any?(heroicons, &String.starts_with?(&1, "icontest-"))
    end

    test "counting follows the same restriction" do
      assert Icons.count("", "", library: Icons.Bundled) < Icons.count("", "")
    end

    # ROUND-ROBIN, not concatenate-then-cut. `flat_map |> take` spent the whole limit on the first
    # library, so a second set was unbrowsable however many were installed.
    # Every bundle's glyphs live behind ONE library, and Chelekom's carries 1,288 heroicons — so a
    # kit adding a dozen under a prefix sorting after `hero-` never appeared in a 60-icon grid.
    test "a kit's own set is reachable without narrowing the query" do
      merged = Icons.search("", limit: 60)

      assert Enum.any?(merged, &String.starts_with?(&1, "icontest-")),
             "each set gets a share of a limit one of them alone could fill"
    end

    # An unclaimed class is dropped rather than emitting an empty rule, which is what makes it safe
    # to hand `Icons.css/1` every icon-shaped token found in a template.
    test "a class no library claims contributes nothing" do
      refute Icons.css(["nosuchkit-ghost"]) =~ "nosuchkit-ghost"
    end
  end
end
