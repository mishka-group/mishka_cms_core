defmodule MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlugTest do
  @moduledoc """
  Who the API of an offline or switched-off site answers: its API admins and the masters who are
  API admins. A dashboard admin reaches the screens of an offline site, not its API.

  `async: false` — `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  setup do
    SettingsState.refresh()
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    :ok
  end

  defp cached_site!(attrs) do
    n = System.unique_integer([:positive])
    site = create_site!([name: "api-avail-#{n}", host: "api-avail-#{n}.test"] ++ attrs)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp user(site_id, permissions),
    do: %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(permissions, &%Permission{name: &1})
    }

  defp through_plug(site, user) do
    Plug.Test.conn(:get, "/api/json/anything")
    |> Plug.Conn.assign(:current_site, site)
    |> Plug.Conn.assign(:current_user, user)
    |> ApiAvailabilityPlug.call(ApiAvailabilityPlug.init(api: :json_api))
  end

  describe "an offline site's API" do
    test "passes its API admin and refuses its dashboard-only admin" do
      site = cached_site!(active: true)
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

      refute through_plug(site, user(site.id, ["admin:api:runtime:media"])).halted
      assert through_plug(site, user(site.id, ["admin:dashboard:*"])).status == 503
    end

    test "passes a master who is an API admin and refuses a dashboard-only master" do
      site = cached_site!(active: true)
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

      refute through_plug(site, user(nil, ["admin:api:*"])).halted
      assert through_plug(site, user(nil, ["admin:dashboard:*"])).status == 503
    end
  end
end
