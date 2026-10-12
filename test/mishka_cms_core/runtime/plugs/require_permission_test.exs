defmodule MishkaCmsCore.Runtime.Plugs.RequirePermissionTest do
  use MishkaCmsCore.ConnCase, async: false
  import Plug.Test
  import Phoenix.ConnTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsWeb.Runtime.Plugs.RequirePermission
  @moduletag :unit

  setup do
    # Create a basic conn for testing with session and flash fetched
    conn =
      conn(:get, "/test")
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.ConnTest.fetch_flash()

    {:ok, conn: conn}
  end

  describe "init/1" do
    test "returns permissions from options" do
      opts = [permissions: ["admin.access", "content.manage"]]
      assert RequirePermission.init(opts) == ["admin.access", "content.manage"]
    end

    test "returns empty list when no permissions specified" do
      assert RequirePermission.init([]) == []
    end

    test "returns empty list when permissions key is missing" do
      opts = [other_option: "value"]
      assert RequirePermission.init(opts) == []
    end

    test "handles single permission in list" do
      opts = [permissions: ["single.permission"]]
      assert RequirePermission.init(opts) == ["single.permission"]
    end

    test "preserves permission order" do
      opts = [permissions: ["first", "second", "third"]]
      assert RequirePermission.init(opts) == ["first", "second", "third"]
    end
  end

  describe "call/2 basic behavior" do
    test "denies access when current_user is nil", %{conn: conn} do
      # No current_user assigned
      result = RequirePermission.call(conn, ["any.permission"])

      assert result.halted

      assert Phoenix.Flash.get(result.assigns.flash, :error) ==
               "You don't have permission to access this page"

      assert redirected_to(result) == "/"
    end

    test "sets flash error message on denial", %{conn: conn} do
      result = RequirePermission.call(conn, ["test.permission"])

      assert result.halted

      assert Phoenix.Flash.get(result.assigns.flash, :error) ==
               "You don't have permission to access this page"
    end

    test "redirects to root path on denial", %{conn: conn} do
      result = RequirePermission.call(conn, ["test.permission"])

      assert redirected_to(result) == "/"
    end

    test "halts request processing on denial", %{conn: conn} do
      result = RequirePermission.call(conn, ["test.permission"])

      assert result.halted == true
    end
  end

  describe "call/2 while its events cannot run" do
    setup do
      EventCannotRun.stub!(["web:request:before_permission_gate", "web:request:permission_gate"])
    end

    test "still refuses a visitor without the permission", %{conn: conn} do
      result = RequirePermission.call(conn, ["test.permission"])

      assert result.halted
      assert redirected_to(result) == "/"
    end

    test "still lets in a user who holds it", %{conn: conn} do
      perm = create_permission!(name: "admin:dashboard:runtime:page")

      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      result =
        conn
        |> assign(:current_user, user)
        |> RequirePermission.call(["admin:dashboard:runtime:page"])

      refute result.halted
    end
  end

  describe "initialization and pipeline" do
    test "init returns permissions unchanged" do
      permissions = ["admin.access", "user.manage", "content.edit"]
      assert RequirePermission.init(permissions: permissions) == permissions
    end

    test "init handles empty options" do
      assert RequirePermission.init([]) == []
    end

    test "preserves conn fields when denying access", %{conn: conn} do
      conn =
        conn
        |> assign(:custom_data, "preserved")
        |> put_resp_header("x-custom", "header")

      result = RequirePermission.call(conn, ["denied.permission"])

      # Even when denied, custom data should be preserved
      assert result.assigns.custom_data == "preserved"
      assert get_resp_header(result, "x-custom") == ["header"]
    end
  end

  describe "edge cases" do
    test "handles empty permissions list", %{conn: conn} do
      # With no current_user and empty permissions
      result = RequirePermission.call(conn, [])

      # Should still deny because no current_user
      assert result.halted
    end

    test "handles nil permissions gracefully", %{conn: conn} do
      # This shouldn't crash
      result = RequirePermission.call(conn, nil)

      # Should process even with unexpected input
      assert is_map(result)
    end

    test "handles conn without assigns", %{conn: conn} do
      # Pattern match to tell type system conn is a Plug.Conn struct
      %Plug.Conn{} = conn
      # Create a bare conn with minimal setup (use map syntax, not struct syntax)
      bare_conn = %{
        conn
        | assigns: %{flash: %{}}
      }

      result = RequirePermission.call(bare_conn, ["test.permission"])

      assert result.halted
      assert redirected_to(result) == "/"
    end

    test "handles multiple sequential calls", %{conn: conn} do
      # First denial
      result1 = RequirePermission.call(conn, ["first.permission"])
      assert result1.halted

      # Can't really proceed after halt, but verify conn is still valid
      assert is_map(result1)
      # Redirect status
      assert result1.status == 302
    end
  end

  describe "call/2 when user has permissions" do
    test "allows access when user has exact matching permission", %{conn: conn} do
      # Create permissions
      perm = create_permission!(name: "admin:dashboard:runtime:page")

      # Create user and assign permissions
      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # User has admin:dashboard:runtime:page, endpoint requires admin:dashboard:runtime:page
      result = RequirePermission.call(conn, ["admin:dashboard:runtime:page"])

      # User has the exact permission, should allow access
      refute result.halted,
             "User with admin:dashboard:runtime:page should access admin:dashboard:runtime:page endpoint"
    end

    test "allows access when user has wildcard permission admin:*", %{conn: conn} do
      # Create wildcard permission
      perm = create_permission!(name: "admin:*")

      # Create user and assign permissions
      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # User has admin:*, endpoint requires admin:dashboard:runtime:page
      result = RequirePermission.call(conn, ["admin:dashboard:runtime:page"])

      # Wildcard should match, user should have access
      refute result.halted,
             "User with admin:* should access admin:dashboard:runtime:page endpoint"

      # Test multiple admin permissions
      result2 = RequirePermission.call(conn, ["admin:dashboard:permission"])
      refute result2.halted, "User with admin:* should access admin:dashboard:permission endpoint"

      result3 = RequirePermission.call(conn, ["admin:dashboard:setting"])
      refute result3.halted, "User with admin:* should access admin:dashboard:setting endpoint"
    end

    test "denies access when user has different branch permission", %{conn: conn} do
      # User has content permissions but tries to access admin
      perm = create_permission!(name: "content:*")

      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # User has content:*, endpoint requires admin:dashboard:runtime:page
      result = RequirePermission.call(conn, ["admin:dashboard:runtime:page"])

      # Different permission branch, should deny
      assert result.halted,
             "User with content:* should NOT access admin:dashboard:runtime:page endpoint"

      assert Phoenix.Flash.get(result.assigns.flash, :error) ==
               "You don't have permission to access this page"
    end

    test "allows access with super admin permission *", %{conn: conn} do
      # Create super admin with * permission
      perm = create_permission!(name: "*")

      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # Test various endpoints
      test_cases = [
        ["admin:dashboard:runtime:page"],
        ["content:edit"],
        ["system:config"],
        ["user:profile:update"],
        ["any:random:permission"]
      ]

      for required_permissions <- test_cases do
        result = RequirePermission.call(conn, required_permissions)
        refute result.halted, "Super admin with * should access #{inspect(required_permissions)}"
      end
    end

    test "allows access when user has one of multiple required permissions", %{conn: conn} do
      perm1 = create_permission!(name: "admin:dashboard:blog:post")
      perm2 = create_permission!(name: "admin:dashboard:blog:comment")

      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm1.id, perm2.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # User has admin:dashboard:blog:post, endpoint requires it
      result = RequirePermission.call(conn, ["admin:dashboard:blog:post"])
      refute result.halted, "User should access with exact permission match"

      # User doesn't have admin:dashboard:blog:tag
      result2 = RequirePermission.call(conn, ["admin:dashboard:blog:tag"])
      assert result2.halted, "User without admin:dashboard:blog:tag should be denied"
    end

    test "demonstrates nested wildcard permissions", %{conn: conn} do
      # User has admin:dashboard:blog:* - can do anything with blog
      perm = create_permission!(name: "admin:dashboard:blog:*")

      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # Should have access to all blog actions
      blog_permissions = [
        ["admin:dashboard:blog:tag"],
        ["admin:dashboard:blog:post"],
        ["admin:dashboard:blog:comment"],
        ["admin:dashboard:blog:team"]
      ]

      for perms <- blog_permissions do
        result = RequirePermission.call(conn, perms)
        refute result.halted, "User with admin:dashboard:blog:* should access #{inspect(perms)}"
      end

      # But NOT to other admin areas
      result = RequirePermission.call(conn, ["admin:dashboard:user"])

      assert result.halted,
             "User with admin:dashboard:blog:* should NOT access admin:dashboard:user"
    end

    test "checks multiple required permissions (user needs ANY)", %{conn: conn} do
      # User has only admin:read permission
      perm = create_permission!(name: "admin:read")

      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # Endpoint allows access with ANY of these permissions
      # Since RequirePermission passes the list to AccessPermissions which checks if user has ANY
      result = RequirePermission.call(conn, ["admin:read", "admin:write"])

      refute result.halted,
             "User with admin:read should access when admin:read OR admin:write is required"

      # User doesn't have any of these permissions
      result2 = RequirePermission.call(conn, ["admin:write", "admin:delete"])
      assert result2.halted, "User without any matching permission should be denied"
    end

    test "handles empty permissions list on user", %{conn: conn} do
      # User with no permissions
      user =
        create_user!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      result = RequirePermission.call(conn, ["any:permission"])
      assert result.halted, "User with no permissions should be denied"
    end

    test "handles complex permission hierarchy", %{conn: conn} do
      # User has specific nested wildcard
      perm = create_permission!(name: "system:config:database:*")

      user =
        create_user!()
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [perm.id]},
          authorize?: false
        )
        |> Ash.update!()
        |> Ash.load!(permissions: [:name])

      conn = assign(conn, :current_user, user)

      # Should have access to database operations
      result = RequirePermission.call(conn, ["system:config:database:read"])
      refute result.halted, "Should access database:read"

      result2 = RequirePermission.call(conn, ["system:config:database:write"])
      refute result2.halted, "Should access database:write"

      # Should NOT have access to other config areas
      result3 = RequirePermission.call(conn, ["system:config:security:read"])
      assert result3.halted, "Should NOT access security:read"

      # Should NOT have access to parent levels
      result4 = RequirePermission.call(conn, ["system:config"])
      assert result4.halted, "Should NOT access parent level without wildcard"
    end
  end

  describe "integration patterns" do
    test "works with typical controller usage", %{conn: conn} do
      # Simulate what happens in a controller
      permissions = RequirePermission.init(permissions: ["admin.access"])

      # No user, should be denied
      result = RequirePermission.call(conn, permissions)

      assert result.halted
      assert redirected_to(result) == "/"
    end

    test "maintains conn structure for middleware chain", %{conn: conn} do
      conn =
        conn
        |> assign(:request_id, "123")
        |> put_req_header("x-request-id", "123")

      result = RequirePermission.call(conn, ["test"])

      # Verify conn structure is maintained
      assert result.assigns.request_id == "123"
      assert get_req_header(result, "x-request-id") == ["123"]
    end

    test "handles various permission name formats", %{conn: conn} do
      test_cases = [
        ["simple"],
        ["dot.separated.permission"],
        ["colon:separated:permission"],
        ["hyphen-separated-permission"],
        ["UPPERCASE.PERMISSION"],
        ["with_underscores_permission"],
        ["with123numbers"],
        ["very.long.permission.name.with.many.segments.that.goes.on"]
      ]

      for permissions <- test_cases do
        result = RequirePermission.call(conn, permissions)

        # Should handle all formats without crashing
        assert result.halted
        assert is_map(result)
      end
    end
  end
end
