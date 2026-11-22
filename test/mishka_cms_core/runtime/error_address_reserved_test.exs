# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ErrorAddressReservedTest do
  @moduledoc """
  The address a site's Error Page answers at is its own: a page or a layout saved there would take
  the routing entry the renderer looks it up by.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage, Layout, LayoutDraft, Page, PageDraft}

  setup do
    {:ok, site: create_site!()}
  end

  defp refusals(resource, path, site) do
    resource
    |> Ash.Changeset.for_create(:create, %{path: path}, tenant: site.id, authorize?: false)
    |> Map.fetch!(:errors)
    |> Enum.filter(&(Map.get(&1, :field) == :path))
    |> Enum.map(& &1.message)
  end

  for resource <- [Page, PageDraft, Layout, LayoutDraft] do
    test "is refused to a #{inspect(resource)}", %{site: site} do
      path = ErrorAddress.path(site.name)

      for path <- [path, String.replace(path, "errors", "%65rrors"), ErrorAddress.path("another")],
          do:
            assert(
              "This path is kept for the site's error pages" in refusals(
                unquote(resource),
                path,
                site
              )
            )

      assert refusals(unquote(resource), "/mishka-cms/errors", site) == []
      assert refusals(unquote(resource), "/mishka-cms/errors-guide", site) == []
    end
  end

  test "is refused to a page that moves there", %{site: site} do
    page = create_page!(site_id: site.id)

    assert {:error, %Ash.Error.Invalid{}} =
             page
             |> Ash.Changeset.for_update(:update, %{path: ErrorAddress.path(site.name)},
               tenant: site.id,
               authorize?: false
             )
             |> Ash.update()
  end

  test "is the Error Page's", %{site: site} do
    assert refusals(ErrorPage, "/anything", site) == []
    assert create_error_page!(site_id: site.id).path == ErrorAddress.path(site.name)
  end
end
