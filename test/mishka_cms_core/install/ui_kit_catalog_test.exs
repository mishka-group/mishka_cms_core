# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.UiKitCatalogTest do
  @moduledoc """
  The installer's picker groups a kit's components by category, and kits do not agree on how a
  category is spelled. Chelekom's headless kit, exported as `test/fixtures/cms_ui_kits_export/`
  holds it, wrote `data display` and `data-display`, and `navigation` where the styled kit writes
  `navigations`, so the picker drew "Data display" beside "Data-display" and "Navigation" twice.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Install.UiKitCatalog

  doctest UiKitCatalog, only: [file_categories: 2]

  @export_dir Path.expand("../../fixtures/cms_ui_kits_export", __DIR__)

  defp fixture(name), do: @export_dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp keys(catalog), do: Enum.map(catalog.groups, & &1.key)

  defp group(catalog, key), do: Enum.find(catalog.groups, &(&1.key == key))

  describe "category_key/1" do
    test "case, spaces, hyphens and underscores are one spelling" do
      for written <- ["data display", "data-display", "Data_Display", " DATA  display "],
          do: assert(UiKitCatalog.category_key(written) == "data display")
    end

    test "a component with no category is filed as general" do
      assert UiKitCatalog.category_key(nil) == "general"
      assert UiKitCatalog.category_key("") == "general"
      assert UiKitCatalog.category_key(:forms) == "forms"
    end
  end

  describe "file_categories/2" do
    test "a category beside its own plural is filed under the plural" do
      assert UiKitCatalog.file_categories(["button", "buttons", "media"]) == %{
               "button" => "buttons",
               "buttons" => "buttons",
               "media" => "media"
             }
    end

    test "a known spelling counts though no kit wrote it" do
      assert UiKitCatalog.file_categories(["navigation"]) == %{"navigation" => "navigation"}

      assert UiKitCatalog.file_categories(["navigation"], ["navigations"]) == %{
               "navigation" => "navigations"
             }
    end
  end

  describe "the headless kit's picker" do
    setup do
      %{catalog: UiKitCatalog.build(fixture("chelekom_headless.json"))}
    end

    test "shows each category once", %{catalog: catalog} do
      labels = Enum.map(catalog.groups, &String.downcase(&1.label))

      assert labels == Enum.uniq(labels)
      refute "data-display" in keys(catalog)
      refute "navigation" in keys(catalog)
    end

    test "files both spellings of data display together, and navigation with the styled kit's", %{
      catalog: catalog
    } do
      assert length(group(catalog, "data display").entries) == 12
      assert group(catalog, "data display").label == "Data display"

      assert length(group(catalog, "navigations").entries) == 12
      assert group(catalog, "navigations").label == "Navigation"
    end
  end

  test "two kits that spell a category differently share its heading" do
    catalog =
      UiKitCatalog.merge([fixture("chelekom.json"), fixture("chelekom_headless.json")])

    assert keys(catalog) == Enum.uniq(keys(catalog))
    assert length(group(catalog, "navigations").entries) == 14 + 12

    kits =
      group(catalog, "navigations").entries |> Enum.map(& &1.kit) |> Enum.uniq() |> Enum.sort()

    assert kits == ["chelekom", "chelekom_headless"]
  end

  # Neither kit alone has both words, so only the merge can see that `button` is `buttons`.
  test "a singular in one kit joins the other kit's plural" do
    bundle = fn name, type ->
      %{"name" => name, "components" => [%{"name" => "#{name}-x", "type" => type}]}
    end

    catalog = UiKitCatalog.merge([bundle.("acme", "button"), bundle.("acme_headless", "Buttons")])

    assert keys(catalog) == ["buttons"]
    assert length(group(catalog, "buttons").entries) == 2
  end
end
