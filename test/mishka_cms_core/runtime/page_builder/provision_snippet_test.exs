# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.ProvisionSnippetTest do
  @moduledoc """
  The editor's answer to `runtime:provision:snippets`: an extension's Set up saves its snippet into
  the Studio's list, once, for whoever runs it — and a refused write comes back as the reason, so
  the run can say so, rather than as a raise the event would swallow.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaCmsCore.Runtime.PageBuilder.Plugins.ProvisionSnippet
  alias MishkaCmsCore.Runtime.Snippet

  require Ash.Query

  @moduletag :capture_log

  @bundle %{"name" => "kit", "version" => "1.0.0", "components" => []}

  setup do
    dir = Path.join(System.tmp_dir!(), "provision-snippet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "bundle.json")
    File.write!(path, Jason.encode!(@bundle))

    {:ok, bundle_path: path, site: create_site!()}
  end

  defp manifest(bundle_path, source \\ ~s(<div id="kit"></div>)) do
    %{
      app: :provision_test,
      bundle_path: bundle_path,
      section: "provision",
      pages: fn _site -> [] end,
      snippet: %{name: "Kit", source: fn _site -> source end}
    }
  end

  defp saved(site_id) do
    Snippet
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and name == "Kit")
    |> Ash.read!(page: [limit: 10])
    |> Map.fetch!(:results)
  end

  defp payload(site, source) do
    %{
      app: :provision_test,
      snippet: %{name: "Kit", source: source},
      site_id: site.id,
      site_name: site.name,
      actor: nil,
      installed: [],
      error: nil
    }
  end

  describe "a site's Set up" do
    test "saves the snippet for a site admin holding only the names it asks for",
         %{bundle_path: bundle_path, site: site} do
      manifest = manifest(bundle_path)

      admin =
        create_user_with_permissions!(ExtensionProvision.required(manifest), site_id: site.id)

      assert %{snippets: ["Kit"]} =
               ExtensionProvision.ensure!(manifest, site.id, %{}, actor: admin)

      assert [%{section: :page, scope: :shared}] = saved(site.id)
    end

    test "leaves a snippet the site already has alone, and reports none",
         %{bundle_path: bundle_path, site: site} do
      assert %{snippets: ["Kit"]} = ExtensionProvision.ensure!(manifest(bundle_path), site.id)

      assert %{snippets: []} =
               ExtensionProvision.ensure!(manifest(bundle_path, "<p>changed</p>"), site.id)

      assert [%{source: ~s(<div id="kit"></div>)}] = saved(site.id)
    end

    test "a refused write raises the run with its reason", %{bundle_path: bundle_path, site: site} do
      assert_raise RuntimeError, ~r/the snippet Kit could not be saved/, fn ->
        ExtensionProvision.ensure!(manifest(bundle_path, ""), site.id)
      end

      assert saved(site.id) == []
    end
  end

  describe "call/1" do
    test "answers a refused write with the reason in error, and raises nothing", %{site: site} do
      assert {:reply, %{error: %Ash.Error.Invalid{}, installed: []}} =
               ProvisionSnippet.call(payload(site, ""))
    end

    test "hands on a payload an earlier plugin already failed", %{site: site} do
      failed = %{payload(site, "<div></div>") | error: :earlier}

      assert {:reply, ^failed} = ProvisionSnippet.call(failed)
      assert saved(site.id) == []
    end
  end
end
