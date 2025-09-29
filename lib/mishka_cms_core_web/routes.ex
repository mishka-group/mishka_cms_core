defmodule MishkaCmsCoreWeb.Routes do
  @moduledoc """
  Extension routes for MishkaCmsCore (core admin dashboard, runtime, accounts).
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    [
      {:live, "/account/permissions",
       MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.Permission.Index, :index},
      {:live, "/account/users", MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.User.Index, :index},
      {:live, "/notifications", MishkaCmsCoreWeb.Live.Admin.Dashboard.Notification.Index, :index}
    ]
  end

  def routes(:admin_standalone) do
    []
  end

  def routes(:public) do
    [
      {:put, "/admin/language", MishkaCmsCoreWeb.AdminLanguageController, :update}
    ]
  end

  def routes(:api), do: []
  def routes(_), do: []
end
