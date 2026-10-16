# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.MediaCategoryGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.MediaCategory`.

    * `:name` — `sanitize(squish, no_control)` collapses runs of whitespace
      into a single space + strips ASCII control bytes.
    * `:description` — `sanitize(squish, no_zero_width)` collapses whitespace +
      strips zero-width unicode.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.MediaCategory
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute" do
      assert MapSet.new([:name, :description]) ==
               MediaCategory.__guarded_field_name_set__()
    end
  end

  describe "direct __guarded_change__/1" do
    test "name: multiple spaces collapsed to single; control bytes removed" do
      assert {:ok, %{name: "Hero Photos"}} =
               MediaCategory.__guarded_change__(%{name: "Hero    Photos"})

      assert {:ok, %{name: "Banner Images"}} =
               MediaCategory.__guarded_change__(%{name: "Banner\x01 Images"})
    end

    test "description: zero-width unicode and whitespace runs cleaned" do
      assert {:ok, %{description: "a category for hero shots"}} =
               MediaCategory.__guarded_change__(%{
                 description: "a   category for   he​ro  shots"
               })
    end

    test "empty input is a no-op" do
      assert {:ok, %{}} = MediaCategory.__guarded_change__(%{})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    test "description is squished on insert; name is squished then slugified", %{
      site_id: site_id
    } do
      attrs = %{
        name: "Hero    Banners",
        description: "Top   banner   images   used   site-wide"
      }

      assert {:ok,
              %MediaCategory{
                name: "hero-banners",
                description: "Top banner images used site-wide"
              }} =
               MediaCategory
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end
  end
end
