# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.RuntimeAreasTest do
  @moduledoc """
  The site and media areas over the admin JSON:API: a bearer token reads sites with
  `admin:api:runtime:site`, reads media with anything under `admin:api` and writes it with
  `admin:api:runtime:media` — never with the dashboard's names.
  """
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :capture_log

  @password "Password123!"
  @sign_in "/api/json/v1/auth/user/sign-in"
  @sites "/api/json/v1/tenant/admin/runtime/site"
  @media "/api/json/v1/tenant/admin/runtime/media"
  @categories "/api/json/v1/tenant/admin/runtime/media-category"

  setup do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Runtime, router: MishkaCmsCore.TestRouter)
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsCore.TestRouter)

    site = create_site!(name: "runtime-areas", host: "runtime-areas.localhost", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active
    })

    on_exit(fn -> SiteState.clear() end)
    {:ok, site: site}
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

  describe "sites" do
    test "the API's site area lists its site", ctx do
      response = call("GET", @sites, token!(["admin:api:runtime:site"], ctx.site), ctx.site)

      assert response.status == 200
      assert ctx.site.id in ids(response)
    end

    test "the dashboard's site area lists nothing over the API", ctx do
      response = call("GET", @sites, token!(["admin:dashboard:runtime:site"], ctx.site), ctx.site)

      refute response.status == 200 and ctx.site.id in ids(response)
    end

    test "another API area lists nothing", ctx do
      response = call("GET", @sites, token!(["admin:api:runtime:media"], ctx.site), ctx.site)

      refute response.status == 200 and ctx.site.id in ids(response)
    end
  end

  describe "media" do
    defp edit(token, media, site) do
      call("PATCH", "#{@media}/#{media.id}", token, site, %{
        "type" => "media",
        "id" => media.id,
        "attributes" => %{"description" => "edited over the api"}
      })
    end

    test "anything under the API reads the library", ctx do
      media = create_media!(site_id: ctx.site.id)
      response = call("GET", @media, token!(["admin:api:runtime:page"], ctx.site), ctx.site)

      assert response.status == 200
      assert media.id in ids(response)
    end

    test "the dashboard's names read nothing over the API", ctx do
      media = create_media!(site_id: ctx.site.id)

      response =
        call("GET", @media, token!(["admin:dashboard:runtime:media"], ctx.site), ctx.site)

      refute response.status == 200 and media.id in ids(response)
    end

    test "the API's media area edits media", ctx do
      media = create_media!(site_id: ctx.site.id)

      assert edit(token!(["admin:api:runtime:media"], ctx.site), media, ctx.site).status == 200
    end

    test "the dashboard's media area and another API area do not", ctx do
      media = create_media!(site_id: ctx.site.id)

      assert edit(token!(["admin:dashboard:runtime:media"], ctx.site), media, ctx.site).status in [
               403,
               404
             ]

      assert edit(token!(["admin:api:runtime:page"], ctx.site), media, ctx.site).status == 403
    end

    test "media categories are read under the API and written with its media area", ctx do
      category = create_media_category!(site_id: ctx.site.id)
      response = call("GET", @categories, token!(["admin:api:runtime:page"], ctx.site), ctx.site)

      assert response.status == 200
      assert category.id in ids(response)

      body = %{
        "type" => "media_category",
        "id" => category.id,
        "attributes" => %{"description" => "edited over the api"}
      }

      path = "#{@categories}/#{category.id}"

      assert call("PATCH", path, token!(["admin:api:runtime:page"], ctx.site), ctx.site, body).status ==
               403

      assert call("PATCH", path, token!(["admin:api:runtime:media"], ctx.site), ctx.site, body).status ==
               200
    end
  end
end
