# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.SeedsTest do
  @moduledoc """
  Every installer choice is a part a plugin declares on `installer:seed`. Registering the plugin is
  what puts its parts in the installer: required ones locked and always run, default ones ticked at
  the start, each shown only by the installers its `envs` name, and never a dev part in production.
  The core's own plugin comes first, its parts run once and build the sites and users every other
  part is then run on, once per site.

  The runs exercised end to end here are stress runs at one or two sites: they reach the event
  through the same path as a dev run without installing every UI kit first.
  """
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Dev.Seeds, as: DevSeeds
  alias MishkaCmsCore.Install.{Seeds, StarterContent}
  alias MishkaCmsCore.Test.Installer
  alias MishkaCmsCore.Test.Plugins.{SeedProbe, SeedSecond}

  @tiny [
    sites: 2,
    layouts_per_site: 1,
    error_pages_per_site: 1,
    hooks_per_site: 1,
    media_categories_per_site: 1,
    media_per_site: 1,
    master_users: 1,
    tenant_users: 1
  ]

  @probe_parts [
    %{
      id: "pages",
      label: "Probe pages",
      summary: "Probe pages",
      envs: [:dev, :prod],
      default: true
    },
    %{
      id: "samples",
      label: "Probe samples",
      summary: "Probe records",
      envs: [:dev],
      nav: [%{label: "Probe", path: "/probe"}, %{label: "Store", to: "/store"}]
    },
    %{id: "locked", label: "Probe locked", envs: [:dev, :prod], required: true},
    %{label: "Not a part, it has no id", envs: [:dev, :prod]}
  ]

  defp register_probe!(attrs \\ %{}) do
    Installer.register!(
      SeedProbe,
      Seeds.event(),
      Map.merge(%{extension: :mishka_seed_probe, priority: 50, extra: @probe_parts}, attrs)
    )
  end

  defp probe(env), do: Enum.find(Seeds.plugins(env), &(&1.key == "mishka_seed_probe"))

  defp part_ids(plugin), do: Enum.map(plugin.parts, & &1.id)

  defp production_build! do
    for key <- [:env_dev?, :env_test?] do
      previous = Application.get_env(:mishka_cms_core, key)
      Application.put_env(:mishka_cms_core, key, false)
      on_exit(fn -> restore_env(key, previous) end)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mishka_cms_core, key)
  defp restore_env(key, value), do: Application.put_env(:mishka_cms_core, key, value)

  describe "plugins/1" do
    test "lists the core's own parts, its dev parts in dev and its production parts in production" do
      assert [%{key: "mishka_cms_core", label: "Mishka CMS"} = dev] = Seeds.plugins(:dev)
      assert [%{key: "mishka_cms_core"} = prod] = Seeds.plugins(:prod)

      assert part_ids(dev) ==
               ~w(permissions master_user site languages components starter_content auth_pages samples)

      assert part_ids(prod) ==
               ~w(permissions master_user site languages settings components starter_content auth_pages)

      assert %{required: false, default: true} = Enum.find(prod.parts, &(&1.id == "components"))

      assert prod.parts |> Enum.reject(&(&1.id == "components")) |> Enum.all?(& &1.required),
             "every core part but the components is not a choice"
    end

    test "reads a plugin's parts with their flags, in the order it declares them" do
      register_probe!()

      assert %{label: label, parts: [pages, samples, locked]} = probe(:dev)
      assert label == "Seed Probe"

      assert %{label: "Probe pages", envs: [:dev, :prod], required: false, default: true} = pages
      assert %{summary: "Probe records", envs: [:dev], required: false, default: false} = samples
      assert %{required: true, default: true, summary: ""} = locked
    end

    test "shows a part only in the installers its envs name" do
      register_probe!()

      assert part_ids(probe(:dev)) == ["pages", "samples", "locked"]
      assert part_ids(probe(:prod)) == ["pages", "locked"]
    end

    test "takes a part with no envs as a dev part, and leaves out a plugin with no part to show" do
      register_probe!(%{extra: [%{id: "only", label: "Only"}]})

      assert part_ids(probe(:dev)) == ["only"]
      assert probe(:prod) == nil
    end

    test "lists the core first, then the plugins by priority" do
      register_probe!(%{priority: 20})

      Installer.register!(SeedSecond, Seeds.event(), %{
        extension: :mishka_seed_second,
        priority: 10,
        extra: [%{id: "x", label: "X"}]
      })

      assert Enum.map(Seeds.plugins(:dev), & &1.key) ==
               ["mishka_cms_core", "mishka_seed_second", "mishka_seed_probe"]
    end

    test "leaves out a plugin an operator switched off" do
      register_probe!(%{status: :stopped})

      assert probe(:dev) == nil
    end

    test "never shows a dev-only part in a production build" do
      register_probe!()
      production_build!()

      assert part_ids(probe(:dev)) == ["pages", "locked"]
      refute "samples" in (Seeds.plugins(:dev) |> hd() |> part_ids())
    end
  end

  describe "steps/2" do
    test "runs the required and default parts when nothing was chosen" do
      register_probe!()

      assert {{"mishka_seed_probe", "pages"}, "Probe pages"} in Seeds.steps(:dev)
      assert {{"mishka_seed_probe", "locked"}, "Probe locked"} in Seeds.steps(:dev)
      refute Enum.any?(Seeds.steps(:dev), &match?({{"mishka_seed_probe", "samples"}, _}, &1))
    end

    test "runs the required parts and the chosen ones, plugin by plugin in declared order" do
      register_probe!()

      rows =
        Seeds.steps(:dev, %{"mishka_seed_probe" => ["samples"]}) |> Enum.map(&elem(&1, 0))

      assert Enum.take(rows, 1) == [{"mishka_cms_core", "permissions"}]

      assert Enum.drop_while(rows, &(elem(&1, 0) == "mishka_cms_core")) ==
               [{"mishka_seed_probe", "samples"}, {"mishka_seed_probe", "locked"}]
    end

    test "never runs a part the installer does not show, whatever was chosen" do
      register_probe!()

      rows = :prod |> Seeds.steps(%{"mishka_seed_probe" => ["samples", "pages"]})

      assert {{"mishka_seed_probe", "pages"}, "Probe pages"} in rows
      refute Enum.any?(rows, &match?({{_key, "samples"}, _label}, &1))
    end
  end

  describe "nav" do
    test "names every dev part's links in every dev site's header, a to: link as written" do
      register_probe!()

      assert Seeds.nav() == [%{label: "Probe", path: "/probe"}, %{label: "Store", to: "/store"}]

      assert [%{label: "Dev", children: children}] = DevSeeds.nav("localhost")
      assert Enum.take(children, -2) == Seeds.nav()

      html = StarterContent.nav_links(DevSeeds.nav("localhost"))
      assert html =~ ~s|navigate="/store"|
      refute html =~ ~s|/:lang/store|
      assert html =~ ~s|/:lang/probe|
    end
  end

  describe "run/3" do
    test "runs the core's parts once, then each chosen part of a plugin on every site" do
      register_probe!()
      test = self()

      assert {:ok, core} =
               Seeds.run(
                 :dev,
                 %{"mishka_seed_probe" => ["samples", "pages"]},
                 [size: :stress, progress: &send(test, {:progress, &1})] ++ @tiny
               )

      assert length(core.sites) == 2, "the core's parts were not given the run's opts"
      assert [master] = core.users.master

      for part <- ["pages", "samples", "locked"], site <- core.sites do
        assert_received {:seed, %{part: ^part, site_id: site_id} = payload}
                        when site_id == site.id

        assert payload.key == "mishka_seed_probe"
        assert payload.parts == ["pages", "samples", "locked"]
        assert payload.env == :dev
        assert payload.size == :stress
        assert payload.foundation.sites == core.sites

        assert Enum.map(payload.users, & &1.id) ==
                 [master.id | Enum.map(Map.fetch!(core.users.tenant, site.id), & &1.id)]
      end

      refute_received {:seed, _payload}

      probe_rows =
        for {{"mishka_seed_probe", part}, status} <- phases(), do: {part, status}

      assert probe_rows == [
               {"pages", :running},
               {"pages", :done},
               {"samples", :running},
               {"samples", :done},
               {"locked", :running},
               {"locked", :done}
             ]
    end

    test "stops at a required part that failed, and says which on its row" do
      register_probe!(%{
        extension: :mishka_seed_raises,
        extra: [%{id: "locked", label: "Raises", required: true}]
      })

      test = self()

      log =
        capture_log(fn ->
          assert {:error, :plugin_raised} =
                   Seeds.run(
                     :dev,
                     nil,
                     [size: :stress, progress: &send(test, {:progress, &1})] ++
                       Keyword.put(@tiny, :sites, 1)
                   )
        end)

      assert log =~ "the probe's part failed"
      assert_received {:progress, {{"mishka_seed_raises", "locked"}, :error, detail}}
      assert detail =~ "raised"
    end

    test "goes on past an optional part that failed, its row marked failed" do
      register_probe!(%{
        extra: [
          %{id: "refused", label: "Refused", default: true},
          %{id: "after", label: "After", default: true}
        ]
      })

      test = self()

      capture_log(fn ->
        assert {:ok, _core} =
                 Seeds.run(
                   :dev,
                   nil,
                   [size: :stress, progress: &send(test, {:progress, &1})] ++
                     Keyword.put(@tiny, :sites, 1)
                 )
      end)

      assert_received {:progress, {{"mishka_seed_probe", "refused"}, :error, ":refused"}}
      assert_received {:progress, {{"mishka_seed_probe", "after"}, :done, nil}}
    end

    test "fails a part nothing answered to" do
      Installer.register!(SeedSecond, Seeds.event(), %{
        extension: :mishka_seed_second,
        extra: [%{id: "silent", label: "Silent", required: true}]
      })

      capture_log(fn ->
        assert {:error, :no_plugin_answered} =
                 Seeds.run(:dev, nil, [size: :stress] ++ Keyword.put(@tiny, :sites, 1))
      end)
    end

    test "refuses a dev run in a production build, and runs nothing" do
      register_probe!()
      production_build!()

      assert {:error, :dev_in_production} =
               Seeds.run(:dev, %{"mishka_seed_probe" => ["samples"]}, size: :stress)

      refute_received {:seed, _payload}
    end
  end

  # The rows a run reported, in the order it reported them. The run is over and every message it
  # sent is already in this process's mailbox, so nothing is waited for.
  defp phases do
    receive do
      {:progress, {row, status, _detail}} when status in [:running, :done] ->
        [{row, status} | phases()]

      {:progress, _log} ->
        phases()
    after
      0 -> []
    end
  end
end
