# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.WebRunTimeMetaDataStateReloadTest do
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Runtime.Handlers.BootHandler

  setup do
    WebRunTimeMetaDataState.clear()
    on_exit(fn -> WebRunTimeMetaDataState.clear() end)
    :ok
  end

  describe "BootHandler.load_web_metadata/0 — reused loader that self-heals routing metadata" do
    test "repopulates routing rows from the DB after the tables are emptied" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      WebRunTimeMetaDataState.clear()

      assert WebRunTimeMetaDataState.find_by_path_and_site(page.path, site.name) ==
               {:error, :not_found}

      assert :ok = BootHandler.load_web_metadata()

      assert {:ok, %{id: id, section: "Page"}} =
               WebRunTimeMetaDataState.find_by_path_and_site(page.path, site.name)

      assert id == page.id
    end

    test "returns :ok and touches nothing for a route that does not exist" do
      assert :ok = BootHandler.load_web_metadata()

      assert WebRunTimeMetaDataState.find_by_path_and_site("/no-such-path", "none") ==
               {:error, :not_found}
    end
  end
end
