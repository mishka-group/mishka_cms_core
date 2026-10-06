defmodule MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorkerTest do
  @moduledoc """
  Pure transition rules + site resolution for the runtime compiler worker, plus
  the routing-metadata behaviour that makes a deactivated page 404.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker, as: Worker
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}

  defp data(attrs) do
    Map.merge(%{"active" => true, "precompile" => false}, Map.new(attrs))
  end

  describe "purge?/2 — when to unload + de-route" do
    test "destroy always purges" do
      assert Worker.purge?("destroy", data(%{"active" => true}))
      assert Worker.purge?("destroy", data(%{"active" => false}))
    end

    test "deactivate (update -> inactive) purges" do
      assert Worker.purge?("update", data(%{"active" => false}))
    end

    test "active update does not purge" do
      refute Worker.purge?("update", data(%{"active" => true}))
    end

    test "create/unarchive never purge" do
      refute Worker.purge?("create", data(%{"active" => false}))
      refute Worker.purge?("unarchive", data(%{"active" => false}))
    end
  end

  describe "compile?/3 — when an active record should (re)compile" do
    test "create compiles only when precompiled" do
      assert Worker.compile?("create", data(%{"precompile" => true}), false)
      refute Worker.compile?("create", data(%{"precompile" => false}), false)
    end

    test "unarchive compiles only when precompiled" do
      assert Worker.compile?("unarchive", data(%{"precompile" => true}), false)
      refute Worker.compile?("unarchive", data(%{"precompile" => false}), false)
    end

    test "update recompiles a module that is already loaded (keep it fresh)" do
      assert Worker.compile?("update", data(%{"precompile" => false}), true)
    end

    test "update with precompile newly true compiles even if not loaded (force-precompile)" do
      assert Worker.compile?("update", data(%{"precompile" => true}), false)
    end

    test "update with precompile false and not loaded does nothing (no runtime change)" do
      refute Worker.compile?("update", data(%{"precompile" => false}), false)
    end

    test "destroy never compiles" do
      refute Worker.compile?("destroy", data(%{"precompile" => true}), true)
    end
  end

  describe "resolve_site/1" do
    test "global record (nil site_id) resolves to Global" do
      assert Worker.resolve_site(%{"site_id" => nil}) == {:ok, "Global", nil}
      assert Worker.resolve_site(%{}) == {:ok, "Global", nil}
    end

    test "tenant record resolves the name from SiteState by site_id" do
      n = System.unique_integer([:positive])
      site_id = "rcw-site-#{n}"
      site_name = "rcw-acme-#{n}"

      seed_site(site_id, site_name)

      assert Worker.resolve_site(%{"site_id" => site_id}) == {:ok, site_name, site_id}
    end

    test "tenant record whose site is not in SiteState is skipped (no DB fallback)" do
      n = System.unique_integer([:positive])

      assert Worker.resolve_site(%{"site_id" => "rcw-missing-#{n}"}) == :skip
    end
  end

  describe "apply_module_lifecycle/5 — deactivating de-routes a record" do
    test "purge (deactivate) unloads and removes the routing metadata so it 404s" do
      n = System.unique_integer([:positive])
      site_id = "rcw-de-#{n}"
      site_name = "rcw-de-acme-#{n}"
      page_id = "rcw-page-#{n}"
      path = "/rcw-#{n}"

      seed_site(site_id, site_name)

      WebRunTimeMetaDataState.save(%{
        id: page_id,
        site: site_name,
        path: path,
        title: "x",
        created_at: ~U[2026-05-29 00:00:00Z],
        section: "Page",
        priority: 0
      })

      assert WebRunTimeMetaDataState.exists?(page_id)

      inactive = %{
        "id" => page_id,
        "name" => "x",
        "path" => path,
        "active" => false,
        "precompile" => false,
        "site_id" => site_id
      }

      assert :ok =
               Worker.apply_module_lifecycle(
                 "update",
                 inactive,
                 RCW.NoSuch.Module,
                 "page",
                 "Page"
               )

      refute WebRunTimeMetaDataState.exists?(page_id)
    end

    test "an active record keeps its routing metadata" do
      n = System.unique_integer([:positive])
      site_id = "rcw-ac-#{n}"
      site_name = "rcw-ac-acme-#{n}"
      page_id = "rcw-ap-#{n}"
      path = "/rcw-ac-#{n}"

      seed_site(site_id, site_name)

      active = %{
        "id" => page_id,
        "name" => "x",
        "path" => path,
        "active" => true,
        "precompile" => false,
        "site_id" => site_id,
        "priority" => 0,
        "updated_at" => "2026-05-29T00:00:00Z"
      }

      # active + update + not loaded + not precompiled => no compile, just routing
      assert :ok =
               Worker.apply_module_lifecycle(
                 "update",
                 active,
                 RCW.NoSuch.Module,
                 "page",
                 "Page"
               )

      assert WebRunTimeMetaDataState.exists?(page_id)
    end
  end

  # A `/:lang/…` PAGE THAT SERVES EVERY LANGUAGE stores its routing row with no language, and the
  # router answers it under each one the site publishes. The boot pass always did; the worker that
  # runs after a save stored the page's own, so editing `/:lang/blog` took `/fa/blog` down until
  # the next restart.
  describe "the routing row's language after a save" do
    setup do
      n = System.unique_integer([:positive])
      site_id = "rcw-lang-#{n}"
      site_name = "rcw-lang-acme-#{n}"
      seed_site(site_id, site_name)

      # Each call its own id and path: the routing table keeps one row per path and site.
      page = fn extra ->
        m = System.unique_integer([:positive])

        %{
          "id" => "rcw-lang-page-#{m}",
          "name" => "x",
          "path" => "/:lang/rcw-lang-#{n}-#{m}",
          "active" => true,
          "precompile" => false,
          "site_id" => site_id,
          "priority" => 0,
          "language" => "en",
          "extra" => extra,
          "updated_at" => "2026-09-23T00:00:00Z"
        }
      end

      %{page: page, site_name: site_name}
    end

    for action <- ["create", "update"] do
      test "#{action}: a page that serves every language stores none", %{page: page} do
        data = page.(%{"serves_all_languages" => true})

        assert :ok =
                 Worker.apply_module_lifecycle(unquote(action), data, RCW.NoSuch, "page", "Page")

        assert {:ok, %{language: nil}} = WebRunTimeMetaDataState.get(data["id"])
      end

      test "#{action}: a page written in one language stores that one", %{page: page} do
        data = page.(%{})

        assert :ok =
                 Worker.apply_module_lifecycle(unquote(action), data, RCW.NoSuch, "page", "Page")

        assert {:ok, %{language: "en"}} = WebRunTimeMetaDataState.get(data["id"])
      end
    end

    # The worker's row and the boot pass's row for the same page, side by side.
    test "stores the language the boot pass stores", %{page: page, site_name: site_name} do
      for extra <- [%{"serves_all_languages" => true}, %{}] do
        data = page.(extra)
        :ok = Worker.apply_module_lifecycle("update", data, RCW.NoSuch, "page", "Page")
        {:ok, %{language: from_worker}} = WebRunTimeMetaDataState.get(data["id"])

        booted =
          BootHandler.web_metadata_row(
            %{
              id: data["id"],
              site: %{name: site_name},
              path: data["path"],
              name: data["name"],
              updated_at: data["updated_at"],
              priority: 0,
              language: "en",
              extra: extra
            },
            "Page"
          )

        assert from_worker == booted.language
      end
    end

    # `atomize_keys/1` converts every key that already exists as an atom, `extra`'s included. This
    # module names `:serves_all_languages`, so the atom exists here — the mark must be seen anyway.
    test "reads the mark whether or not its key exists as an atom", %{page: page} do
      assert is_atom(:serves_all_languages)
      data = page.(%{"serves_all_languages" => true})

      :ok = Worker.apply_module_lifecycle("update", data, RCW.NoSuch, "page", "Page")

      assert {:ok, %{language: nil}} = WebRunTimeMetaDataState.get(data["id"])
    end
  end

  describe "apply_component_lifecycle/3 — same precompile gate as a page, no routing" do
    test "purge (destroy) unloads and returns :ok" do
      com = %{
        "name" => "btn-#{System.unique_integer([:positive])}",
        "site_id" => nil,
        "active" => false
      }

      assert :ok = Worker.apply_component_lifecycle("destroy", com, RCW.NoSuch.Component)
    end

    test "deactivate (update -> inactive) purges and returns :ok" do
      com = %{
        "name" => "btn-#{System.unique_integer([:positive])}",
        "site_id" => nil,
        "active" => false
      }

      assert :ok = Worker.apply_component_lifecycle("update", com, RCW.NoSuch.Component)
    end

    test "a create that is inactive does nothing" do
      com = %{
        "name" => "btn-#{System.unique_integer([:positive])}",
        "site_id" => nil,
        "active" => false
      }

      assert :ok = Worker.apply_component_lifecycle("create", com, RCW.NoSuch.Component)
    end

    test "unarchive of an inactive component compiles nothing" do
      com = %{
        "name" => "btn-#{System.unique_integer([:positive])}",
        "site_id" => nil,
        "active" => false
      }

      refute :erlang.module_loaded(RCW.NoSuch.UnarchivedComponent)

      assert :ok =
               Worker.apply_component_lifecycle("unarchive", com, RCW.NoSuch.UnarchivedComponent)

      refute :erlang.module_loaded(RCW.NoSuch.UnarchivedComponent)
    end

    # A COMPONENT ADDED AT RUNTIME AND USED IN A PAGE. Nothing compiles it until something renders
    # it, but its classes have to reach the site's stylesheet regardless — so the template file is
    # written on the way past, not as a side effect of a successful compile.
    test "an active but lazy component writes its template even though nothing compiles" do
      name = "btn-#{System.unique_integer([:positive])}"

      com = %{
        "name" => name,
        "site_id" => nil,
        "active" => true,
        "precompile" => false,
        "template" => ~s(<i class="lazy-runtime-class"></i>)
      }

      on_exit(fn -> BootHandler.delete_template_file(nil, "component", name) end)

      assert :ok = Worker.apply_component_lifecycle("create", com, RCW.NoSuch.LazyComponent)

      refute :erlang.module_loaded(RCW.NoSuch.LazyComponent)
      assert File.read!(template_path(name, "component")) =~ "lazy-runtime-class"
    end

    # The worker reads its record out of an Oban job, where every key is a string; boot reads an Ash
    # struct. Both go through the same aggregate builder, and a helper's classes count either way.
    test "the written template aggregates body and helpers, as boot's does" do
      name = "btn-#{System.unique_integer([:positive])}"

      com = %{
        "name" => name,
        "site_id" => nil,
        "active" => true,
        "precompile" => false,
        "template" => ~s(<i class="tmpl-class"></i>),
        "body" => "assigns = Map.put(assigns, :tone, \"body-class\")",
        "helpers" => [%{"name" => "tone", "code" => "def tone, do: \"helper-class\""}]
      }

      on_exit(fn -> BootHandler.delete_template_file(nil, "component", name) end)

      assert :ok = Worker.apply_component_lifecycle("create", com, RCW.NoSuch.BlobComponent)

      contents = File.read!(template_path(name, "component"))

      assert contents =~ "tmpl-class"
      assert contents =~ "body-class"
      assert contents =~ "helper-class"
    end
  end

  describe "apply_module_lifecycle/5 — a lazy page's classes ship before its module exists" do
    test "an active, non-precompiled page writes its template without compiling" do
      n = System.unique_integer([:positive])
      site_id = "rcw-lz-#{n}"
      site_name = "rcw-lz-acme-#{n}"

      seed_site(site_id, site_name)

      page = %{
        "id" => "rcw-lzp-#{n}",
        "name" => "lazy-page-#{n}",
        "path" => "/rcw-lz-#{n}",
        "active" => true,
        "precompile" => false,
        "site_id" => site_id,
        "priority" => 0,
        "updated_at" => "2026-05-29T00:00:00Z",
        "template" => ~s(<main class="lazy-page-class"></main>)
      }

      on_exit(fn -> BootHandler.delete_template_file(site_name, "page", page["name"]) end)

      assert :ok =
               Worker.apply_module_lifecycle("create", page, RCW.NoSuch.LazyPage, "page", "Page")

      refute :erlang.module_loaded(RCW.NoSuch.LazyPage)
      assert File.read!(template_path(page["name"], "page", site_name)) =~ "lazy-page-class"
    end
  end

  defp template_path(name, type, site_name \\ "__global__") do
    ["runtime", site_name, type]
    |> MishkaCmsCore.Runtime.Helpers.static_temp_dir()
    |> Path.join("#{Slug.slugify(name)}.template")
  end

  describe "apply_module_lifecycle/5 — unarchiving an inactive record stays unrouted" do
    test "unarchive + inactive writes no routing metadata (404s until activated)" do
      n = System.unique_integer([:positive])
      site_id = "rcw-un-#{n}"
      page_id = "rcw-unp-#{n}"

      seed_site(site_id, "rcw-un-acme-#{n}")

      inactive = %{
        "id" => page_id,
        "name" => "x",
        "path" => "/rcw-un-#{n}",
        "active" => false,
        "precompile" => true,
        "site_id" => site_id
      }

      refute WebRunTimeMetaDataState.exists?(page_id)

      assert :ok =
               Worker.apply_module_lifecycle(
                 "unarchive",
                 inactive,
                 RCW.NoSuch.Module,
                 "page",
                 "Page"
               )

      refute WebRunTimeMetaDataState.exists?(page_id)
    end

    test "the same record but active DOES get routed (active is the gate)" do
      n = System.unique_integer([:positive])
      site_id = "rcw-ung-#{n}"
      page_id = "rcw-ungp-#{n}"

      seed_site(site_id, "rcw-ung-acme-#{n}")

      active = %{
        "id" => page_id,
        "name" => "x",
        "path" => "/rcw-ung-#{n}",
        "active" => true,
        "precompile" => false,
        "site_id" => site_id,
        "priority" => 0,
        "updated_at" => "2026-05-29T00:00:00Z"
      }

      assert :ok =
               Worker.apply_module_lifecycle(
                 "unarchive",
                 active,
                 RCW.NoSuch.Module,
                 "page",
                 "Page"
               )

      assert WebRunTimeMetaDataState.exists?(page_id)
    end
  end

  defp seed_site(site_id, site_name) do
    SiteState.save(%{
      id: site_id,
      name: site_name,
      host: "#{site_id}.test",
      priority: 0,
      active: true
    })
  end
end
