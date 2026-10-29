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
      {:get, "/apple-touch-icon.png", MishkaCmsCoreWeb.SeoController, :site_icon,
       private: Map.put(@stored_file, :icon_size, 180)},
      {:get, "/apple-touch-icon-precomposed.png", MishkaCmsCoreWeb.SeoController, :site_icon,
       private: Map.put(@stored_file, :icon_size, 180)},
      {:get, "/site-icon-192.png", MishkaCmsCoreWeb.SeoController, :site_icon,
       private: Map.put(@stored_file, :icon_size, 192)},
      {:get, "/site-icon-512.png", MishkaCmsCoreWeb.SeoController, :site_icon,
       private: Map.put(@stored_file, :icon_size, 512)},
      {:get, "/site.webmanifest", MishkaCmsCoreWeb.SeoController, :manifest,
       private: @stored_file},
      {:get, "/sitemap.xml", MishkaCmsCoreWeb.SeoController, :sitemap, private: @file_formats},
      {:get, "/sitemap-:file", MishkaCmsCoreWeb.SeoController, :sitemap_file,
       private: @stored_file}
    ]
  end

  def routes(:api), do: []
  def routes(_), do: []
end
