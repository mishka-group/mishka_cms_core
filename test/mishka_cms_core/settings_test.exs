defmodule MishkaCmsCore.SettingsTest do
  @moduledoc """
  Real tests for the settings store: the façade writes through the durable `Setting` resource and the
  ETS cache, and reads come back from RAM. The ETS cache is process-global (not sandboxed), so each
  test refreshes it from the (rolled-back) database in `on_exit`.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  require Ash.Query

  setup do
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    :ok
  end

  describe "get/2 and put/3" do
    test "round-trips a scalar value through the database and the RAM cache" do
      assert {:ok, "MishkaCMS"} = Settings.put("site.title", "MishkaCMS")

      # Read comes from ETS, not the DB.
      assert Settings.get("site.title") == "MishkaCMS"

      # And it is durable: exactly one row, value wrapped.
      assert [row] =
               Setting |> Ash.Query.filter(key == "site.title") |> Ash.read!(authorize?: false)

      assert row.value == %{"value" => "MishkaCMS"}
    end

    test "returns the default for an unknown key" do
      assert Settings.get("does.not.exist", 10) == 10
      assert Settings.get("does.not.exist") == nil
    end

    test "put/3 is an upsert — a second write updates in place, no duplicate row" do
      {:ok, _} = Settings.put("blog.posts_per_page", 10)
      {:ok, _} = Settings.put("blog.posts_per_page", 25)

      assert Settings.get("blog.posts_per_page") == 25

      assert Setting
             |> Ash.Query.filter(key == "blog.posts_per_page")
             |> Ash.count!(authorize?: false) == 1
    end

    test "stores non-scalar values (booleans, lists)" do
      {:ok, _} = Settings.put("cms.offline", false, category: "general")
      {:ok, _} = Settings.put("blog.tags", ["elixir", "phoenix"])

      assert Settings.get("cms.offline") == false
      assert Settings.get("blog.tags") == ["elixir", "phoenix"]
    end

    test "records the category and source for the settings page / extensions" do
      {:ok, _} = Settings.put("blog.posts_per_page", 10, category: "blog", source: :extension)

      setting =
        Setting
        |> Ash.Query.filter(key == "blog.posts_per_page")
        |> Ash.read_one!(authorize?: false)

      assert setting.category == "blog"
      assert setting.source == :extension
    end
  end

  test "all_global/0 returns every cached global setting unwrapped" do
    {:ok, _} = Settings.put("a.one", 1)
    {:ok, _} = Settings.put("a.two", "two")

    all = Settings.all_global()
    assert all["a.one"] == 1
    assert all["a.two"] == "two"
  end

  describe "authorization" do
    test "writes require a master/admin actor (reads are open)" do
      # No actor + authorization on → the write policy forbids it.
      assert {:error, %Ash.Error.Forbidden{}} =
               Setting
               |> Ash.Changeset.for_create(:master_set, %{key: "x.y", value: %{"value" => 1}})
               |> Ash.create()

      # Reads are open.
      assert {:ok, _} = Setting |> Ash.Query.for_read(:read) |> Ash.read()
    end
  end

  # THE CACHE IS PER NODE, THE CLUSTER IS NOT. `Settings.put/3` refreshes the key locally as soon as
  # its Ash write returns, so one machine was always right — but with `DNSCluster` there are several,
  # and a setting written on one node stayed stale on every other until that node restarted. There is
  # no second node in a test, so these drive the seam itself: the broadcast the resource already
  # publishes, delivered to a cache that did not write the row.
  describe "a write from another node" do
    defp remote_broadcast(setting, event) do
      Phoenix.PubSub.broadcast(
        MishkaCmsCore.PubSub,
        "setting:#{event}",
        %Phoenix.Socket.Broadcast{
          topic: "setting:#{event}",
          event: event,
          payload: %Ash.Notifier.Notification{
            resource: MishkaCmsCore.Runtime.Setting,
            data: setting
          }
        }
      )

      # The cache handles it in its own process; sync on a call so the assertion is not a race.
      _ = SettingsState.all_global()
      :sys.get_state(SettingsState)
    end

    test "reaches this node's cache" do
      {:ok, _} = Settings.put("cluster.probe", "written here")
      assert Settings.get("cluster.probe") == "written here"

      # The row moves on, and then the cache is put back to what it held before — which is the state
      # this node would be in had another node done the writing.
      {:ok, _} = Settings.put("cluster.probe", "written elsewhere")

      updated =
        Setting
        |> Ash.Query.filter(key == "cluster.probe")
        |> Ash.read_one!(action: :read_any, authorize?: false)

      :ets.insert(:mishka_cms_settings, {{nil, "cluster.probe"}, %{"value" => "written here"}})
      assert Settings.get("cluster.probe") == "written here", "precondition: cache is stale"

      remote_broadcast(updated, "updated")

      assert Settings.get("cluster.probe") == "written elsewhere"
    end

    test "a destroy elsewhere clears it here" do
      {:ok, _} = Settings.put("cluster.gone", "here")
      assert Settings.get("cluster.gone") == "here"

      setting =
        Setting
        |> Ash.Query.filter(key == "cluster.gone")
        |> Ash.read_one!(action: :read_any, authorize?: false)

      :ok = Ash.destroy(setting, action: :master_destroy, authorize?: false)
      :ets.insert(:mishka_cms_settings, {{nil, "cluster.gone"}, %{"value" => "here"}})

      assert Settings.get("cluster.gone") == "here",
             "precondition: cache still holds the deleted row"

      remote_broadcast(setting, "destroyed")

      assert Settings.get("cluster.gone", :absent) == :absent
    end
  end

  describe "text/1 — a definition's words, in the reader's language" do
    test "translates a marked text, and a text built from another" do
      Gettext.put_locale("fa")
      on_exit(fn -> Gettext.put_locale("en") end)

      assert Settings.text("Sites") == "[fa] Sites"

      assert Settings.text({"%{label} — position", label: "Sites"}) ==
               "[fa] [fa] Sites — position"
    end

    test "returns a text no translation knows as it is, and nil as nil" do
      assert Settings.text("A label nobody translated") == "A label nobody translated"
      assert Settings.text(nil) == nil
    end
  end
end
