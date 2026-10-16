# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.AdminPredicatesTest do
  @moduledoc """
  Who is an admin, per surface, in `MishkaCmsCore.Accounts.Helper`: a dashboard admin holds anything
  under `admin:dashboard`, an API admin anything under `admin:api`. A master is only `site_id` nil;
  a permission never makes one. The cached viewer answers every question exactly as the user does.

  `async: false` because the viewer cache is process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Accounts.{Helper, Permission, User}
  alias MishkaCmsCore.Runtime.States.ViewerState

  defp user(site_id, names) do
    user = %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(names, &%Permission{name: &1})
    }

    on_exit(fn -> ViewerState.forget(user.id) end)
    user
  end

  describe "dashboard_admin?/1, api_admin?/1, admin?/1" do
    test "anything under the surface counts, a wildcard over it too" do
      for names <- [
            ["admin:dashboard:runtime:page"],
            ["admin:dashboard:code"],
            ["admin:dashboard:*"],
            ["admin:*"],
            ["*"]
          ] do
        assert Helper.dashboard_admin?(user(nil, names)), inspect(names)
      end

      for names <- [["admin:api:user"], ["admin:api:*"], ["admin:*"], ["*"]] do
        assert Helper.api_admin?(user(nil, names)), inspect(names)
      end
    end

    test "the other surface, an old name or nothing does not" do
      for names <- [["admin:api:*"], ["admin:site:*"], ["media:*"], []] do
        refute Helper.dashboard_admin?(user(nil, names)), inspect(names)
      end

      for names <- [["admin:dashboard:*"], ["admin:dashboard:runtime:page"], []] do
        refute Helper.api_admin?(user(nil, names)), inspect(names)
      end

      refute Helper.dashboard_admin?(nil)
      refute Helper.api_admin?(nil)
    end

    test "admin? is either surface, or the one asked for" do
      assert Helper.admin?(user(nil, ["admin:api:runtime:page"]))
      assert Helper.admin?(user(nil, ["admin:dashboard:runtime:page"]))
      refute Helper.admin?(user(nil, ["blog:post:*"]))
      refute Helper.admin?(nil)

      assert Helper.admin?(user(nil, ["admin:api:runtime:page"]), :api)
      refute Helper.admin?(user(nil, ["admin:api:runtime:page"]), :dashboard)
      assert Helper.admin?(user(nil, ["admin:api:runtime:page"]), :any)
    end
  end

  describe "master_admin?/1,2 and site_admin?/2,3" do
    test "a master is site_id nil and an admin of either surface" do
      assert Helper.master_admin?(user(nil, ["admin:dashboard:runtime:page"]))
      assert Helper.master_admin?(user(nil, ["admin:api:runtime:page"]))
      refute Helper.master_admin?(user(nil, []))

      refute Helper.master_admin?(user(Ecto.UUID.generate(), ["*"])),
             "a permission makes no master"

      refute Helper.master_admin?(nil)
    end

    test "a surface narrows it" do
      api_only = user(nil, ["admin:api:*"])

      assert Helper.master_admin?(api_only, :api)
      refute Helper.master_admin?(api_only, :dashboard)
      assert Helper.master_admin?(api_only, :any)
    end

    test "a site admin is an admin of its own site only" do
      site_id = Ecto.UUID.generate()
      admin = user(site_id, ["admin:dashboard:runtime:page"])

      assert Helper.site_admin?(admin, site_id)
      refute Helper.site_admin?(admin, Ecto.UUID.generate())
      refute Helper.site_admin?(admin, nil)
      refute Helper.site_admin?(user(nil, ["*"]), site_id), "a master is not a site's admin"
      refute Helper.site_admin?(user(site_id, []), site_id)

      assert Helper.site_admin?(user(site_id, ["admin:api:runtime:page"]), site_id, :api)
      refute Helper.site_admin?(user(site_id, ["admin:api:runtime:page"]), site_id, :dashboard)
    end

    test "a site admin asked with no surface is a dashboard admin of that site" do
      site_id = Ecto.UUID.generate()
      api_only = user(site_id, ["admin:api:*"])

      assert Helper.site_admin?(user(site_id, ["admin:dashboard:runtime:page"]), site_id)
      assert Helper.site_admin?(user(site_id, ["*"]), site_id)
      refute Helper.site_admin?(api_only, site_id), "an API-only admin"
      assert Helper.site_admin?(api_only, site_id, :api)
      assert Helper.site_admin?(api_only, site_id, :any)
    end
  end

  describe "full_admin?/2" do
    test "only a wildcard covering the whole surface" do
      for names <- [["admin:dashboard:*"], ["admin:*"], ["*"]] do
        assert Helper.full_admin?(user(nil, names), :dashboard), inspect(names)
      end

      for names <- [
            ["admin:dashboard:runtime:page"],
            ["admin:dashboard:runtime:*"],
            ["admin:api:*"],
            []
          ] do
        refute Helper.full_admin?(user(nil, names), :dashboard), inspect(names)
      end

      assert Helper.full_admin?(user(nil, ["admin:api:*"]), :api)
      refute Helper.full_admin?(nil, :dashboard)
    end
  end

  describe "oban_admin?/1" do
    test "a master who is a full dashboard admin, nobody else" do
      for names <- [["admin:dashboard:*"], ["admin:*"], ["*"]] do
        assert Helper.oban_admin?(user(nil, names)), inspect(names)
      end

      for names <- [
            ["admin:api:*"],
            ["admin:dashboard:runtime:page"],
            ["admin:dashboard:runtime:*"],
            []
          ] do
        refute Helper.oban_admin?(user(nil, names)), inspect(names)
      end

      refute Helper.oban_admin?(user(Ecto.UUID.generate(), ["*"])), "a site's full admin"
      refute Helper.oban_admin?(nil)
    end
  end

  describe "the cached viewer" do
    test "answers every predicate as the user does" do
      site_id = Ecto.UUID.generate()

      users =
        for site <- [nil, site_id],
            names <- [
              [],
              ["*"],
              ["admin:*"],
              ["admin:dashboard:*"],
              ["admin:dashboard:runtime:page"],
              ["admin:api:*"],
              ["admin:api:user"],
              ["admin:dashboard:blog:post"]
            ],
            do: user(site, names)

      for user <- users do
        ViewerState.remember(user)
        viewer = ViewerState.get(user.id)
        label = "#{inspect(user.site_id)} #{inspect(Enum.map(user.permissions, & &1.name))}"

        assert Helper.dashboard_admin?(viewer) == Helper.dashboard_admin?(user), label
        assert Helper.api_admin?(viewer) == Helper.api_admin?(user), label
        assert Helper.admin?(viewer) == Helper.admin?(user), label
        assert Helper.master_admin?(viewer) == Helper.master_admin?(user), label
        assert Helper.site_admin?(viewer, site_id) == Helper.site_admin?(user, site_id), label

        for surface <- [:dashboard, :api] do
          assert Helper.master_admin?(viewer, surface) == Helper.master_admin?(user, surface),
                 label

          assert Helper.site_admin?(viewer, site_id, surface) ==
                   Helper.site_admin?(user, site_id, surface),
                 label
        end
      end
    end

    test "holds each surface's answer" do
      admin = user(nil, ["admin:api:user"])
      ViewerState.remember(admin)

      assert %{site_id: nil, dashboard_admin?: false, api_admin?: true} =
               ViewerState.get(admin.id)
    end
  end
end
