# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.StylesheetTest do
  @moduledoc """
  JSON:API tests for the Stylesheet resource, `/v1/{tenant,master}/admin/runtime/stylesheet`.

  A stylesheet, its CSS included, is written by the stylesheet section or by code, on the surface
  the request came from: `admin:api:runtime:stylesheet` or `admin:api:code` over the API. The
  dashboard's names do not reach the API. A tenant reads its own site's stylesheets and the shared
  ones, and changes only its own.
  """
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  alias MishkaCmsCore.Runtime.Stylesheet
  alias MishkaCmsCoreWeb.Test.AreaApi

  @moduletag :unit
  @moduletag :capture_log

  @password "Password123!"
  @tenant_path "/api/json/v1/tenant/admin/runtime/stylesheet"
  @master_path "/api/json/v1/master/admin/runtime/stylesheet"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    Application.put_env(:ash_json_api, MishkaCmsCore.Runtime, router: MishkaCmsCore.TestRouter)

    site =
      create_site!(name: "localhost", host: "localhost", active: true, priority: 50, master: true)

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    master_user =
      MishkaCmsCore.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "master@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password)
      })
      |> Ash.create!(authorize?: false, tenant: nil)
      |> Ash.Changeset.for_update(
        :assign_permissions,
        %{permission_ids: [create_permission!(name: "admin:api:*").id]},
        authorize?: false
      )
      |> Ash.update!()

    on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.clear() end)

    %{site: site, master_user: master_user}
  end

  defp sheet!(attrs) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      Map.merge(
        %{name: AreaApi.unique("sheet"), content: ".a { color: red; }", format: :css},
        attrs
      ),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp sheet_attrs,
    do: %{"name" => AreaApi.unique("sheet"), "content" => ".a { color: red; }", "format" => "css"}

  describe "a tenant" do
    test "reads its own site's stylesheets and the shared ones, not another site's", %{
      site: site
    } do
      own = sheet!(%{site_id: site.id})
      shared = sheet!(%{site_id: nil})
      elsewhere = sheet!(%{site_id: create_site!().id})

      response = AreaApi.list(@tenant_path, area_token!(site, ["admin:api:runtime:page"]))

      assert response.status == 200
      ids = Enum.map(Jason.decode!(response.resp_body)["data"], & &1["id"])

      assert own.id in ids
      assert shared.id in ids
      refute elsewhere.id in ids
    end

    test "creates one with the stylesheet section, into its own site", %{site: site} do
      token = area_token!(site, ["admin:api:runtime:stylesheet"])

      response = AreaApi.post(@tenant_path, "stylesheet", token, sheet_attrs())

      assert response.status == 201
      assert Jason.decode!(response.resp_body)["data"]["attributes"]["site_id"] == site.id
    end

    test "does not change a shared stylesheet", %{site: site} do
      shared = sheet!(%{site_id: nil})
      token = area_token!(site, ["admin:api:runtime:stylesheet"])

      response =
        AreaApi.patch(@tenant_path, "stylesheet", shared.id, token, %{"description" => "mine"})

      refute response.status == 200
    end
  end

  describe "a master" do
    test "creates a stylesheet for any site", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{"type" => "stylesheet", "attributes" => Map.put(sheet_attrs(), "site_id", site.id)},
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 201
    end
  end

  # THE API HAS ITS OWN NAMES, AND CSS IS THE STYLESHEET SECTION'S OR CODE'S.
  describe "the stylesheet section over the API" do
    test "content is written by the section or by code; another section and the dashboard's names write none",
         %{site: site} do
      area = area_token!(site, ["admin:api:runtime:stylesheet"])
      code = area_token!(site, ["admin:api:code"])
      unrelated = area_token!(site, ["admin:api:runtime:js_hook"])

      dashboard =
        area_token!(site, ["admin:dashboard:runtime:stylesheet", "admin:dashboard:code"])

      assert AreaApi.post(@tenant_path, "stylesheet", code, sheet_attrs()).status == 201
      refute AreaApi.post(@tenant_path, "stylesheet", unrelated, sheet_attrs()).status == 201
      refute AreaApi.post(@tenant_path, "stylesheet", dashboard, sheet_attrs()).status == 201
      assert AreaApi.post(@tenant_path, "stylesheet", area, sheet_attrs()).status == 201
    end

    test "the section edits a stylesheet's details; the dashboard's names do not", %{
      site: site
    } do
      sheet = sheet!(%{site_id: site.id})
      area = area_token!(site, ["admin:api:runtime:stylesheet"])
      dashboard = area_token!(site, ["admin:dashboard:runtime:stylesheet"])
      unrelated = area_token!(site, ["admin:api:runtime:js_hook"])

      assert AreaApi.patch(@tenant_path, "stylesheet", sheet.id, dashboard, %{
               "description" => "d"
             }).status ==
               403

      assert AreaApi.patch(@tenant_path, "stylesheet", sheet.id, unrelated, %{
               "description" => "d"
             }).status ==
               403

      assert AreaApi.patch(@tenant_path, "stylesheet", sheet.id, area, %{"description" => "d"}).status ==
               200
    end

    test "another API section reads the list; a dashboard name does not", %{site: site} do
      assert AreaApi.list(@tenant_path, area_token!(site, ["admin:api:runtime:js_hook"])).status ==
               200

      assert AreaApi.list(@tenant_path, area_token!(site, ["admin:dashboard:runtime:stylesheet"])).status ==
               403
    end

    test "content changed over the API by the section alone is written", %{site: site} do
      sheet = sheet!(%{site_id: site.id})
      area = area_token!(site, ["admin:api:runtime:stylesheet"])

      response =
        AreaApi.patch(@tenant_path, "stylesheet", sheet.id, area, %{"content" => ".b {}"})

      assert response.status == 200
    end
  end
end
