# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Runtime.ErrorPreviewSourceTest do
  @moduledoc """
  ErrorPage/Layout previews run as a full LiveView at `/_preview/:resource/:token` for BOTH the live
  original and a draft (each carries a `preview_token`). The Error-code selector and the Original⇄Draft
  toggle just drive that iframe URL — they record the chosen status/source and bump the render nonce;
  they no longer render a static document.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaCmsCore.Runtime.{ErrorPage, Layout}
  import Phoenix.Component, only: [assign: 3]

  defp socket(preview_overrides) do
    preview =
      Map.merge(
        %{
          resource: ErrorPage,
          preview_source: "original",
          preview_error_status: 404,
          edit_html: "<p>stale unsaved edit</p>",
          render_nonce: 0
        },
        preview_overrides
      )

    assign(%Phoenix.LiveView.Socket{}, :preview, preview)
  end

  defp preview(socket), do: socket.assigns.preview

  describe "set_error_status/2" do
    test "records the status, clears any unsaved edit, and bumps the nonce (drives the iframe URL)" do
      p = socket(%{}) |> PreviewHelpers.set_error_status(500) |> preview()

      assert p.preview_error_status == 500
      assert p.edit_html == nil
      assert p.render_nonce == 1
      # it no longer renders a static document
      refute Map.has_key?(p, :html) and p[:html] not in [nil, ""]
    end
  end

  describe "set_preview_source/2" do
    test "switches the toggle between original and draft" do
      p =
        socket(%{preview_source: "original"})
        |> PreviewHelpers.set_preview_source("draft")
        |> preview()

      assert p.preview_source == "draft"

      p2 =
        socket(%{preview_source: "draft"})
        |> PreviewHelpers.set_preview_source("original")
        |> preview()

      assert p2.preview_source == "original"
    end

    test "ignores an unknown source" do
      p =
        socket(%{preview_source: "draft"})
        |> PreviewHelpers.set_preview_source("bogus")
        |> preview()

      assert p.preview_source == "draft"
    end
  end

  describe "preview_url/1 resolves the resource segment for live originals" do
    test "an ErrorPage original maps to /_preview/error_page/:token" do
      record = struct(ErrorPage, preview_token: "errtok123", site: %{host: "tenant.example.test"})

      url = PreviewHelpers.preview_url(record)

      assert url =~ "/_preview/error_page/errtok123"
      assert url =~ "tenant.example.test"
    end

    test "a Layout original maps to /_preview/layout/:token" do
      record = struct(Layout, preview_token: "laytok456", site: %{host: "tenant.example.test"})

      url = PreviewHelpers.preview_url(record)

      assert url =~ "/_preview/layout/laytok456"
    end
  end
end
