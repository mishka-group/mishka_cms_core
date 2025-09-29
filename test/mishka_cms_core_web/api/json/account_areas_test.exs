defmodule MishkaCmsCoreWeb.Api.Json.AccountAreasTest do
  @moduledoc """
  The Users and Permissions areas over the admin JSON:API: a bearer token opens them with
  `admin:api:user` and `admin:api:permission`, and never with the dashboard's names.
  """
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @moduletag :capture_log

  @password "Password123!"
  @sign_in "/api/json/v1/auth/user/sign-in"
  @admin "/api/json/v1/auth/admin"
  @catalogue "/api/json/v1/tenant/admin/permissions"

  setup do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsCore.TestRouter)

    site = create_site!(name: "areas-site", host: "areas.localhost", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active
    })

    on_exit(fn -> SiteState.clear() end)

    {:ok, site: site, member: create_user!(site_id: site.id)}
  end

  defp token!(names, site) do
    user =
      create_user_with_permissions!(names,
        site_id: site.id,
        password: @password,
        password_confirmation: @password
      )

    response =
      make_api_request(
        @sign_in,
        %{
          "type" => "user",
          "attributes" => %{"email" => to_string(user.email), "password" => @password}
        },
        headers: [{"x-no-tenant", "false"}],
        host: site.host
      )

    assert response.status == 201
    Jason.decode!(response.resp_body)["meta"]["token"]
  end

  defp call(method, path, token, site, data \\ nil),
    do:
      make_api_request(path, data,
        method: method,
        headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
        host: site.host
      )

  defp ids(response),
    do: response.resp_body |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["id"])

  describe "GET /v1/auth/admin/users" do
    test "lists the site's accounts to the API's user area", ctx do
      response = call("GET", "#{@admin}/users", token!(["admin:api:user"], ctx.site), ctx.site)

      assert response.status == 200
      assert ctx.member.id in ids(response)
    end

    test "refuses a bearer holding only the dashboard's user area", ctx do
      token = token!(["admin:dashboard:user"], ctx.site)

      assert call("GET", "#{@admin}/users", token, ctx.site).status == 403
    end
  end

  describe "PATCH and DELETE /v1/master/admin/permissions/:id" do
    @master_catalogue "/api/json/v1/master/admin/permissions"

    setup do
      master_site =
        create_site!(name: "localhost", host: "localhost", active: true, master: true)

      SiteState.save(%{
        id: master_site.id,
        name: master_site.name,
        host: master_site.host,
        priority: master_site.priority,
        active: master_site.active,
        master: master_site.master
      })

      :ok
    end

    defp master_token!(names) do
      create_user_with_permissions!(names, password: @password, password_confirmation: @password)
      |> MishkaCmsCoreWeb.Test.AuthTestHelpers.sign_in_master(@password)
    end

    defp master_call(method, id, token, attributes \\ nil) do
      data = if attributes, do: %{"type" => "permission", "id" => id, "attributes" => attributes}

      make_api_request("#{@master_catalogue}/#{id}", data,
        method: method,
        headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
      )
    end

    defp row!(name) do
      MishkaCmsCore.Accounts.Permission
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil -> create_permission!(name: name)
        row -> row
      end
    end

    test "a master of the API's permission area renames a row it holds; a dashboard one does not" do
      row = row!("admin:api:probe:before")
      rename = %{"name" => "admin:api:probe:after"}

      dashboard_token = master_token!(["admin:dashboard:*", "admin:api:probe:*"])
      assert master_call("PATCH", row.id, dashboard_token, rename).status == 403

      api_token = master_token!(["admin:api:permission", "admin:api:probe:*"])
      assert master_call("PATCH", row.id, api_token, rename).status == 200
    end
  end

  describe "GET /v1/tenant/admin/permissions" do
    test "lists the catalogue to the API's permission area", ctx do
      create_permission!(name: "admin:api:runtime:page")
      token = token!(["admin:api:permission"], ctx.site)

      assert call("GET", @catalogue, token, ctx.site).status == 200
    end

    test "refuses a bearer holding only the dashboard's permission area", ctx do
      token = token!(["admin:dashboard:permission"], ctx.site)

      assert call("GET", @catalogue, token, ctx.site).status == 403
    end
  end
end
