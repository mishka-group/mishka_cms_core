# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Marketplace.KitsTest do
  @moduledoc """
  The Studio's Registry tab over the registry an install actually has: the UI-kit bundles on disk.

  The tab used to list a sample catalogue whose Install button refused every click. What a CMS can
  really offer is the rest of the kit — a site is set up with a subset, and the other hundred
  components are exactly "available to install". Installing one has to bring what it depends on,
  because a card that cannot draw its icon is not installed.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits

  require Ash.Query

  setup do
    %{site: create_site!()}
  end

  describe "packages/1" do
    test "offers the kit's components", %{site: site} do
      packages = Kits.packages(%{site_id: site.id})

      assert length(packages) > 0
      assert Enum.all?(packages, &String.starts_with?(&1.id, "chelekom-"))
    end

    # The whole difference between this and a catalogue of things to fetch: it knows what is already
    # here.
    test "a component this site already has is not offered again", %{site: site} do
      [first | _rest] = Kits.packages(%{site_id: site.id})

      create_component!(site_id: site.id, name: first.id)

      refute first.id in Enum.map(Kits.packages(%{site_id: site.id}), & &1.id)
    end

    test "a package says which kit it came from and what it will bring with it", %{site: site} do
      card = Enum.find(Kits.packages(%{site_id: site.id}), &(&1.id == "chelekom-card"))

      assert card.name == "card"
      assert card.author == "Chelekom"
      assert card.deps > 0
      assert card.description =~ "Chelekom"
      assert card.description =~ "depends on"
    end

    test "the category filter narrows to one group", %{site: site} do
      forms = Kits.packages(%{site_id: site.id, category: "forms"})

      assert forms != []
      assert Enum.all?(forms, &(&1.category == "forms"))
    end

    # A preset carries a whole layout and a token set, and no bundle on disk supplies one. Saying
    # nothing beats inventing cards whose Apply button refuses.
    test "presets and snippets are not something a kit bundle offers" do
      assert Kits.presets(%{}) == []
      assert Kits.snippets(%{}) == []
    end
  end

  describe "install/3" do
    test "installs the component and everything it depends on", %{site: site} do
      assert {:ok, %{installed: installed}} =
               Kits.install(:package, "chelekom-card", site.id, nil)

      assert "chelekom-card" in installed
      # `card` renders an icon, so installing it without `icon` would install something broken.
      assert "chelekom-icon" in installed

      names = installed_names(site)
      assert "chelekom-card" in names
      assert "chelekom-icon" in names
    end

    test "a name no kit ships is refused, not silently ignored", %{site: site} do
      assert {:error, {:not_available, message}} =
               Kits.install(:package, "chelekom-nonesuch", site.id, nil)

      assert message =~ "not in any kit"
    end

    test "a preset is not something this adapter can install", %{site: site} do
      assert {:error, {:not_available, message}} =
               Kits.install(:preset, "editorial", site.id, nil)

      assert message =~ "not something a kit bundle can install"
    end
  end

  # THE STUDIO ASKS ON EVERY OPEN, TAB AND CATEGORY, so it must never reach the network. It used to
  # download each kit again on each look in production. It offers the rest of the kits the install
  # fetched, read from disk, and never looks up or downloads a newer one.
  describe "the catalogue in production" do
    setup do
      dir = Path.join(System.tmp_dir!(), "studio_kits_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      test = self()
      keys = [:ui_kits_dir, :official_ui_kits, :prefer_local_ui_kits, :ui_kit_req_options]
      before = for key <- keys, do: {key, Application.fetch_env(:mishka_cms_core, key)}

      on_exit(fn ->
        for {key, value} <- before, do: restore_env(key, value)
        Kits.forget_catalog()
        File.rm_rf(dir)
      end)

      Application.put_env(:mishka_cms_core, :ui_kits_dir, dir)
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, false)
      Application.delete_env(:mishka_cms_core, :official_ui_kits)

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn ->
          send(test, {:network, conn.host})
          Req.Test.json(conn, acme_bundle())
        end
      )

      Kits.forget_catalog()
      %{dir: dir}
    end

    test "looks after looks, and after a restart, reach no network", %{site: site, dir: dir} do
      File.write!(Path.join(dir, "acme.json"), Jason.encode!(acme_bundle()))

      for _look <- 1..3 do
        Kits.packages(%{site_id: site.id})
        Kits.package_categories(%{site_id: site.id})
      end

      Kits.forget_catalog()
      Kits.packages(%{site_id: site.id})

      refute_received {:network, _host}
    end

    test "with no kit on disk it offers nothing rather than fetching one", %{site: site} do
      assert Kits.packages(%{site_id: site.id}) == []
      refute_received {:network, _host}
    end
  end

  defp acme_bundle,
    do: %{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => "acme",
      "version" => "1.0.0",
      "components" => []
    }

  defp restore_env(key, {:ok, value}), do: Application.put_env(:mishka_cms_core, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:mishka_cms_core, key)

  defp installed_names(site) do
    site_id = site.id

    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(page: [limit: 500])
    |> Map.fetch!(:results)
    |> Enum.map(& &1.name)
  end
end
