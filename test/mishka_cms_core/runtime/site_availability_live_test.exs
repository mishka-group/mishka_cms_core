# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteAvailabilityLiveTest do
  @moduledoc """
  A page left open — a public page, the dashboard, a sign-in page — closes the moment its site
  closes to whoever has it open: on a live navigation, on an event, and the moment the site's state
  changes, without waiting for the next click. The site's own admin keeps an offline site's pages;
  a sign-in address stays open while a site is offline, so that admin can get in.

  Sockets are built as a routed LiveView has them, and the hooks `on_mount/4` attaches are called
  the way LiveView calls them. `async: false` — `SiteState`, the settings cache and the plugin
  registry are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{LiveSockets, Permission, User}
  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, ViewerState}
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCore.Test.Plugins.{LiveSiteUnavailable, SiteAvailabilityChanged}
  alias Phoenix.LiveView.Socket

  setup do
    SettingsState.refresh()
    %{site: cached_site!(active: true)}
  end

  defp cached_site!(attrs) do
    n = System.unique_integer([:positive])
    site = create_site!([name: "live-#{n}", host: "live-#{n}.test"] ++ attrs)
    :ok = cache(site, site.active)
    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp cache(site, active?) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: active?,
      master: site.master
    })
  end

  defp offline!(site_id) do
    {:ok, _} = Settings.put("cms.offline", true, if(site_id, do: [site_id: site_id], else: []))
    on_exit(fn -> SettingsState.delete(site_id, "cms.offline") end)
  end

  defp signed_in(site_id, permissions) do
    user = %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(permissions, &%Permission{name: &1})
    }

    ViewerState.remember(user)
    on_exit(fn -> ViewerState.forget(user.id) end)
    user
  end

  defp register_plugin(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  # A routed LiveView's socket, connected unless asked otherwise, after `on_mount/4`.
  defp open(site, opts \\ []) do
    user = opts[:as]

    socket = %Socket{
      transport_pid: if(Keyword.get(opts, :connected, true), do: self()),
      router: MishkaCmsCore.TestRouter,
      private: %{connect_params: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}}
    }

    session = %{
      "current_site" => %{id: site.id},
      "live_socket_id" => user && LiveSockets.live_socket_id(user)
    }

    {:cont, socket} = SiteAvailability.on_mount(:default, %{}, session, socket)

    socket
  end

  defp hook(socket, stage, id),
    do: Enum.find(Map.fetch!(socket.private.lifecycle, stage), &(&1.id == id)).function

  defp navigate(socket, uri \\ "http://localhost/blog?page=2"),
    do: hook(socket, :handle_params, :site_availability_params).(%{}, uri, socket)

  defp event(socket),
    do: hook(socket, :handle_event, :site_availability_event).("save", %{}, socket)

  defp info(socket, message),
    do: hook(socket, :handle_info, :site_availability_info).(message, socket)

  defp arrived(site), do: {:site_availability_changed, site.id}

  describe "a page left open" do
    test "keeps working while its site is up", %{site: site} do
      assert {:cont, socket} = site |> open() |> navigate()
      assert {:cont, _socket} = event(socket)
      assert {:halt, %{redirected: nil}} = info(socket, arrived(site))
    end

    test "is sent back to its address, query included, the moment its site goes offline", %{
      site: site
    } do
      {:cont, socket} = site |> open() |> navigate()
      offline!(site.id)

      assert {:halt, socket} = info(socket, arrived(site))
      assert socket.redirected == {:redirect, %{to: "/blog?page=2", status: 302}}
    end

    test "has an event refused once its site is offline, even without the message", %{site: site} do
      {:cont, socket} = site |> open() |> navigate()
      offline!(site.id)

      assert {:halt, %{redirected: {:redirect, %{to: "/blog?page=2"}}}} = event(socket)
    end

    test "stays with the site's own admin, and a master, while the site is offline", %{site: site} do
      offline!(site.id)

      for user <- [signed_in(site.id, ["admin:dashboard:*"]), signed_in(nil, ["*"])] do
        {:cont, socket} = site |> open(as: user) |> navigate()
        assert {:halt, %{redirected: nil}} = info(socket, arrived(site))
      end
    end

    test "is closed for everyone the moment its site goes inactive, its admin and a master too",
         %{
           site: site
         } do
      users = [nil, signed_in(site.id, ["admin:dashboard:*"]), signed_in(nil, ["*"])]
      sockets = for user <- users, do: site |> open(as: user) |> navigate() |> elem(1)
      :ok = cache(site, false)

      for socket <- sockets do
        assert {:halt, %{redirected: {:redirect, _to}}} = info(socket, arrived(site))
      end
    end

    test "lets every other message through to the view", %{site: site} do
      {:cont, socket} = site |> open() |> navigate()

      assert {:cont, _socket} = info(socket, {:something, :else})
    end
  end

  # A SIGN-IN ADDRESS IS READ OFF EVERY NAVIGATION, `/auth…` and `/<language>/auth…` alike — see
  # `SiteLookupPlug.sign_in_path?/2` — so the page a visitor signs in on stays open, and the one
  # they navigate to next does not.
  describe "a sign-in page" do
    @sign_in [
      "http://localhost/en/auth",
      "http://localhost/en/auth/register?x=1",
      "http://localhost/auth"
    ]

    test "stays open while its site is offline, so the site's admin can sign in", %{site: site} do
      offline!(site.id)

      for uri <- @sign_in do
        assert {:cont, socket} = site |> open() |> navigate(uri), uri
        assert {:cont, _socket} = event(socket), uri
        assert {:halt, %{redirected: nil}} = info(socket, arrived(site)), uri
      end
    end

    test "an address that only looks like one is closed", %{site: site} do
      offline!(site.id)

      for uri <- [
            "http://localhost/xx/auth",
            "http://localhost/authors",
            "http://localhost/en/authors"
          ] do
        assert {:halt, %{redirected: {:redirect, _to}}} = site |> open() |> navigate(uri), uri
      end
    end

    test "is closed once the visitor navigates off it", %{site: site} do
      {:cont, socket} = site |> open() |> navigate("http://localhost/en/auth")
      offline!(site.id)

      assert {:halt, %{redirected: {:redirect, %{to: "/en/blog"}}}} =
               navigate(socket, "http://localhost/en/blog")
    end

    test "closes the moment its site goes inactive", %{site: site} do
      {:cont, socket} = site |> open() |> navigate("http://localhost/en/auth")
      :ok = cache(site, false)

      assert {:halt, %{redirected: {:redirect, %{to: "/en/auth"}}}} = info(socket, arrived(site))
    end
  end

  # EACH NODE'S CACHES TELL ITS OWN PAGES, once they hold the new state. The message only wakes the
  # page; what it reads next decides.
  describe "a change of state reaching the pages" do
    test "a site switched off or on reaches its open pages", %{site: site} do
      site_id = site.id
      open(site)
      :ok = cache(site, false)

      assert_receive {:site_availability_changed, ^site_id}
    end

    test "the site's offline switch reaches them", %{site: site} do
      site_id = site.id
      open(site)
      offline!(site.id)

      assert_receive {:site_availability_changed, ^site_id}
    end

    test "the global switch reaches every site's pages", %{site: site} do
      open(site)
      offline!(nil)

      assert_receive {:site_availability_changed, nil}
    end

    test "another site's change does not wake them", %{site: site} do
      other = cached_site!(active: true)
      other_id = other.id
      open(site)
      :ok = cache(other, false)

      refute_receive {:site_availability_changed, ^other_id}, 100
    end

    test "a page not connected yet listens to nothing", %{site: site} do
      socket = open(site, connected: false)
      :ok = cache(site, false)

      refute_receive {:site_availability_changed, _id}, 100
      assert Map.fetch!(socket.private.lifecycle, :handle_info) == []
    end
  end

  describe "plugin events" do
    test "each change is announced on runtime:state:site:availability_changed", %{site: site} do
      Process.register(self(), :__plugin_hook_probe__)
      register_plugin(SiteAvailabilityChanged, "runtime:state:site:availability_changed")
      site_id = site.id

      offline!(site.id)

      assert_receive {:availability_changed, ^site_id}
    end

    test "a plugin on web:live:site_unavailable may send a closed page elsewhere", %{site: site} do
      register_plugin(LiveSiteUnavailable, "web:live:site_unavailable")
      {:cont, socket} = site |> open() |> navigate()
      offline!(site.id)

      assert {:halt, %{redirected: {:redirect, %{to: "/closed-by-plugin"}}}} =
               info(socket, arrived(site))
    end
  end

  describe "web:live:site_unavailable while it cannot run" do
    test "a page left open is still sent back to its address once its site goes offline", %{
      site: site
    } do
      EventCannotRun.stub!("web:live:site_unavailable")
      {:cont, socket} = site |> open() |> navigate()
      offline!(site.id)

      assert {:halt, socket} = info(socket, arrived(site))
      assert socket.redirected == {:redirect, %{to: "/blog?page=2", status: 302}}
    end
  end

  # The hook does nothing unless the LiveView carries it; this fails if the line goes missing.
  describe "where it is attached" do
    test "every dashboard page, through ExtensionLiveView" do
      ids =
        Enum.map(
          MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.SettingsLive.__live__().lifecycle.mount,
          & &1.id
        )

      assert {SiteAvailability, :default} in ids
    end
  end
end
