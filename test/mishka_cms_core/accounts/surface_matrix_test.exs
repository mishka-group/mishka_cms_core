defmodule MishkaCmsCore.Accounts.SurfaceMatrixTest do
  @moduledoc """
  The dashboard and the API are separate: one page edit, made from the dashboard and over the admin
  JSON:API by a site admin holding exactly one name.

    * `admin:dashboard:*` and `admin:dashboard:runtime:page` edit from the dashboard only;
    * `admin:api:*` and `admin:api:runtime:page` edit over the API only;
    * `admin:*` and `*` edit from both.

  The dashboard's edit is the page's `:update` run as its screens run it, with the actor and the
  site and no surface in the context. The API's is a `PATCH` through the `/api/json` pipeline, whose
  `MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug` names the request the API's.
  """
  use MishkaCmsCore.ConnCase

  import MishkaCmsCore.Test.Factory
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  @moduletag :capture_log

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.SiteState

  @password "Password123!"
  @path "/api/json/v1/tenant/admin/runtime/page"

  @matrix %{
    "admin:dashboard:*" => %{dashboard: true, api: false},
    "admin:api:*" => %{dashboard: false, api: true},
    "admin:dashboard:runtime:page" => %{dashboard: true, api: false},
    "admin:api:runtime:page" => %{dashboard: false, api: true},
    "admin:*" => %{dashboard: true, api: true},
    "*" => %{dashboard: true, api: true}
  }

  setup do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Runtime, router: MishkaCmsCore.TestRouter)

    site =
      create_site!(name: "localhost", host: "localhost", active: true, priority: 50, master: true)

    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))
    on_exit(&SiteState.clear/0)

    %{site: site}
  end

  test "each name edits a page on its own surface and on no other", %{site: site} do
    edits =
      Map.new(@matrix, fn {name, _expected} ->
        holder = holder!(site, name)

        {name,
         %{
           dashboard: edits_on_dashboard?(page!(site), holder),
           api: edits_over_api?(page!(site), holder)
         }}
      end)

    assert edits == @matrix
  end

  defp holder!(site, name) do
    create_user_with_permissions!([name],
      site_id: site.id,
      email: "holder-#{System.unique_integer([:positive])}@example.com",
      password: @password,
      password_confirmation: @password
    )
  end

  defp page!(site) do
    n = System.unique_integer([:positive])

    Page
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Matrix #{n}", title: "Matrix #{n}", path: "/matrix-#{n}", template: "<div></div>"},
      tenant: site.id
    )
    |> Ash.create!(authorize?: false)
  end

  defp edits_on_dashboard?(page, holder) do
    page
    |> Ash.Changeset.for_update(:update, %{description: "dashboard"},
      actor: holder,
      tenant: page.site_id
    )
    |> Ash.update()
    |> case do
      {:ok, %Page{}} -> true
      {:error, %Ash.Error.Forbidden{}} -> false
    end
    |> tap(&assert(&1 == stored?(page, "dashboard")))
  end

  defp edits_over_api?(page, holder) do
    response =
      make_api_request(
        "#{@path}/#{page.id}",
        %{"type" => "page", "attributes" => %{"description" => "api"}},
        method: :patch,
        headers: [
          {"authorization", "Bearer #{sign_in_tenant(holder, @password)}"},
          {"content-type", "application/vnd.api+json"}
        ]
      )

    case response.status do
      200 -> true
      status when status in [403, 404] -> false
    end
    |> tap(&assert(&1 == stored?(page, "api")))
  end

  defp stored?(page, description),
    do:
      Ash.get!(Page, page.id, tenant: page.site_id, authorize?: false).description == description
end
