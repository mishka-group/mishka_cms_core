# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.SeedsEventTest do
  @moduledoc """
  Every dev seed is a plugin on `dev:seed`: registering it is what puts it in the installer's dev
  step. The core's own seed is one of them, required: listed first, always run, once, and its report
  is the sites and users every extension's seed is then fired with, once per site.

  The stress run is the one exercised end to end here, at one or two sites: it reaches the event
  through the same path as the dev run without installing every UI kit first.
  """
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Dev.Seeds
  alias MishkaCmsCore.Test.Installer
  alias MishkaCmsCore.Test.Plugins.{DevSeedProbe, DevSeedSecond}

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

  defp register_probe!(attrs \\ %{}) do
    Installer.register!(
      DevSeedProbe,
      Seeds.event(),
      Map.merge(
        %{
          extension: :mishka_seed_probe,
          priority: 50,
          extra: [
            %{
              label: "Seed probe",
              summary: "Probe records",
              nav: [%{label: "Probe", path: "/probe"}]
            }
          ]
        },
        attrs
      )
    )
  end

  describe "categories/0" do
    test "lists the core's own seed alone, required, when no extension registered one" do
      assert [%{key: "mishka_cms_core", label: "Mishka CMS", required: true}] = Seeds.categories()
    end

    test "lists a registered seed with its label, summary and links, after the core's" do
      register_probe!()

      assert [%{key: "mishka_cms_core"}, category] = Seeds.categories()
      refute category.required
      assert category.key == "mishka_seed_probe"
      assert category.label == "Seed probe"
      assert category.summary == "Probe records"
      assert category.nav == [{"Probe", "/probe"}]
    end

    test "orders the seeds by priority" do
      register_probe!()

      Installer.register!(DevSeedSecond, Seeds.event(), %{
        extension: :mishka_seed_second,
        priority: 10
      })

      assert Enum.map(Seeds.categories(), & &1.key) ==
               ["mishka_cms_core", "mishka_seed_second", "mishka_seed_probe"]
    end

    test "keeps the required seed first beside an extension at the same priority" do
      register_probe!(%{
        priority: 0,
        extra: [%{label: "A probe that sorts first", summary: "", required: false}]
      })

      assert Enum.map(Seeds.categories(), & &1.key) == ["mishka_cms_core", "mishka_seed_probe"]
    end

    test "leaves out a seed an operator switched off" do
      register_probe!()

      Installer.register!(DevSeedSecond, Seeds.event(), %{
        extension: :mishka_seed_second,
        status: :stopped
      })

      assert Enum.map(Seeds.categories(), & &1.key) == ["mishka_cms_core", "mishka_seed_probe"]
    end

    test "names the links of the registered seeds in every dev site's header" do
      register_probe!()

      assert [%{label: "Dev", children: children}] = Seeds.nav("localhost")
      assert List.last(children) == {"Probe", "/probe"}
    end
  end

  describe "steps/1" do
    test "adds a phase for each chosen seed, by key as a string or an atom" do
      register_probe!()

      assert [{"mishka_cms_core", "Mishka CMS"}, {"mishka_seed_probe", "Seed probe"}] =
               Seeds.steps([:mishka_seed_probe])

      assert [{"mishka_cms_core", _}, {"mishka_seed_probe", _}] =
               Seeds.steps(["mishka_seed_probe"])
    end

    test "keeps the required seed in a selection that left it out" do
      register_probe!()

      assert [{"mishka_cms_core", _}] = Seeds.steps([])
      assert [{"mishka_cms_core", _}] = Seeds.steps(["mishka_not_installed"])
    end
  end

  describe "run_all(:stress, opts)" do
    test "runs the core's seed once with the opts, then each extension's per site" do
      register_probe!()
      test = self()

      core = Seeds.run_all(:stress, [progress: &send(test, {:progress, &1})] ++ @tiny)

      assert length(core.sites) == 2, "the core's seed was not given the run's opts"
      assert [master] = core.users.master

      for site <- core.sites do
        assert_received {:dev_seed, %{site_id: site_id} = payload} when site_id == site.id
        assert payload.key == "mishka_seed_probe"
        assert payload.size == :stress

        assert Enum.map(payload.users, & &1.id) ==
                 [master.id | Enum.map(Map.fetch!(core.users.tenant, site.id), & &1.id)]

        assert_received {:progress, {"mishka_seed_probe", :log, line}}
        assert line =~ site.id
      end

      refute_received {:dev_seed, _}

      assert phases() == [
               {"mishka_cms_core", :running},
               {"mishka_cms_core", :done},
               {"mishka_seed_probe", :running},
               {"mishka_seed_probe", :done}
             ]
    end

    test "raises when the seed's plugin raised" do
      register_probe!(%{extension: :mishka_seed_raises})

      log =
        capture_log(fn ->
          assert_raise RuntimeError, ~r/mishka_seed_raises seed did not run.*raised/, fn ->
            Seeds.run_all(:stress, Keyword.put(@tiny, :sites, 1))
          end
        end)

      assert log =~ "the probe's seed failed"
    end

    test "raises when no plugin answered to the seed's key" do
      Installer.register!(DevSeedSecond, Seeds.event(), %{extension: :mishka_seed_second})

      assert_raise RuntimeError,
                   ~r/mishka_seed_second seed did not run.*no plugin answered/,
                   fn ->
                     Seeds.run_all(:stress, Keyword.put(@tiny, :sites, 1))
                   end
    end
  end

  # The phases a run reported, in the order it reported them. The run is over and every message it
  # sent is already in this process's mailbox, so nothing is waited for.
  defp phases do
    receive do
      {:progress, {key, status, _detail}} when status in [:running, :done] ->
        [{key, status} | phases()]

      {:progress, _log} ->
        phases()
    after
      0 -> []
    end
  end
end
