# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.AccessPermissionsTest do
  @moduledoc """
  The matcher every gate asks: which held names cover a required one, the `{:under, prefix}` entry
  for "holds anything under", and which required names count on the surface the request came from.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Layout

  defp holder(names, site_id \\ nil) do
    %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(names, &%Permission{name: &1})
    }
  end

  defp holds?(names, required), do: AccessPermissions.match?(holder(names), %{}, required)

  defp on(surface) do
    query =
      case surface do
        nil ->
          Ash.Query.new(Layout)

        surface ->
          Ash.Query.set_context(Ash.Query.new(Layout), %{shared: %{admin_surface: surface}})
      end

    %{subject: query}
  end

  describe "covers?/2 — what a held name grants" do
    test "a trailing * covers every deeper level, a leaf covers only itself" do
      assert AccessPermissions.covers?("*", "admin:dashboard:runtime:page")
      assert AccessPermissions.covers?("admin:*", "admin:api:code")
      assert AccessPermissions.covers?("admin:dashboard:*", "admin:dashboard:runtime:page")
      assert AccessPermissions.covers?("admin:dashboard:*", "admin:dashboard:blog:post")
      assert AccessPermissions.covers?("admin:dashboard:*", "admin:dashboard:setting:secret")

      assert AccessPermissions.covers?(
               "admin:dashboard:runtime:page",
               "admin:dashboard:runtime:page"
             )

      refute AccessPermissions.covers?("admin:dashboard:*", "admin:api:runtime:page")
      refute AccessPermissions.covers?("admin:dashboard:code", "admin:dashboard:code:x")

      refute AccessPermissions.covers?(
               "admin:dashboard:setting",
               "admin:dashboard:setting:secret"
             )

      refute AccessPermissions.covers?("admin:dashboard:runtime:page", "admin:dashboard:*")
      refute AccessPermissions.covers?("admin:dashboard:*", "*")
    end
  end

  describe "a list of strings — unchanged" do
    test "any one held name covering any one required name grants" do
      assert holds?(["admin:dashboard:runtime:page"],
               permissions: ["admin:dashboard:runtime:page"]
             )

      assert holds?(["*"], permissions: ["admin:dashboard:runtime:page"])

      assert holds?(["admin:dashboard:*"],
               permissions: ["admin:api:runtime:page", "admin:dashboard:runtime:page"]
             )

      refute holds?(["admin:dashboard:runtime:page"],
               permissions: ["admin:dashboard:runtime:layout"]
             )

      refute holds?(["admin:api:*"], permissions: ["admin:dashboard:runtime:page"])
    end

    test "a required wildcard is met only by a wildcard covering it" do
      assert holds?(["admin:dashboard:*"], permissions: ["admin:dashboard:*"])
      assert holds?(["admin:*"], permissions: ["admin:dashboard:*"])
      assert holds?(["*"], permissions: ["admin:dashboard:*"])
      refute holds?(["admin:dashboard:runtime:page"], permissions: ["admin:dashboard:*"])
      refute holds?(["admin:dashboard:runtime:page"], permissions: ["*"])
    end

    test "nobody, nothing required, or an entry that is no requirement, grants nothing" do
      refute AccessPermissions.match?(nil, %{}, permissions: [{:under, "admin:dashboard"}])
      refute holds?(["*"], permissions: [])
      refute holds?(["*"], permissions: nil)
      refute holds?(["*"], [])
      refute holds?(["*"], permissions: [:admin, 1, {:under, nil}, {:other, "admin"}])
    end
  end

  describe "{:under, prefix} — holds anything under a prefix" do
    test "every name at or below the prefix counts, and every wildcard covering it" do
      for held <- [
            "*",
            "admin:*",
            "admin:dashboard:*",
            "admin:dashboard:runtime:page",
            "admin:dashboard:blog:post",
            "admin:dashboard:runtime:*"
          ] do
        assert holds?([held], permissions: [{:under, "admin:dashboard"}]), held
      end
    end

    test "nothing of another surface or another prefix counts" do
      for held <- [
            "admin:api:*",
            "admin:api:runtime:page",
            "admin:site:*",
            "admin:dashboardx:page",
            "media:*"
          ] do
        refute holds?([held], permissions: [{:under, "admin:dashboard"}]), held
      end
    end

    test "under an area" do
      under = {:under, "admin:dashboard:runtime"}

      assert holds?(["admin:dashboard:runtime:page"], permissions: [under])
      assert holds?(["admin:dashboard:*"], permissions: [under])
      refute holds?(["admin:dashboard:code"], permissions: [under])
    end

    test "sits in a list with strings, either one granting" do
      required = [{:under, "admin:api"}, "admin:dashboard:runtime:page"]

      assert holds?(["admin:api:user"], permissions: required)
      assert holds?(["admin:dashboard:runtime:page"], permissions: required)
      refute holds?(["admin:dashboard:runtime:layout"], permissions: required)
    end

    test "as the under: option" do
      assert holds?(["admin:dashboard:runtime:page"], under: "admin:dashboard")
      assert holds?(["admin:api:runtime:page"], under: ["admin:dashboard", "admin:api"])
      refute holds?(["admin:api:runtime:page"], under: "admin:dashboard")
    end

    test "holds_under?/2 takes a prefix" do
      page = holder(["admin:dashboard:runtime:page"])

      assert AccessPermissions.holds_under?(page, "admin:dashboard")
      refute AccessPermissions.holds_under?(page, "admin:api")
      refute AccessPermissions.holds_under?(nil, "admin:dashboard")
      refute AccessPermissions.holds_under?(holder([]), "admin:dashboard")
    end
  end

  describe "the request's surface" do
    @page ["admin:dashboard:runtime:page", "admin:api:runtime:page"]

    test "a dashboard name counts on the dashboard, when nothing says otherwise" do
      assert AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), %{},
               permissions: @page
             )

      assert AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), on(nil),
               permissions: @page
             )

      refute AccessPermissions.match?(holder(["admin:api:runtime:page"]), on(nil),
               permissions: @page
             )

      refute AccessPermissions.match?(holder(["admin:api:*"]), %{}, permissions: @page)
    end

    test "an api name counts on the api, when the request's shared context says so" do
      assert AccessPermissions.match?(holder(["admin:api:runtime:page"]), on(:api),
               permissions: @page
             )

      assert AccessPermissions.match?(holder(["admin:api:*"]), on(:api), permissions: @page)

      refute AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), on(:api),
               permissions: @page
             )

      refute AccessPermissions.match?(holder(["admin:dashboard:*"]), on(:api), permissions: @page)

      assert AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), on(:dashboard),
               permissions: @page
             )
    end

    test "a required name of one surface is met on the other by nothing, * included" do
      code = [permissions: ["admin:dashboard:code"]]

      assert AccessPermissions.match?(holder(["admin:dashboard:*"]), on(nil), code)
      refute AccessPermissions.match?(holder(["admin:api:*"]), on(:api), code)
      refute AccessPermissions.match?(holder(["*"]), on(:api), code)
    end

    test "any other required name counts on both" do
      for context <- [%{}, on(:api)], held <- ["*", "admin:*"] do
        assert AccessPermissions.match?(holder([held]), context, permissions: ["*"]) ==
                 (held == "*")

        assert AccessPermissions.match?(holder([held]), context, permissions: ["admin:*"])
      end
    end

    test "a list of areas, any one granting, and the wildcards over them" do
      blog = [
        permissions: [
          "admin:dashboard:blog:post",
          "admin:api:blog:post",
          "admin:dashboard:blog:comment",
          "admin:api:blog:comment"
        ]
      ]

      assert AccessPermissions.match?(holder(["admin:dashboard:blog:comment"]), on(nil), blog)
      assert AccessPermissions.match?(holder(["admin:dashboard:blog:*"]), on(nil), blog)
      assert AccessPermissions.match?(holder(["admin:api:*"]), on(:api), blog)
      assert AccessPermissions.match?(holder(["*"]), on(:api), blog)
      refute AccessPermissions.match?(holder(["admin:dashboard:*"]), on(:api), blog)
    end

    test "{:under, :surface} is anything under the request's surface" do
      assert AccessPermissions.match?(holder(["admin:api:user"]), on(:api), under: :surface)
      refute AccessPermissions.match?(holder(["admin:dashboard:user"]), on(:api), under: :surface)
      assert AccessPermissions.match?(holder(["admin:dashboard:user"]), %{}, under: :surface)
    end

    test "{:under, :surface} as an entry of a list is anything under the request's surface" do
      required = [permissions: [{:under, :surface}]]

      assert AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), %{}, required)
      assert AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), on(nil), required)
      assert AccessPermissions.match?(holder(["admin:api:user"]), on(:api), required)

      refute AccessPermissions.match?(
               holder(["admin:dashboard:runtime:page"]),
               on(:api),
               required
             )

      refute AccessPermissions.match?(holder(["admin:api:user"]), on(nil), required)
    end

    test "a prefix named in an entry is that prefix, wherever the request came from" do
      for required <- [[under: "admin:dashboard"], [permissions: [{:under, "admin:dashboard"}]]] do
        assert AccessPermissions.match?(
                 holder(["admin:dashboard:runtime:page"]),
                 on(:api),
                 required
               )

        assert AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), %{}, required)
        refute AccessPermissions.match?(holder(["admin:api:runtime:page"]), %{}, required)
      end

      for required <- [[under: "admin:api"], [permissions: [{:under, "admin:api"}]]] do
        assert AccessPermissions.match?(holder(["admin:api:user"]), %{}, required)
        refute AccessPermissions.match?(holder(["admin:dashboard:*"]), on(:api), required)
      end
    end

    test "still keeps a site user to its own site" do
      site_id = Ecto.UUID.generate()
      admin = holder(["admin:dashboard:*"], site_id)

      own = %{subject: Ash.Query.set_tenant(Ash.Query.new(Layout), site_id)}
      other = %{subject: Ash.Query.set_tenant(Ash.Query.new(Layout), Ecto.UUID.generate())}

      assert AccessPermissions.match?(admin, own, permissions: @page)
      refute AccessPermissions.match?(admin, other, permissions: @page)
      refute AccessPermissions.match?(admin, other, under: "admin:dashboard")
    end
  end

  describe "surface/1" do
    test "reads the shared context of a policy's subject, a subject, or a context" do
      assert AccessPermissions.surface(on(:api)) == :api
      assert AccessPermissions.surface(on(:api).subject) == :api
      assert AccessPermissions.surface(%{shared: %{admin_surface: :api}}) == :api
      assert AccessPermissions.surface(on(:dashboard)) == :dashboard
    end

    test "anything else is the dashboard" do
      assert AccessPermissions.surface(on(nil)) == :dashboard
      assert AccessPermissions.surface(%{}) == :dashboard
      assert AccessPermissions.surface(nil) == :dashboard
      assert AccessPermissions.surface(%{shared: %{admin_surface: "api"}}) == :dashboard
      assert AccessPermissions.surface(%{shared: %{admin_surface: :web}}) == :dashboard
    end
  end

  describe "an actor whose permissions are not loaded" do
    test "they are loaded for a user of a site, as for a master" do
      site = create_site!()
      stored = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)
      bare = Ash.get!(User, stored.id, tenant: site.id, authorize?: false)

      refute Ash.Resource.loaded?(bare, :permissions)
      assert AccessPermissions.holds_under?(bare, "admin:dashboard")
      assert AccessPermissions.match?(bare, %{}, permissions: ["admin:dashboard:runtime:page"])

      assert AccessPermissions.with_permissions(bare).permissions |> Enum.map(& &1.name) ==
               ["admin:dashboard:runtime:page"]
    end
  end

  describe "describe/1" do
    test "says what a policy asks" do
      assert AccessPermissions.describe(permissions: ["admin:dashboard:runtime:page"]) =~
               "admin:dashboard:runtime:page"

      assert AccessPermissions.describe(under: "admin:dashboard") =~ "under admin:dashboard"
      assert AccessPermissions.describe(under: :surface) =~ "the request's surface"

      assert AccessPermissions.describe(
               permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page"]
             ) =~
               "any of: admin:dashboard:runtime:page, admin:api:runtime:page"
    end
  end

  test "a name is matched as written" do
    assert holds?(["admin:dashboard:*"], permissions: ["admin:dashboard:runtime:error_page"])

    assert AccessPermissions.match?(holder(["admin:api:code"]), on(:api),
             permissions: ["admin:api:code"]
           )

    refute AccessPermissions.match?(holder(["admin:dashboard:code"]), on(:api),
             permissions: ["admin:api:code"]
           )
  end

  test "an old name grants nothing" do
    for old <- ["admin:site:*", "admin:users:*", "media:*", "blog:post:*", "page:code:write"],
        context <- [%{}, on(:api)] do
      refute AccessPermissions.match?(holder([old]), context,
               permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page"]
             ),
             old

      refute AccessPermissions.holds_under?(holder([old]), "admin:dashboard"), old
    end
  end
end
