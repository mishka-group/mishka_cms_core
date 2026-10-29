# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ExtensionProvisionTest do
  @moduledoc """
  Who may run an extension's Set up, Doctor or Kit upgrade.

  A provision creates the extension's own permission names, writes components, sample pages and a
  snippet, and reads the site. The components, the
  pages and the site are a name each, and a required list is any-of — so
  `ExtensionProvision.required/1` lists one name per step and `allowed?/2` asks each. The snippet
  is an installed editor's, handed over on `runtime:provision:snippets` and saved under the pages'
  name. A run by someone missing one is refused before its first write, so a site is never left half
  set up.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{ExtensionProvision, PageProvision}
  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCore.Test.Plugins.ProvisionSnippetRefused
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "provision-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, site: create_site!()}
  end

  defp manifest(dir, bundle, extra \\ %{}) do
    path = Path.join(dir, "bundle-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(bundle))

    Map.merge(
      %{app: :provision_test, bundle_path: path, section: "provision", pages: fn _site -> [] end},
      extra
    )
  end

  @components %{"name" => "kit", "version" => "1.0.0", "components" => [%{"name" => "kit-card"}]}

  defp snippet, do: %{snippet: %{name: "Kit", source: fn _site -> ~s(<div id="kit"></div>) end}}

  describe "moved/2" do
    @every_language %{"serves_all_languages" => true}

    defp sample_pages do
      [
        %{path: "/:lang/blog", extra: @every_language},
        %{path: "/:lang", extra: @every_language},
        %{path: "/archive", extra: %{}}
      ]
    end

    # Only the first segment is ever a language, so a prefix goes after it.
    test "puts a prefix after a leading :lang, and in front of any other path" do
      moved = ExtensionProvision.moved(sample_pages(), %{"prefix" => " /mish/ "})

      assert Enum.map(moved, & &1.path) == ["/:lang/mish/blog", "/:lang/mish", "/mish/archive"]
    end

    test "a named path wins over the prefix" do
      moved =
        ExtensionProvision.moved(sample_pages(), %{
          "prefix" => "/mish",
          "paths" => %{"/:lang/blog" => "/:lang/journal"}
        })

      assert Enum.map(moved, & &1.path) == ["/:lang/journal", "/:lang/mish", "/mish/archive"]
      assert Enum.all?(Enum.take(moved, 2), &PageProvision.serves_all_languages?/1)
    end

    test "a page moved to a path with no lang answers its own language alone" do
      [journal | _rest] =
        ExtensionProvision.moved(sample_pages(), %{"paths" => %{"/:lang/blog" => "/journal"}})

      assert journal.path == "/journal"
      refute PageProvision.serves_all_languages?(journal)
    end
  end

  describe "required/1" do
    test "names components, pages and the site for a bundle of components", %{dir: dir} do
      assert ExtensionProvision.required(manifest(dir, @components)) == [
               "admin:dashboard:runtime:component",
               "admin:dashboard:runtime:page",
               "admin:dashboard:runtime:site"
             ]
    end

    test "adds hooks and stylesheets when the kit ships them", %{dir: dir} do
      bundle =
        Map.merge(@components, %{
          "js_hooks" => [%{"name" => "kit-hook"}],
          "stylesheets" => [%{"name" => "kit-theme"}]
        })

      assert ExtensionProvision.required(manifest(dir, bundle)) == [
               "admin:dashboard:runtime:component",
               "admin:dashboard:runtime:js_hook",
               "admin:dashboard:runtime:stylesheet",
               "admin:dashboard:runtime:page",
               "admin:dashboard:runtime:site"
             ]
    end

    test "adds no name for a snippet", %{dir: dir} do
      assert ExtensionProvision.required(manifest(dir, @components, snippet())) ==
               ExtensionProvision.required(manifest(dir, @components))
    end
  end

  describe "allowed?/2" do
    test "needs every name, each asked on its own", %{dir: dir, site: site} do
      manifest = manifest(dir, @components)
      all = ExtensionProvision.required(manifest)

      assert ExtensionProvision.allowed?(
               manifest,
               create_user_with_permissions!(all, site_id: site.id)
             )

      for name <- all do
        short = create_user_with_permissions!(all -- [name], site_id: site.id)

        refute ExtensionProvision.allowed?(manifest, short), "#{name} was not asked"
        assert ExtensionProvision.missing(manifest, short) == [name]
      end
    end

    test "a full dashboard admin holds them all; nobody holds none", %{dir: dir, site: site} do
      manifest = manifest(dir, @components)

      assert ExtensionProvision.allowed?(
               manifest,
               create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
             )

      refute ExtensionProvision.allowed?(manifest, nil)
      assert ExtensionProvision.missing(manifest, nil) == ExtensionProvision.required(manifest)
    end
  end

  describe "ensure!/4" do
    test "refuses an actor missing a name before it writes anything", %{dir: dir, site: site} do
      manifest = manifest(dir, @components)

      pages_only =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert_raise ArgumentError, ~r/admin:dashboard:runtime:component/, fn ->
        ExtensionProvision.ensure!(manifest, site.id, %{}, actor: pages_only)
      end

      assert MishkaCmsCore.Runtime.Component
             |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
             |> Ash.Query.filter(site_id == ^site.id)
             |> Ash.read!(page: [limit: 10])
             |> Map.fetch!(:results) == []
    end
  end

  # THE SNIPPET IS THE EDITOR'S. The run hands it to `runtime:provision:snippets` and reports what an
  # editor says it saved; the editor's own plugin is tested beside it.
  describe "ensure!/4 — the snippet" do
    @snippets_event "runtime:provision:snippets"

    test "reports none, and raises nothing, when no editor answers", %{dir: dir, site: site} do
      :ok = EventCannotRun.stub!(@snippets_event)
      manifest = manifest(dir, Map.put(@components, "components", []), snippet())

      admin =
        create_user_with_permissions!(ExtensionProvision.required(manifest), site_id: site.id)

      assert %{snippets: []} = ExtensionProvision.ensure!(manifest, site.id, %{}, actor: admin)
      assert %{snippets: []} = ExtensionProvision.ensure!(manifest, site.id)
    end

    test "raises with the reason an editor reports, as a refused write always did",
         %{dir: dir, site: site} do
      register!(ProvisionSnippetRefused, @snippets_event)
      manifest = manifest(dir, Map.put(@components, "components", []), snippet())

      assert_raise RuntimeError,
                   ~r/the snippet Kit could not be saved: :refused_by_the_probe/,
                   fn ->
                     ExtensionProvision.ensure!(manifest, site.id)
                   end
    end
  end

  defp register!(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  # AN EXTENSION'S NAMES ARRIVE WITH IT, as its components do: created by the first run on any site,
  # found by every later one, and never by the core install.
  describe "ensure!/4 — the extension's permission names" do
    @no_components Map.put(@components, "components", [])

    @names [
      {"admin:dashboard:probe:*", "The whole probe."},
      {"admin:dashboard:probe:item", "Probe items."}
    ]

    defp stored(names) do
      MishkaCmsCore.Accounts.Permission
      |> Ash.Query.filter(name in ^names)
      |> Ash.read!(authorize?: false, page: false)
      |> Map.new(&{&1.name, &1.description})
    end

    test "are created by the first run and reported, and a second run creates none",
         %{dir: dir, site: site} do
      manifest = manifest(dir, @no_components, %{permissions: @names})
      names = Enum.map(@names, &elem(&1, 0))

      assert stored(names) == %{}

      assert %{permissions: ^names} = ExtensionProvision.ensure!(manifest, site.id)
      assert stored(names) == Map.new(@names)

      assert %{permissions: []} = ExtensionProvision.ensure!(manifest, create_site!().id)
    end

    test "are created by the system for an admin who may set the site up", %{dir: dir, site: site} do
      manifest = manifest(dir, @no_components, %{permissions: @names})

      admin =
        create_user_with_permissions!(ExtensionProvision.required(manifest), site_id: site.id)

      assert %{permissions: [_, _]} =
               ExtensionProvision.ensure!(manifest, site.id, %{}, actor: admin)
    end

    test "keep a name stored before, with its own description", %{dir: dir, site: site} do
      create_permission!(name: "admin:dashboard:probe:item", description: "Written by hand.")
      manifest = manifest(dir, @no_components, %{permissions: @names})

      assert %{permissions: ["admin:dashboard:probe:*"]} =
               ExtensionProvision.ensure!(manifest, site.id)

      assert stored(["admin:dashboard:probe:item"]) == %{
               "admin:dashboard:probe:item" => "Written by hand."
             }
    end

    test "a manifest shipping none reports none", %{dir: dir, site: site} do
      assert %{permissions: []} =
               ExtensionProvision.ensure!(manifest(dir, @no_components), site.id)
    end
  end
end
