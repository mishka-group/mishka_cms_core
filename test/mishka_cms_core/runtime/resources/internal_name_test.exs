# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.InternalNameTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.Resources.Changes.InternalName`: the `name` a component, page, layout and
  the rest are saved under becomes a module, CSS and file name, so it is ASCII, and a name with no
  Latin letter left is refused with a sentence the admin can act on, never stored empty.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.Resources.Changes.InternalName

  defp create_page(site, name) do
    Page
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        title: "Title",
        path: "/p-#{System.unique_integer([:positive])}",
        template: "<div class='p'></div>"
      },
      tenant: site.id
    )
    |> Ash.create(authorize?: false)
  end

  test "a Latin name with accents is stored as ASCII" do
    assert {:ok, page} = create_page(create_site!(), "Café Crème Brûlée")
    assert page.name == "cafe-creme-brulee"
    assert page.name == InternalName.slug("Café Crème Brûlée")
  end

  test "`_` and `.` are word breaks, so a name stays one kebab-case word list" do
    assert {:ok, page} = create_page(create_site!(), "__my_page.v2__")
    assert page.name == "my-page-v2"
  end

  test "letters of other scripts are dropped beside Latin ones" do
    assert {:ok, page} = create_page(create_site!(), "آموزش React")
    assert page.name == "react"
  end

  test "Persian, Arabic-Indic and Devanagari digits are stored as 0-9" do
    site = create_site!()

    for {typed, stored} <- [
          {"Header ۱۲۳", "header-123"},
          {"Box ١٢ ४५", "box-12-45"},
          {"Page ४५६", "page-456"}
        ] do
      assert {:ok, page} = create_page(site, typed)
      assert page.name == stored
      assert InternalName.slug(typed) == stored
      assert page.name =~ ~r/\A[a-z0-9-]+\z/
    end
  end

  test "a name of only non-ASCII digits is stored like the same Latin digits" do
    for typed <- ["۱۲۳", "١٢٣", "१२३"] do
      assert InternalName.slug(typed) == InternalName.slug("123")
    end

    assert {:ok, page} = create_page(create_site!(), "۱۲۳")
    assert page.name == InternalName.slug("123")
  end

  test "a Persian-only name is refused with an error on name, nothing stored" do
    assert {:error, %Ash.Error.Invalid{errors: errors}} = create_page(create_site!(), "قیمت‌گذاری")

    assert [error] = Enum.filter(errors, &(&1.field == :name))
    assert error.message =~ "Latin letters"
    assert InternalName.slug("قیمت‌گذاری") == nil
  end

  test "an update to a Persian-only name is refused and the stored name kept" do
    site = create_site!()
    {:ok, page} = create_page(site, "Pricing")

    assert {:error, %Ash.Error.Invalid{}} =
             page
             |> Ash.Changeset.for_update(:update, %{name: "قیمت"}, tenant: site.id)
             |> Ash.update(authorize?: false)

    assert Ash.get!(Page, page.id, tenant: site.id, authorize?: false).name == "pricing"
  end
end
