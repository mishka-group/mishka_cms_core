# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.HelperNarrowingTest do
  @moduledoc """
  Which helper clauses an install keeps, for a kit whose helpers are not shaped like Chelekom's.

  Narrowing used to read the selection by axis NAME (`"variant"`, `"color"`) and test the clause by
  POSITION — argument 0 against the variants, argument 1 against the colours. That is Chelekom's
  `color_variant(variant, color)` written into the installer, and `discriminators` is the Chelekom
  exporter's own field, so a third-party kit fell to that branch for every helper it ships.

  The failure had two shapes, both bad:

    * the kit ships a `_`-headed fallback, so every button renders at the fallback style while the
      Inspector still offers small/medium/large and clicking changes nothing;
    * it does not, so the generated module defines no `size_class/1` while the template calls it —
      the component fails to compile, on the canvas AND on the published page.

  And it was perverse: a kit naming its axes `tone`/`density` was accidentally safe, because nothing
  narrowed at all. A kit naming them the obvious `variant`/`color` was the one that broke.

  The bindings come from the kit's own call sites now — `color_variant(@variant, @kind)` says what
  parameter 0 and 1 describe — so the order stops mattering.

  `async: false` — installs write global runtime rows.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  setup do
    dir = Path.join(System.tmp_dir!(), "narrow_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # COLOUR FIRST, VARIANT SECOND — the opposite of Chelekom's order, and no discriminators, which is
  # what a kit built without Chelekom's exporter looks like.
  defp reversed_kit do
    %{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => "acme",
      "components" => [
        %{
          "name" => "acme-button",
          "type" => "general",
          "template" => ~s|<button class={paint(@color, @variant)}>x</button>|,
          "attrs" => [
            %{
              "name" => "color",
              "type" => "string",
              "opts" => %{"values" => ["brand", "danger"]}
            },
            %{"name" => "variant", "type" => "string", "opts" => %{"values" => ["solid", "soft"]}}
          ],
          "helpers" => [
            %{
              "name" => "paint",
              "args" => ~s|"brand", "solid"|,
              "code" => ~s|defp paint("brand", "solid"), do: "a"|
            },
            %{
              "name" => "paint",
              "args" => ~s|"brand", "soft"|,
              "code" => ~s|defp paint("brand", "soft"), do: "b"|
            },
            %{
              "name" => "paint",
              "args" => ~s|"danger", "solid"|,
              "code" => ~s|defp paint("danger", "solid"), do: "c"|
            },
            %{
              "name" => "paint",
              "args" => ~s|"danger", "soft"|,
              "code" => ~s|defp paint("danger", "soft"), do: "d"|
            }
          ]
        }
      ]
    }
  end

  defp install!(dir, bundle, selection) do
    path = Path.join(dir, "#{bundle["name"]}.json")
    File.write!(path, Jason.encode!(bundle))
    UiKitHandler.install_kit!(path, site_id: nil, selection: selection)
    on_exit(fn -> UiKitHandler.uninstall_kit!(path, kit_name: bundle["name"]) end)
    path
  end

  defp helper_args(name) do
    Component
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(authorize?: false, action: :read_any, page: [limit: 1])
    |> Map.fetch!(:results)
    |> hd()
    |> Map.fetch!(:helpers)
    |> Enum.map(& &1.args)
    |> Enum.sort()
  end

  describe "a kit whose helper takes colour first" do
    # The call site says parameter 0 is `color`, so narrowing colours must cut on argument 0 — the
    # position the old code reserved for variants.
    test "narrowing the colour keeps only that colour's clauses", %{dir: dir} do
      install!(dir, reversed_kit(), %{components: ["acme-button"], color: ["brand"]})

      args = helper_args("acme-button")

      assert args == [~s|"brand", "soft"|, ~s|"brand", "solid"|]
      refute Enum.any?(args, &String.contains?(&1, "danger"))
    end

    test "narrowing the variant cuts on argument 1, where the call site put it", %{dir: dir} do
      install!(dir, reversed_kit(), %{components: ["acme-button"], variants: ["solid"]})

      assert helper_args("acme-button") == [~s|"brand", "solid"|, ~s|"danger", "solid"|]
    end

    # Both at once, and the clause that survives is the intersection.
    test "two axes narrow together", %{dir: dir} do
      install!(dir, reversed_kit(), %{
        components: ["acme-button"],
        color: ["danger"],
        variants: ["soft"]
      })

      assert helper_args("acme-button") == [~s|"danger", "soft"|]
    end

    # CANNOT-SAY KEEPS THE CLAUSE. Shipping one clause too many is a component that renders;
    # shipping one too few is a component that does not.
    test "an axis nobody narrowed keeps every clause", %{dir: dir} do
      install!(dir, reversed_kit(), %{components: ["acme-button"]})

      assert length(helper_args("acme-button")) == 4
    end
  end

  describe "a helper whose parameters no call site describes" do
    test "is kept whole rather than narrowed on a guess", %{dir: dir} do
      bundle = %{
        "$schema" => "mishka.ui_kit.bundle.v3",
        "name" => "orphan",
        "components" => [
          %{
            "name" => "orphan-box",
            "type" => "general",
            # `shade/1` is never called with an assign, so nothing says what its parameter means.
            "template" => ~s|<div class="static">x</div>|,
            "attrs" => [
              %{
                "name" => "variant",
                "type" => "string",
                "opts" => %{"values" => ["solid", "soft"]}
              }
            ],
            "helpers" => [
              %{
                "name" => "shade",
                "args" => ~s|"solid"|,
                "code" => ~s|defp shade("solid"), do: "a"|
              },
              %{
                "name" => "shade",
                "args" => ~s|"soft"|,
                "code" => ~s|defp shade("soft"), do: "b"|
              }
            ]
          }
        ]
      }

      install!(dir, bundle, %{components: ["orphan-box"], variants: ["solid"]})

      assert length(helper_args("orphan-box")) == 2,
             "an unbound parameter means cannot-say, and cannot-say keeps the clause"
    end
  end
end
