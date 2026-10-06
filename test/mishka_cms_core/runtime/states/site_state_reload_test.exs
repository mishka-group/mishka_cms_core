defmodule MishkaCmsCore.Runtime.States.SiteStateReloadTest do
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Handlers.BootHandler

  setup do
    SiteState.clear()
    on_exit(fn -> SiteState.clear() end)
    :ok
  end

  describe "BootHandler.load_sites/0 — the reused loader that self-heals the SiteState cache" do
    test "repopulates the ETS host cache from the database after the tables are emptied" do
      site = create_site!()

      # Simulate an owner crash: the ETS tables are empty and nothing repopulates them.
      SiteState.clear()
      assert SiteState.get_by_host(site.host) == {:error, :not_found}

      assert :ok = BootHandler.load_sites()

      assert {:ok, %{id: id}} = SiteState.get_by_host(site.host)
      assert id == site.id
    end

    test "returns :ok and touches nothing for an unknown host" do
      assert :ok = BootHandler.load_sites()
      assert SiteState.get_by_host("no-such-host.example") == {:error, :not_found}
    end
  end
end
