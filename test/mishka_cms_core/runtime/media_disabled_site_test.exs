defmodule MishkaCmsCore.Runtime.MediaDisabledSiteTest do
  @moduledoc """
  A switched-off site's files, as a master manages them.

  A master manages an inactive site from the dashboard like any other, so `master_read` lists its
  files beside every other site's. The one place that must not offer them is the visual editor
  choosing a file for a GLOBAL document, which every site renders — that is the Media table's own
  `on_load`, covered with the editor.

  `read_any`, `get_any` and `master_get` are how a file a page ALREADY references is resolved, and a
  page that works keeps working while its site is off.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.Media

  require Ash.Query

  defp unique, do: System.unique_integer([:positive])

  setup do
    n = unique()
    live = create_site!(name: "live-#{n}", host: "live-#{n}.test", active: true)
    off = create_site!(name: "off-#{n}", host: "off-#{n}.test", active: false)

    here = create_media!(site_id: live.id, name: "on-a-live-site")
    there = create_media!(site_id: off.id, name: "on-a-dead-site")

    {:ok, live: live, off: off, here: here, there: there}
  end

  defp master, do: %User{id: Ecto.UUID.generate(), site_id: nil}

  defp browsed do
    Media
    |> Ash.Query.for_read(:master_read, %{}, actor: master(), authorize?: false)
    |> Ash.read!(page: [limit: 100])
    |> Map.fetch!(:results)
    |> Enum.map(& &1.name)
  end

  describe "a master's library" do
    test "lists a live site's files", %{here: here} do
      assert here.name in browsed()
    end

    test "and a switched-off site's too, for the master to manage", %{there: there} do
      assert there.name in browsed()
    end
  end

  describe "a file a page already points at" do
    # THE PAGE MUST KEEP WORKING. These are the reads that resolve a reference, not the ones that
    # offer a choice, so they are deliberately untouched.
    test "still resolves while its site is off", %{there: there} do
      assert {:ok, found} =
               Media
               |> Ash.Query.for_read(:get_any, %{}, authorize?: false)
               |> Ash.Query.filter(id == ^there.id)
               |> Ash.read_one()

      assert found.id == there.id
    end

    test "and is still there to read internally", %{there: there} do
      names =
        Media
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.read!(page: [limit: 100])
        |> Map.fetch!(:results)
        |> Enum.map(& &1.name)

      assert there.name in names
    end
  end
end
