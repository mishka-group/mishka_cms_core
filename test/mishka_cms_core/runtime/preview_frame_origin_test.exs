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

  See `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.frame_url/1` (framed) versus
  `preview_url/1` (shared).
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaCmsCore.Runtime.{ErrorPage, Layout, Page}

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
    test "is on the admin's own origin, never the record's site host" do
      for mod <- [Page, Layout, ErrorPage] do
        url = PreviewHelpers.frame_url(record(mod, []))

        assert url =~ admin_host(),
               "#{inspect(mod)} is framed somewhere other than the admin — CSP will refuse it"

        refute url =~ "api.example.test",
               "#{inspect(mod)} is framed at its site's domain, which may be a different machine"
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
    # Different job, different answer: this is the link you send to a reviewer, opened rather than
    # embedded, so it names the site's own public domain.
    test "keeps the record's site host" do
      url = PreviewHelpers.preview_url(record(Page, []))

      assert url =~ "api.example.test"
      refute url =~ admin_host()
    end

    test "and falls back to the endpoint's host for a record with no site" do
      assert PreviewHelpers.preview_url(record(Layout, site: nil)) =~ admin_host()
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

    test "a path capturing only the language is opened in the page's own language" do
      url = PreviewHelpers.live_url(record(Page, path: "/:lang/blog", language: "en"), Page)

      assert String.ends_with?(url, "/en/blog")
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
  end
end
