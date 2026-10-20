# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Runtime.PreviewFrameOriginTest do
  @moduledoc """
  Where the inspector's Preview tab points its iframe.

  It used to point at the record's own site host: `http://api.mishka.tools:4000/contact` for a page
  belonging to that site. Three separate things are wrong with that, and only the first is obvious.

    1. The admin's Content-Security-Policy says `frame-src 'self'`, so the browser refuses it and the
       tab shows an empty frame.
    2. **A site's domain is not necessarily this machine.** `api.mishka.tools` resolves to a public
       IP; the record being edited lives on the developer's own build. Relaxing the policy would not
       have fixed that — it would have replaced an empty frame with a stranger's server, which is
       worse, because it looks like an answer.
    3. A master administering site A cannot reach site B's domain from the admin at all in most
       deployments, so cross-site preview never worked.

  The fix is not a wider policy. `MishkaCmsWeb.DraftPreviewLive` resolves a record from its TOKEN and
  not from the Host header, so the very same preview answers on the admin's own origin — and now
  a Page has a token too, which it never did.

  The frame is a path with no host. Built on the endpoint's host, it named `localhost` in production,
  where a multi-site endpoint has no host configured. The shared link names the sharing admin's
  domain: the master site's for a master, their own site's for a site admin.

  See `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.frame_url/1` (framed) versus
  `preview_url/2` (shared), and `MishkaCmsCore.Runtime.DraftPreviewAssets.served_on?/2`.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaCmsCore.Runtime.{DraftPreviewAssets, ErrorPage, Layout, Page}
  alias MishkaCmsCore.Runtime.States.SiteState

  @endpoint_host Application.compile_env!(:mishka_cms_core, :endpoint)

  defp admin_host, do: apply(@endpoint_host, :struct_url, []).host

  defp record(struct_mod, overrides) do
    struct(
      struct_mod,
      Keyword.merge(
        [
          id: Ecto.UUID.generate(),
          name: "probe",
          path: "/probe",
          preview_token: "tok-#{System.unique_integer([:positive])}",
          active: true,
          site: %{id: Ecto.UUID.generate(), name: "elsewhere", host: "api.example.test"}
        ],
        overrides
      )
    )
  end

  describe "the URL the modal frames" do
    test "is a path on the admin's own origin, naming no host at all" do
      for mod <- [Page, Layout, ErrorPage] do
        url = PreviewHelpers.frame_url(record(mod, []))

        assert String.starts_with?(url, "/_preview/"),
               "#{inspect(mod)} is framed at a host of its own — CSP will refuse it"

        refute url =~ "://"
        refute url =~ admin_host(), "#{inspect(mod)} is framed at the endpoint's host"
      end
    end

    test "carries the token, which is what resolves the tenant" do
      page = record(Page, preview_token: "tok-page-1")

      assert PreviewHelpers.frame_url(page) =~ "/_preview/page/tok-page-1"
    end

    test "names the right resource segment for each kind" do
      assert PreviewHelpers.frame_url(record(Layout, [])) =~ "/_preview/layout/"
      assert PreviewHelpers.frame_url(record(ErrorPage, [])) =~ "/_preview/error_page/"
      assert PreviewHelpers.frame_url(record(Page, [])) =~ "/_preview/page/"
    end

    # A Component has no preview route — its tab renders a self-contained document instead — so the
    # absence has to be a clean `nil` rather than a URL that 404s.
    test "is nothing at all for a record with no token" do
      refute PreviewHelpers.frame_url(%{name: "no-token"})
    end
  end

  describe "the URL the modal SHARES" do
    setup do
      SiteState.clear()

      master = %{
        id: Ecto.UUID.generate(),
        name: "main",
        host: "master.example.test",
        master: true
      }

      tenant = %{id: Ecto.UUID.generate(), name: "shop", host: "shop.example.test", master: false}

      for site <- [master, tenant],
          do: SiteState.save(Map.merge(site, %{priority: 0, active: true}))

      on_exit(&SiteState.clear/0)
      %{master: master, tenant: tenant}
    end

    test "a master's link is on the master site's domain, whatever site the record is on" do
      master_user = %{site_id: nil}

      for record <- [record(Page, []), record(Layout, site: nil)] do
        url = PreviewHelpers.preview_url(record, master_user)

        assert url =~ "://master.example.test"
        refute url =~ "api.example.test"
      end
    end

    test "a site admin's link is on their own site's domain, a global record's too", %{
      tenant: tenant
    } do
      admin = %{site_id: tenant.id, site: %{host: tenant.host}}
      unloaded = %{site_id: tenant.id, site: %Ash.NotLoaded{}}

      for viewer <- [admin, unloaded],
          record <- [record(Page, site: tenant), record(ErrorPage, site: nil)] do
        assert PreviewHelpers.preview_url(record, viewer) =~
                 ~r{://shop\.example\.test(:\d+)?/_preview/}
      end
    end

    test "with no admin, a record's own site's domain, and the master site's for a global one" do
      assert PreviewHelpers.preview_url(record(Page, [])) =~
               ~r{://api\.example\.test(:\d+)?/_preview/page/}

      assert PreviewHelpers.preview_url(record(Layout, site: nil)) =~ "://master.example.test"
    end

    test "never the endpoint's host while a master site exists" do
      refute PreviewHelpers.preview_url(record(ErrorPage, site: nil)) =~ "://#{admin_host()}"
    end
  end

  # A PREVIEW OF SITE A IS NEVER SHOWN ON SITE B. Its own site's address and the master site's serve
  # it; a global record belongs to every site.
  describe "the addresses a preview is served on" do
    test "its own site's and the master site's, never another site's" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      master = %{id: Ecto.UUID.generate(), master: true}

      assert DraftPreviewAssets.served_on?(a, %{id: a, master: false})
      assert DraftPreviewAssets.served_on?(a, master)
      refute DraftPreviewAssets.served_on?(a, %{id: b, master: false})
    end

    test "a global record on any site's address, and nothing where no site answers" do
      assert DraftPreviewAssets.served_on?(nil, %{id: Ecto.UUID.generate(), master: false})
      refute DraftPreviewAssets.served_on?(nil, nil)
      refute DraftPreviewAssets.served_on?(Ecto.UUID.generate(), nil)
    end
  end

  # A STORED PATH IS A ROUTE. "Open page" used to join it to the host as it was, so a document page
  # opened `/:lang/docs/:workspace/:section` and answered 404.
  describe "the URL Open page opens" do
    test "a path with no capture is the page's address as it is" do
      url = PreviewHelpers.live_url(record(Page, path: "/contact", language: "en"), Page)

      assert url =~ "api.example.test"
      assert String.ends_with?(url, "/contact")
    end

    test "a path capturing only the language is opened in the page's own language, at the address the site's URL mode gives it" do
      site = create_site!(host: "open-#{System.unique_integer([:positive])}.test")
      forget_settings(~w(site.languages site.language_urls), [site.id])
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      opened =
        &PreviewHelpers.live_url(
          record(Page, path: "/:lang/blog", language: &1, site: site),
          Page
        )

      assert opened.("en") == MishkaCmsCore.Helpers.site_url(site.host, "/blog")
      assert opened.("fa") == MishkaCmsCore.Helpers.site_url(site.host, "/fa/blog")

      {:ok, _} = MishkaCmsCore.Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert opened.("en") == MishkaCmsCore.Helpers.site_url(site.host, "/en/blog")
    end

    # The template of many URLs and the address of none: no button, rather than a 404.
    test "a path capturing a record has no single page to open" do
      for path <- ["/:lang/docs/:workspace/:section", "/:lang/blog/:slug", "/files/*rest"] do
        refute PreviewHelpers.live_url(record(Page, path: path, language: "en"), Page), path
      end
    end

    test "an inactive page, or anything but a page, has none" do
      refute PreviewHelpers.live_url(record(Page, active: false, language: "en"), Page)
      refute PreviewHelpers.live_url(record(Layout, []), Layout)
    end

    test "the modal shows no Open page for a record-capturing page" do
      page = record(Page, path: "/:lang/docs/:workspace/:section", language: "en")

      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview:
            PreviewHelpers.empty()
            |> Map.merge(%{
              active_tab: "preview",
              resource: Page,
              record: page,
              live_url: PreviewHelpers.live_url(page, Page)
            })
        )

      refute html =~ "Open page"
      refute html =~ ":workspace/:section\""
    end
  end

  describe "the rendered Preview tab" do
    defp preview(overrides),
      do: PreviewHelpers.empty() |> Map.merge(%{active_tab: "preview"}) |> Map.merge(overrides)

    test "a Page is framed on the admin origin rather than at its live URL" do
      page = record(Page, name: "contact", path: "/contact")

      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview:
            preview(%{
              resource: Page,
              record: page,
              live_url: "http://api.example.test:4000/contact"
            })
        )

      assert html =~ "/_preview/page/#{page.preview_token}"

      refute html =~ ~s(src="http://api.example.test:4000/contact),
             "the frame still points at the site's domain"
    end

    # The live URL has not gone away — it is what "Open page" opens, in a new tab, where no frame
    # policy applies and the reader is deliberately leaving the admin.
    test "while Open page still links to the real published URL" do
      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview:
            preview(%{
              resource: Page,
              record: record(Page, []),
              live_url: "http://api.example.test:4000/contact"
            })
        )

      assert html =~ ~s(href="http://api.example.test:4000/contact")
      assert html =~ "Open page"
    end

    test "an ErrorPage keeps its selected status code on the framed URL" do
      err =
        record(ErrorPage,
          error_pages: [%{status: 404, template: "x"}, %{status: 500, template: "y"}]
        )

      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview: preview(%{resource: ErrorPage, record: err, preview_error_status: 500})
        )

      assert html =~ "/_preview/error_page/#{err.preview_token}?status=500"
    end

    test "the frame loads a path and the address bar names the reader's domain" do
      SiteState.clear()
      on_exit(&SiteState.clear/0)

      SiteState.save(%{
        id: Ecto.UUID.generate(),
        name: "main",
        host: "master.example.test",
        priority: 0,
        active: true,
        master: true
      })

      err = record(ErrorPage, site: nil, error_pages: [%{status: 404, template: "x"}])

      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview:
            preview(%{
              resource: ErrorPage,
              record: err,
              preview_error_status: 404,
              current_user: %{site_id: nil}
            })
        )

      assert html =~ ~s(src="/_preview/error_page/#{err.preview_token}?status=404")

      assert html =~
               ~r{://master\.example\.test(:\d+)?/_preview/error_page/#{err.preview_token}\?status=404}

      refute html =~ "://#{admin_host()}/_preview"
    end
  end
end
