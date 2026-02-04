defmodule MishkaCmsCore.Runtime.Compilers.ClosureRootsTest do
  @moduledoc """
  Which templates a site's stylesheet is built FROM — the roots the walk starts at.

  A page and an error page are roots because a visitor reaches either by URL. A layout is not: it is
  chosen by `pages.layout_id`, so nothing in the template tree says which of a site's thirty layouts
  its five pages use, and treating them all as roots meant scanning twenty-five that can never
  render. Global layouts were worse — every one of them was a root of EVERY site's walk, so being
  global meant being in everybody's stylesheet rather than being available to everybody.

  See `MishkaCmsCore.Runtime.Compilers.CssClosure` for the walk these roots seed.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.States.SiteState

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "roots-site-#{n}", host: "roots-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    runtime = Path.join(System.tmp_dir!(), "closure_roots_#{n}")

    on_exit(fn ->
      SiteState.delete(site.id)
      File.rm_rf(runtime)
    end)

    %{site: site, runtime: runtime}
  end

  # The compiler resolves a layout to `<scope>/layout/<slug>.template`, the same path
  # `BootHandler.create_template_file/4` writes to, so a root it names must exist on disk.
  defp write_template(runtime, scope, kind, name) do
    dir = Path.join([runtime, scope, kind])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{Slug.slugify(name)}.template")
    File.write!(path, "<div>#{name}</div>")
    path
  end

  defp roots(site, runtime, opts \\ []) do
    TailwindCompiler.closure_roots(site.name, Keyword.put(opts, :runtime_dir, runtime))
  end

  describe "entry points" do
    test "a site's pages and error pages are roots", %{site: site, runtime: runtime} do
      page = write_template(runtime, site.name, "page", "home")
      error = write_template(runtime, site.name, "error", "not-found")

      found = roots(site, runtime)

      assert page in found
      assert error in found
    end

    test "another site's pages are not", %{site: site, runtime: runtime} do
      write_template(runtime, site.name, "page", "home")
      other = write_template(runtime, "someone-else", "page", "home")

      refute other in roots(site, runtime)
    end

    # A draft preview writes its unsaved template into a throwaway scope, and that draft is usually
    # the only thing referencing the component being previewed.
    test "an extra scope's pages join the roots", %{site: site, runtime: runtime} do
      draft = write_template(runtime, "preview_abc", "page", "draft")

      refute draft in roots(site, runtime)
      assert draft in roots(site, runtime, extra_scopes: ["preview_abc"])
    end
  end

  describe "layouts, which only the database can resolve" do
    test "a layout a page uses is a root; one no page uses is not", %{
      site: site,
      runtime: runtime
    } do
      used = create_layout!(site_id: site.id, name: "roots-used-#{unique()}")
      unused = create_layout!(site_id: site.id, name: "roots-unused-#{unique()}")
      create_page!(site_id: site.id, layout_id: used.id)

      used_path = write_template(runtime, site.name, "layout", used.name)
      unused_path = write_template(runtime, site.name, "layout", unused.name)

      found = roots(site, runtime)

      assert used_path in found
      refute unused_path in found
    end

    # BEING GLOBAL IS NOT BEING USED. A global layout used to be a root of every site's walk, so its
    # components' CSS shipped to sites that had never picked it.
    test "a global layout is a root only for the sites whose pages pick it", %{
      site: site,
      runtime: runtime
    } do
      picked = create_layout!(name: "roots-global-picked-#{unique()}")
      ignored = create_layout!(name: "roots-global-ignored-#{unique()}")
      create_page!(site_id: site.id, layout_id: picked.id)

      picked_path = write_template(runtime, "__global__", "layout", picked.name)
      ignored_path = write_template(runtime, "__global__", "layout", ignored.name)

      found = roots(site, runtime)

      assert picked_path in found
      refute ignored_path in found
    end

    test "an inactive page's layout stops being a root", %{site: site, runtime: runtime} do
      layout = create_layout!(site_id: site.id, name: "roots-inactive-#{unique()}")
      create_page!(site_id: site.id, layout_id: layout.id, active: false)

      path = write_template(runtime, site.name, "layout", layout.name)

      refute path in roots(site, runtime)
    end

    test "a page with no layout contributes none", %{site: site, runtime: runtime} do
      create_page!(site_id: site.id, layout_id: nil)
      write_template(runtime, site.name, "page", "home")

      assert Enum.all?(roots(site, runtime), &(!String.contains?(&1, "/layout/")))
    end

    # A layout row whose template file was never written points at nothing, and a missing `@source`
    # would abort the whole Tailwind run rather than lose one file.
    test "a layout with no template file on disk is dropped", %{site: site, runtime: runtime} do
      layout = create_layout!(site_id: site.id, name: "roots-nofile-#{unique()}")
      create_page!(site_id: site.id, layout_id: layout.id)

      assert Enum.all?(roots(site, runtime), &(!String.contains?(&1, "/layout/")))
    end
  end

  describe "when the site cannot be resolved" do
    # Correct-and-large, never small-and-broken — the same rule `:unbounded` follows. A site absent
    # from `SiteState` has no id to query pages by, and a stylesheet missing a layout's classes is a
    # page that renders unstyled in production.
    test "an unknown site falls back to every layout rather than none", %{runtime: runtime} do
      mine = write_template(runtime, "roots-ghost-site", "layout", "main")
      global = write_template(runtime, "__global__", "layout", "shared")

      found = TailwindCompiler.closure_roots("roots-ghost-site", runtime_dir: runtime)

      assert mine in found
      assert global in found
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
