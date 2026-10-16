# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.ViewerStateTest do
  @moduledoc """
  Who a signed-in user is to the site gates, cached by id so a file or a live navigation can ask
  without loading the user — and dropped the moment their access changes, on every node, so the
  answer never outlives the change.

  `async: false` because the table is process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Accounts.{Helper, LiveSockets, Permission, User}
  alias MishkaCmsCore.Runtime.States.ViewerState

  defp user(site_id, permissions) do
    user = %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(permissions, &%Permission{name: &1})
    }

    on_exit(fn -> ViewerState.forget(user.id) end)
    user
  end

  describe "remember/1 and get/1" do
    test "a master admin is cached with no site, as an admin" do
      master = user(nil, ["*"])
      ViewerState.remember(master)

      assert ViewerState.get(master.id) == %{
               id: master.id,
               site_id: nil,
               email: "",
               permissions: [%{name: "*"}],
               dashboard_admin?: true,
               api_admin?: true
             }
    end

    test "a site's user without the dashboard is cached, but not as an admin" do
      site_id = Ecto.UUID.generate()
      member = user(site_id, ["probe:role"])
      ViewerState.remember(member)

      assert ViewerState.get(member.id) == %{
               id: member.id,
               site_id: site_id,
               email: "",
               permissions: [%{name: "probe:role"}],
               dashboard_admin?: false,
               api_admin?: false
             }
    end

    test "a later page load rewrites what changed" do
      site_id = Ecto.UUID.generate()
      member = user(site_id, ["probe:role"])
      ViewerState.remember(member)
      ViewerState.remember(%{member | permissions: [%Permission{name: "admin:dashboard:*"}]})

      assert ViewerState.get(member.id).dashboard_admin?
    end

    test "nobody is cached for a visitor or an unknown id" do
      assert ViewerState.remember(nil) == :ok
      assert ViewerState.get(nil) == nil
      assert ViewerState.get(Ecto.UUID.generate()) == nil
    end
  end

  describe "the gates' questions, answered from the cache" do
    test "master_admin?/1 and site_admin?/2 read a cached viewer as they read a user" do
      site_id = Ecto.UUID.generate()
      master = user(nil, ["admin:dashboard:*"])
      admin = user(site_id, ["admin:dashboard:*"])
      Enum.each([master, admin], &ViewerState.remember/1)

      assert Helper.master_admin?(ViewerState.get(master.id))
      refute Helper.master_admin?(ViewerState.get(admin.id))
      assert Helper.site_admin?(ViewerState.get(admin.id), site_id)
      refute Helper.site_admin?(ViewerState.get(admin.id), Ecto.UUID.generate())
    end
  end

  describe "forgetting" do
    # Every change to a user's access goes through `LiveSockets.disconnect/1`: a permission granted or
    # taken, the account changed or deleted, signing out.
    test "cutting a user's sockets drops what was cached for them" do
      admin = user(nil, ["*"])
      ViewerState.remember(admin)

      LiveSockets.disconnect(admin)

      assert ViewerState.get(admin.id) == nil
    end

    # Another node's `forget/1` reaches this one as a message; `:sys.get_state/1` returns once it is
    # handled.
    test "a forget sent from another node drops the entry here too" do
      admin = user(nil, ["*"])
      ViewerState.remember(admin)

      Phoenix.PubSub.broadcast(
        MishkaCmsCore.PubSub,
        "viewer_state",
        {:forget_viewer, admin.id, :other@node}
      )

      _handled = :sys.get_state(ViewerState)

      assert ViewerState.get(admin.id) == nil
    end
  end

  describe "LiveSockets.user_id/1" do
    test "reads the user id back out of a session's live_socket_id" do
      id = Ecto.UUID.generate()

      assert id |> LiveSockets.live_socket_id() |> LiveSockets.user_id() == id
      assert LiveSockets.user_id(nil) == nil
      assert LiveSockets.user_id("something-else") == nil
    end
  end

  # ONE ANNOUNCEMENT PER CHANGE, PER NODE. A write that changes nothing is not announced, and a
  # forget this node broadcast is not announced a second time when the broadcast comes back.
  describe "runtime:state:viewer:changed" do
    setup do
      Process.register(self(), :__plugin_hook_probe__)

      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: MishkaCmsCore.Test.Plugins.ViewerStateChanged,
          event: "runtime:state:viewer:changed",
          extension: :mishka_installer,
          status: :started
        })

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile(
          "runtime:state:viewer:changed",
          :start,
          false
        )

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(
          :name,
          MishkaCmsCore.Test.Plugins.ViewerStateChanged,
          false
        )
      end)

      :ok
    end

    test "announces a write, not a write that changes nothing, and a drop once" do
      admin = user(nil, ["*"])
      id = admin.id

      ViewerState.remember(admin)
      assert_receive {:viewer_changed, :save, ^id}

      ViewerState.remember(admin)
      refute_receive {:viewer_changed, :save, ^id}, 100

      ViewerState.forget(id)
      _handled = :sys.get_state(ViewerState)
      assert_receive {:viewer_changed, :delete, ^id}
      refute_receive {:viewer_changed, :delete, ^id}, 100
    end

    test "announces a drop another node sent" do
      admin = user(nil, ["*"])
      id = admin.id
      ViewerState.remember(admin)
      assert_receive {:viewer_changed, :save, ^id}

      Phoenix.PubSub.broadcast(
        MishkaCmsCore.PubSub,
        "viewer_state",
        {:forget_viewer, id, :other@node}
      )

      _handled = :sys.get_state(ViewerState)
      assert_receive {:viewer_changed, :delete, ^id}
    end
  end
end
