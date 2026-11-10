# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.TestApiExtension.Routes do
  @moduledoc """
  The routes of a stand-in extension with an API, listed in `config/test.exs` beside the core's own:
  `/_api_ext/ping` answers JSON, and `/_api_ext/ping.txt` names `accepts: :any` and answers any
  `Accept`, and `/_api_ext/session` answers what the session holds under `"probe"` for a `GET` and a
  `POST`. They belong to `:mishka_cms_core`, so its `mishka_cms_core.active` switch turns them off.
  """
  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:api) do
    [
      {:get, "/_api_ext/ping", MishkaCmsCore.TestApiExtension.PingController, :show},
      {:get, "/_api_ext/ping.txt", MishkaCmsCore.TestApiExtension.PingController, :show,
       private: %{accepts: :any}},
      {:get, "/_api_ext/session", MishkaCmsCore.TestApiExtension.PingController, :session},
      {:post, "/_api_ext/session", MishkaCmsCore.TestApiExtension.PingController, :session}
    ]
  end

  def routes(_type), do: []
end

defmodule MishkaCmsCore.TestApiExtension.PingController do
  @moduledoc "Answers the stand-in extension's API routes with the site the request resolved, or its session."
  use Phoenix.Controller, formats: []

  def show(conn, _params),
    do: json(conn, %{site: conn.assigns.current_site.id, format: get_format(conn)})

  def session(conn, _params), do: json(conn, %{probe: Plug.Conn.get_session(conn, "probe")})
end
