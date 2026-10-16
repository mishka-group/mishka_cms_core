# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Routes do
  @moduledoc """
  Extension routes for MishkaCmsCore (core admin dashboard, runtime, accounts).
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    [
      {:live, "/", MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index, :index},
      {:live, "/runtime/activity", MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index, :index},
      {:live, "/runtime/sites", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Site.Index, :index},
      {:live, "/runtime/pages", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Page.Index, :index},
      {:live, "/runtime/components",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Component.Index, :index},
      {:live, "/runtime/error-pages",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.ErrorPage.Index, :index},
      {:live, "/runtime/js-hooks", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.JsHook.Index,
       :index},
      {:live, "/runtime/translations",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Translation.Index, :index},
      {:live, "/runtime/redirects", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Redirect.Index,
       :index},
      {:live, "/runtime/stylesheets",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Stylesheet.Index, :index},
      {:live, "/runtime/medias", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Media.Index,
       :index},
      {:live, "/runtime/layouts", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Layout.Index,
       :index},
      {:live, "/account/permissions",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.Permission.Index, :index},
      {:live, "/account/users", MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.User.Index, :index},
      {:live, "/notifications", MishkaCmsCoreWeb.Live.Admin.Dashboard.Notification.Index, :index},
      {:live, "/settings", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.SettingsLive, :index}
    ]
  end

  @doc """
  The visual page builder, in its own `live_session`.

  `:section` is page | layout | error-page | component; the canvas is a second LiveView the chrome
  embeds in an iframe, addressed by its session token.

  These are `:admin_standalone` rather than `:admin` because the builder is the one admin page whose
  `<head>` is not the admin's usual head — it carries the in-browser Tailwind JIT and the shim that
  nonces what that JIT and CodeMirror create. The root layout builds `<head>` on a dead render only,
  so a live navigation into the builder would hand it the previous page's head. The separate session
  is what makes arriving here a fresh document; navigation BETWEEN these routes stays live and fast.
  """
  def routes(:admin_standalone) do
    [
      {:live, "/runtime/builder/:section/:id", MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive,
       :edit},
      {:live, "/runtime/builder/:section", MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive, :new},
      {:live, "/runtime/builder-canvas/:token", MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive,
       :canvas},
      # One example of one component, rendered alone for the examples modal's preview pane — the same
      # canvas in preview mode, addressed by the editing session's token.
      {:live, "/runtime/builder-canvas/:token/example/:name/:index",
       MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive, :example},
      # The wizard's preview — the component composed from the reader's own choices, which live in
      # the editing session so this canvas can read them.
      {:live, "/runtime/builder-canvas/:token/wizard/:wizard",
       MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive, :wizard}
    ]
  end

  # A crawler asks for these by what they are, so each also answers an `Accept` naming text or xml
  # alone, which a page refuses, and a stored sitemap file whatever it names — see
  # `MishkaCmsCore.ExtensionRouter.route_accepts/2`.
  @file_formats %{accepts: ["html", "txt", "xml"]}
  @stored_file %{accepts: :any}

  def routes(:public) do
    [
      {:put, "/admin/language", MishkaCmsCoreWeb.AdminLanguageController, :update},
      {:get, "/assets/css/:site/:hash", MishkaCmsCoreWeb.AssetsController, :css},
      {:get, "/assets/js/:site/:hash", MishkaCmsCoreWeb.AssetsController, :js},
      {:get, "/robots.txt", MishkaCmsCoreWeb.SeoController, :robots, private: @file_formats},
      {:get, "/favicon.ico", MishkaCmsCoreWeb.SeoController, :favicon, private: @stored_file},
      {:get, "/sitemap.xml", MishkaCmsCoreWeb.SeoController, :sitemap, private: @file_formats},
      {:get, "/sitemap-:file", MishkaCmsCoreWeb.SeoController, :sitemap_file,
       private: @stored_file}
    ]
  end

  def routes(:api), do: []
  def routes(_), do: []
end
