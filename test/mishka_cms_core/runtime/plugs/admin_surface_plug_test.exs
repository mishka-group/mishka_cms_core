# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.AdminSurfacePlugTest do
  @moduledoc """
  The plug that names the admin surface a pipeline's requests come from, and the context merge the
  GraphQL socket makes with it. What the surface changes — which names hold an area — is
  `MishkaCmsCore.Accounts.Checks.AccessPermissions`'s; this asks only that the surface is said, and
  that nothing else in the context is lost saying it.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Factory
  import Plug.Test, only: [conn: 2]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug
  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :unit

  defp call(conn, surface),
    do: AdminSurfacePlug.call(conn, AdminSurfacePlug.init(surface: surface))

  describe "init/1" do
    test "takes a surface" do
      assert AdminSurfacePlug.init(surface: :api) == :api
      assert AdminSurfacePlug.init(surface: :dashboard) == :dashboard
    end

    test "refuses anything else, so a mistyped pipeline does not compile" do
      assert_raise ArgumentError, fn -> AdminSurfacePlug.init(surface: :graphql) end
      assert_raise ArgumentError, fn -> AdminSurfacePlug.init([]) end
    end
  end

  describe "call/2" do
    test "puts the surface in the shared context a request with none gets" do
      conn = call(conn(:get, "/api/json"), :api)

      assert Ash.PlugHelpers.get_context(conn) == %{shared: %{admin_surface: :api}}
      assert AccessPermissions.surface(Ash.PlugHelpers.get_context(conn)) == :api
    end

    test "keeps what an earlier plug put in the context, shared or not" do
      conn =
        conn(:get, "/api/json")
        |> Ash.PlugHelpers.set_context(%{
          ash_authentication_request: %{remote_ip: "127.0.0.1"},
          shared: %{locale: "en"}
        })
        |> call(:api)

      assert Ash.PlugHelpers.get_context(conn) == %{
               ash_authentication_request: %{remote_ip: "127.0.0.1"},
               shared: %{locale: "en", admin_surface: :api}
             }
    end
  end

  describe "put/2" do
    test "merges the surface into a context map, as a socket needs with no conn" do
      assert AdminSurfacePlug.put(nil, :api) == %{shared: %{admin_surface: :api}}
      assert AdminSurfacePlug.put(%{}, :dashboard) == %{shared: %{admin_surface: :dashboard}}

      assert AdminSurfacePlug.put(%{shared: %{admin_surface: :dashboard}, other: 1}, :api) ==
               %{shared: %{admin_surface: :api}, other: 1}
    end
  end

  describe "the test router's :api pipeline" do
    test "runs as the API, as the CMS's does, so this library's API tests ask what the CMS asks" do
      name = "surface#{System.unique_integer([:positive])}"
      site = create_site!(name: name, host: "#{name}.test", active: true)

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: true
        })

      on_exit(fn -> SiteState.delete(site.id) end)

      conn =
        make_api_request("/api/json/v1/tenant/admin/runtime/page", nil,
          method: "GET",
          host: site.host
        )

      assert Ash.PlugHelpers.get_context(conn).shared == %{admin_surface: :api}
    end
  end
end
