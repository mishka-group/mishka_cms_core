# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.UnderRequirementTest do
  @moduledoc """
  Every list that takes permissions takes `{:under, prefix}` as an entry: the RequirePermission
  plug, LiveUserAuth's `{:require_permission, …}`, a sidebar group and item and the PageGuard that
  reads them, a widget's and a setting's `:permission`, and a notification audience — through the
  Oban job args too. A version read asks for anything under the request's surface.
  """
  use MishkaCmsCore.DataCase, async: false

  import Plug.Test

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.LiveUserAuth
  alias MishkaCmsCore.Notify.Delivery
  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.Notify.Workers.FanoutWorker
  alias MishkaCmsCore.Runtime.Resources.Mixins.VersionReach
  alias MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Test.Plugins.UnderGatedMenu
  alias MishkaCmsWeb.Runtime.Plugs.RequirePermission
  alias MishkaInstaller.Event.{Event, EventHandler}
  alias Phoenix.LiveView.Socket

  @api {:under, "admin:api"}

  defp holder(names, site_id \\ nil) do
    %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(names, &%Permission{name: &1})
    }
  end

  defp socket(user, view \\ nil) do
    %Socket{
      router: MishkaCmsCore.TestRouter,
      endpoint: MishkaCmsCore.TestEndpoint,
      view: view,
      private: %{connect_params: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
      assigns: %{__changed__: %{}, current_user: user, flash: %{}}
    }
  end

  defp conn(user) do
    conn(:get, "/test")
    |> init_test_session(%{})
    |> Phoenix.ConnTest.fetch_flash()
    |> Plug.Conn.assign(:current_user, user)
  end

  describe "the RequirePermission plug" do
    test "lets anyone under the prefix through and refuses the rest" do
      refute RequirePermission.call(conn(holder(["admin:api:user"])), [@api]).halted
      assert RequirePermission.call(conn(holder(["admin:dashboard:runtime:page"])), [@api]).halted
    end

    test "counts a name on the surface the conn's Ash context names" do
      page = ["admin:dashboard:runtime:page", "admin:api:runtime:page"]

      on_api = fn names ->
        names
        |> holder()
        |> conn()
        |> Ash.PlugHelpers.update_context(&AdminSurfacePlug.put(&1, :api))
      end

      refute RequirePermission.call(on_api.(["admin:api:runtime:page"]), page).halted
      assert RequirePermission.call(on_api.(["admin:dashboard:runtime:page"]), page).halted
      refute RequirePermission.call(conn(holder(["admin:dashboard:runtime:page"])), page).halted
      assert RequirePermission.call(conn(holder(["admin:api:runtime:page"])), page).halted
    end

    test "answers a JSON refusal the same way" do
      opts = RequirePermission.init(permissions: [@api], on_denied: :json)

      refute RequirePermission.call(conn(holder(["admin:api:*"])), opts).halted
      assert RequirePermission.call(conn(holder(["admin:dashboard:*"])), opts).status == 403
    end
  end

  describe "LiveUserAuth {:require_permission, …}" do
    test "an entry under the prefix mounts, anything else is sent away" do
      assert {:cont, _socket} =
               LiveUserAuth.on_mount(
                 {:require_permission, [@api]},
                 %{},
                 %{},
                 socket(holder(["admin:api:runtime:page"]))
               )

      assert {:halt, _socket} =
               LiveUserAuth.on_mount(
                 {:require_permission, [@api]},
                 %{},
                 %{},
                 socket(holder(["admin:dashboard:runtime:page"]))
               )
    end
  end

  describe "a sidebar group and item, and the PageGuard that reads them" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: UnderGatedMenu,
          event: "sidebar:menus",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("sidebar:menus", :start, false)
      on_exit(fn -> Event.unregister(:name, UnderGatedMenu, false) end)
    end

    test "the page's declaration is the entry as written" do
      assert Sidebar.permissions_for_module(UnderGatedMenu.page()) == [@api]
    end

    test "PageGuard opens the page to anyone under the prefix" do
      assert {:cont, _socket} =
               Sidebar.PageGuard.on_mount(
                 :default,
                 %{},
                 %{},
                 socket(holder(["admin:api:user"]), UnderGatedMenu.page())
               )

      assert {:halt, _socket} =
               Sidebar.PageGuard.on_mount(
                 :default,
                 %{},
                 %{},
                 socket(holder(["admin:dashboard:*"]), UnderGatedMenu.page())
               )
    end

    test "the menu shows the group and its item to anyone under the prefix" do
      keys = fn user ->
        user
        |> Sidebar.menu()
        |> Map.fetch!(:main)
        |> Enum.flat_map(fn entry ->
          [entry.key | Enum.map(Map.get(entry, :items, []), & &1.key)]
        end)
      end

      assert "under-gated" in keys.(holder(["admin:api:user"]))
      assert "under-gated.page" in keys.(holder(["admin:api:user"]))
      refute "under-gated" in keys.(holder(["admin:dashboard:runtime:page"]))
    end
  end

  describe "a widget's and a setting's :permission" do
    test "one entry or a list of them" do
      assert Settings.permitted?(%{permission: @api}, holder(["admin:api:runtime:page"]))
      refute Settings.permitted?(%{permission: @api}, holder(["admin:dashboard:runtime:page"]))

      assert Settings.permitted?(
               %{permission: [@api, "admin:dashboard:runtime:page"]},
               holder(["admin:dashboard:runtime:page"])
             )

      assert Widget.permitted?(%{permission: [@api]}, holder(["admin:api:*"]))
      refute Widget.permitted?(%{permission: [@api]}, holder(["admin:dashboard:*"]))
    end

    test "{:under, :surface} is anything under the dashboard, where they are shown" do
      surface = {:under, :surface}

      assert Settings.permitted?(%{permission: surface}, holder(["admin:dashboard:runtime:page"]))
      refute Settings.permitted?(%{permission: surface}, holder(["admin:api:*"]))
      assert Widget.permitted?(%{permission: [surface]}, holder(["admin:dashboard:blog:post"]))
      refute Widget.permitted?(%{permission: [surface]}, holder(["admin:api:user"]))
    end
  end

  describe "{:under, :surface} and a named prefix in a gate's list" do
    test "LiveUserAuth reads them as the dashboard's and the named prefix's" do
      mount = fn required, names ->
        LiveUserAuth.on_mount({:require_permission, required}, %{}, %{}, socket(holder(names)))
      end

      assert {:cont, _socket} = mount.([{:under, :surface}], ["admin:dashboard:runtime:page"])
      assert {:halt, _socket} = mount.([{:under, :surface}], ["admin:api:*"])
      assert {:cont, _socket} = mount.([@api], ["admin:api:user"])
      assert {:halt, _socket} = mount.([@api], ["admin:dashboard:*"])
    end

    test "the RequirePermission plug reads them the same way" do
      refute RequirePermission.call(conn(holder(["admin:api:user"])), [@api]).halted
      assert RequirePermission.call(conn(holder(["admin:dashboard:*"])), [@api]).halted

      refute RequirePermission.call(conn(holder(["admin:dashboard:runtime:page"])), [
               {:under, :surface}
             ]).halted

      assert RequirePermission.call(conn(holder(["admin:api:*"])), [{:under, :surface}]).halted
    end
  end

  describe "a notification audience" do
    test "serializes an entry as a JSON map and reads it back" do
      site_id = Ecto.UUID.generate()
      audience = {:permission, [@api, "admin:dashboard:runtime:page"], site_id}

      assert Delivery.serialize(audience) == %{
               "kind" => "permission",
               "perms" => [%{"under" => "admin:api"}, "admin:dashboard:runtime:page"],
               "site_id" => site_id
             }

      assert audience
             |> Delivery.serialize()
             |> Jason.encode!()
             |> Jason.decode!()
             |> Delivery.deserialize() ==
               audience

      masters = {:permission_masters, [@api]}

      assert masters
             |> Delivery.serialize()
             |> Jason.encode!()
             |> Jason.decode!()
             |> Delivery.deserialize() ==
               masters
    end

    test "an entry is sent as its prefix, the request's surface as the dashboard's" do
      for {entry, prefix} <- [
            {{:under, :surface}, "admin:dashboard"},
            {{:under, "admin:dashboard"}, "admin:dashboard"},
            {@api, "admin:api"}
          ] do
        serialized = Delivery.serialize({:permission, [entry], nil})

        assert serialized["perms"] == [%{"under" => prefix}], inspect(entry)

        assert serialized |> Jason.encode!() |> Jason.decode!() |> Delivery.deserialize() ==
                 {:permission, [{:under, prefix}], nil},
               inspect(entry)

        assert Delivery.serialize({:permission_masters, entry})["perms"] == [
                 %{"under" => prefix}
               ],
               inspect(entry)
      end
    end

    test "{:under, :surface} reaches the dashboard's admins through the queued job" do
      site = create_site!()

      dashboard =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      _api = create_user_with_permissions!(["admin:api:user"], site_id: site.id)

      args =
        %{
          "audience" => Delivery.serialize({:permission, [{:under, :surface}], site.id}),
          "attrs" => %{"type" => "test:under:surface", "title" => "Queued"},
          "site_id" => site.id,
          "except" => []
        }
        |> Jason.encode!()
        |> Jason.decode!()

      assert :ok = FanoutWorker.perform(%Oban.Job{args: args})

      assert [%{user_id: user_id}] =
               Notification
               |> Ash.Query.filter(type == "test:under:surface")
               |> Ash.read!(authorize?: false, tenant: site.id)

      assert user_id == dashboard.id
    end

    test "reaches the users under the prefix, through the queued job too" do
      site = create_site!()
      api = create_user_with_permissions!(["admin:api:user"], site_id: site.id)

      _dashboard =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert Enum.map(Delivery.stream({:permission, @api, site.id}, []), & &1.id) == [api.id]

      args =
        %{
          "audience" => Delivery.serialize({:permission, [@api], site.id}),
          "attrs" => %{"type" => "test:under:queued", "title" => "Queued"},
          "site_id" => site.id,
          "except" => []
        }
        |> Jason.encode!()
        |> Jason.decode!()

      assert :ok = FanoutWorker.perform(%Oban.Job{args: args})

      assert [%{user_id: user_id}] =
               Notification
               |> Ash.Query.filter(type == "test:under:queued")
               |> Ash.read!(authorize?: false, tenant: site.id)

      assert user_id == api.id
    end
  end

  describe "the names a version asks for" do
    test "a version's read asks for anything under the request's surface" do
      reads? = version_reader()

      assert reads?.(["admin:dashboard:runtime:layout"], :dashboard)
      assert reads?.(["admin:api:runtime:page"], :api)
      refute reads?.(["admin:dashboard:runtime:layout"], :api)
      refute reads?.(["admin:api:*"], :dashboard)
      refute reads?.(["secret:role"], :dashboard)
    end
  end

  # The permission check the version policy authorizes with, evaluated as the policy would, run for
  # a holder of `names` on `surface`.
  defp version_reader do
    {_ast, checks} =
      [source: MishkaCmsCore.Runtime.Layout]
      |> VersionReach.policies()
      |> Macro.prewalk([], fn
        {:authorize_if, _meta, [{_module, _check_opts} = check]} = node, found ->
          {node, [check | found]}

        node, found ->
          {node, found}
      end)

    [check] = checks
    {{module, check_opts}, _binding} = Code.eval_quoted(check)

    fn names, surface ->
      query =
        MishkaCmsCore.Runtime.Layout
        |> Ash.Query.new()
        |> Ash.Query.set_context(%{shared: %{admin_surface: surface}})

      module.match?(holder(names), %{subject: query}, check_opts)
    end
  end
end
