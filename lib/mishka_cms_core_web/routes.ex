defmodule MishkaCmsCoreWeb.Routes do
  @moduledoc """
  Extension routes for MishkaCmsCore (core admin dashboard, runtime, accounts).
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    []
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
