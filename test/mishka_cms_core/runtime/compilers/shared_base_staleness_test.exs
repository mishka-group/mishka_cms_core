# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.SharedBaseStalenessTest do
  @moduledoc """
  An administrator edits the header layout their sites share, adds a class, and expects to see it.

  Two facts have to hold together for that to work, and neither is obvious from reading either one
  alone:

    * saving a Layout enqueues a per-site CSS job and does NOT drop the cached shared base —
      `RuntimeCompilerWorker`'s Layout clause has no `delete_shared_base_css/0`;
    * every site's compile PREPENDS that cached base rather than rebuilding it.

  So anything sourced into the shared base is frozen at the moment the base was last built. Global
  layouts used to be sourced there, which meant a class added to one was invisible to every site
  until something unrelated happened to drop the cache — the admin saved, saw nothing, and had no
  way to tell why. They are reached per site now, from that site's own pages.

  This pins the property from the admin's side rather than the implementation's: put a class in a
  global layout, rebuild only what a save rebuilds, and it must be there. Moving global layouts back
  into the shared base without also dropping it on save fails this test.
  """
  use MishkaCmsCore.DataCase, async: false
  @moduletag :integration

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}

  # Arbitrary-value utilities, so nothing else in the tree can supply the rule by coincidence.
  @layout_class "pt-[37px]"
  @page_class "gap-[29px]"

  setup do
    TailwindCompiler.ensure_installed()

    n = System.unique_integer([:positive])
    site = create_site!(name: "sb-#{n}", host: "sb-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    layout = create_layout!(name: "sb-shared-header-#{n}")
    page = create_page!(site_id: site.id, layout_id: layout.id)

    on_exit(fn ->
      SiteState.delete(site.id)
      BootHandler.delete_template_file(nil, "layout", layout.name)
      BootHandler.delete_template_file(site.name, "page", page.name)
      AssetsState.delete(site.name, "css")
    end)

    %{site: site, layout: layout, page: page}
  end

  describe "a class added to a GLOBAL layout a site's page uses" do
    test "reaches that site's stylesheet even though the shared base was never dropped", %{
      site: site,
      layout: layout,
      page: page
    } do
      # The base is built and cached BEFORE the layout carries the class — this is the stale cache
      # a Layout save leaves in place.
      {:ok, _base} = TailwindCompiler.compile_and_store_shared_base()
      assert AssetsState.exists?("__shared_base__", "css")

      BootHandler.create_template_file(
        nil,
        "layout",
        layout.name,
        ~s(<header class="#{@layout_class}">{@inner_content}</header>)
      )

      BootHandler.create_template_file(
        site.name,
        "page",
        page.name,
        ~s(<main class="#{@page_class}">hello</main>)
      )

      # Exactly what the Oban asset job runs — the base is reused, not rebuilt.
      {:ok, css} = TailwindCompiler.compile(site.name)

      assert AssetsState.exists?("__shared_base__", "css"),
             "the Layout clause does not drop the base; this test is worthless if something else did"

      assert css =~ "pt-\\[37px\\]",
             "a class an admin put in a shared global layout never reached the site that uses it"

      assert css =~ "gap-\\[29px\\]", "the site's own page classes are missing too"
    end

    test "and a global layout NO page uses stays out of it", %{site: site, page: page} do
      n = System.unique_integer([:positive])
      orphan = create_layout!(name: "sb-orphan-#{n}")
      on_exit(fn -> BootHandler.delete_template_file(nil, "layout", orphan.name) end)

      BootHandler.create_template_file(
        nil,
        "layout",
        orphan.name,
        ~s(<aside class="pl-[41px]">nobody points a page here</aside>)
      )

      BootHandler.create_template_file(site.name, "page", page.name, ~s(<main>hello</main>))

      {:ok, css} = TailwindCompiler.compile(site.name)

      refute css =~ "pl-\\[41px\\]",
             "a layout this site cannot render still charged its visitors for the CSS"
    end
  end

  # A document no site owns is drawn with the shared base alone, so its open builder frame listens
  # for the base's own rebuild, announced the way a site's bundle is.
  describe "a rebuilt shared base" do
    test "is announced on its own topic, once per change" do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "site:__shared_base__:assets")
      TailwindCompiler.delete_shared_base_css()

      {:ok, _base} = TailwindCompiler.compile_and_store_shared_base()
      hash = AssetsState.hash("__shared_base__", "css")
      assert_received {:css_updated, ^hash}

      {:ok, _base} = TailwindCompiler.compile_and_store_shared_base()
      refute_received {:css_updated, _same}, "an unchanged base was announced again"
    end
  end
end
