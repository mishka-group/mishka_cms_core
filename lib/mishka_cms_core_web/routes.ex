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
      {:live, "/runtime/translations",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Translation.Index, :index},
      {:live, "/runtime/medias", MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Media.Index,
       :index},
      {:live, "/account/permissions",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.Permission.Index, :index},
      {:live, "/account/users", MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.User.Index, :index},
      {:live, "/notifications", MishkaCmsCoreWeb.Live.Admin.Dashboard.Notification.Index, :index}
    ]
  end

  def routes(:admin_standalone) do
    []
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
      {:get, "/sitemap.xml", MishkaCmsCoreWeb.SeoController, :sitemap, private: @file_formats},
      {:get, "/sitemap-:file", MishkaCmsCoreWeb.SeoController, :sitemap_file,
       private: @stored_file}
    ]
  end

  def routes(:api), do: []
  def routes(_), do: []
end
