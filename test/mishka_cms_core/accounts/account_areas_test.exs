defmodule MishkaCmsCore.Accounts.AccountAreasTest do
  @moduledoc """
  The Users and Permissions areas, on each surface.

  An account is listed, read, created, edited and deleted with `admin:<surface>:user`. What it holds
  is changed with `admin:<surface>:permission`, within the granter's own ceiling — a master's
  included. The catalogue is read with the permission area and written by a master holding it.
  Each gate is asked as a holder of that one area, and as a holder of the other.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.User
  @api %{shared: %{admin_surface: :api}}

  setup do
    site = create_site!()
    {:ok, site: site, member: create_user!(site_id: site.id)}
  end

  defp holder(names, site_id \\ nil), do: create_user_with_permissions!(names, site_id: site_id)

  defp list_users(actor, site_id, context \\ %{}) do
    User
    |> Ash.Query.for_read(:users, %{}, actor: actor, tenant: site_id, context: context)
    |> Ash.read()
    |> results()
  end

  defp results({:ok, %{results: results}}), do: {:ok, results}
  defp results(other), do: other

  defp ids({:ok, users}), do: Enum.map(users, & &1.id)
  defp ids({:error, _}), do: []

  describe "listing and reading accounts" do
    test "the user area lists its site's accounts; the permission area lists none", ctx do
      assert ctx.member.id in ids(
               list_users(holder(["admin:dashboard:user"], ctx.site.id), ctx.site.id)
             )

      refute ctx.member.id in ids(
               list_users(holder(["admin:dashboard:permission"], ctx.site.id), ctx.site.id)
             )
    end

    test "on the API the API's user area lists them, and the dashboard's does not", ctx do
      api_admin = holder(["admin:api:user"], ctx.site.id)
      dashboard_admin = holder(["admin:dashboard:user"], ctx.site.id)

      assert ctx.member.id in ids(list_users(api_admin, ctx.site.id, @api))
      refute ctx.member.id in ids(list_users(dashboard_admin, ctx.site.id, @api))
      refute ctx.member.id in ids(list_users(api_admin, ctx.site.id))
    end
  end
end
