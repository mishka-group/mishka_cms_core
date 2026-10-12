defmodule MishkaCmsCoreWeb.AdminLanguageController do
  @moduledoc """
  Keeps the language an admin reads the dashboard in, chosen in the topbar's user menu.

  `PUT /admin/language` with `language` and `return_to`. The language is kept in the session under
  `MishkaCmsCore.Runtime.Languages.admin_session/0` when it is one of
  `MishkaCmsCore.Runtime.Languages.admin_choices/1` for the request's site; any other is ignored.
  The browser is then sent back to `return_to` when it is an admin page, else to the dashboard.

  A plugin on `web:request:admin_language_chosen` is handed the conn with the chosen language in
  `meta`, and may change the conn or halt it.

  The language is the dashboard's alone: the site's visitors, and the admin reading the site, keep
  the one `MishkaCmsCore.Runtime.Plugs.LanguagePlug` remembers.
  """
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias MishkaCmsCore.PluginEvent
  alias MishkaCmsCore.Runtime.Languages

  @dashboard "/admin/dashboard"

  def update(conn, params) do
    conn = choose(conn, params["language"])

    if conn.halted, do: conn, else: redirect(conn, to: back(params["return_to"]))
  end

  defp choose(%{assigns: %{current_site: %{id: site_id}}} = conn, language)
       when is_binary(language) do
    if language in Languages.admin_choices(site_id) do
      conn
      |> put_session(Languages.admin_session(), language)
      |> then(
        &PluginEvent.call("web:request:admin_language_chosen", &1, meta: %{language: language})
      )
    else
      conn
    end
  end

  defp choose(conn, _language), do: conn

  defp back("/admin/" <> _rest = path) do
    if String.contains?(path, ["//", "\\", "\n", "\r"]), do: @dashboard, else: path
  end

  defp back(_path), do: @dashboard
end
