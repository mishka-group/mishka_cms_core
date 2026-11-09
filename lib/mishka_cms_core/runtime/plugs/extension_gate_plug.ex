# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.ExtensionGatePlug do
  @moduledoc """
  Lets a request through to an extension's API route only while that extension is switched on for
  the request's site, the same switch that takes the extension's entries out of the admin sidebar
  (`MishkaCmsCore.Install.Extensions.active?/2`).

  `MishkaCmsCore.ExtensionRouter.extension_routes/1` puts every route of `routes(:api)` behind it,
  one scope per extension, so an extension writes nothing for it and a host cannot forget it:

      scope "/", alias: false do
        pipe_through {MishkaCmsCore.Runtime.Plugs.ExtensionGatePlug, extension: MishkaBlogWeb}
        get "/feed", MishkaBlogWeb.FeedController, :show
      end

  The site is `conn.assigns.current_site`, which the host's pipeline resolved before this runs. A
  request with no site, or one for a site that switched the extension off, is the 404 an address no
  route has, raised as `MishkaCmsCore.ErrorsExceptions.NotFoundError` in a `Plug.Conn.WrapperError`
  so the host's error page is drawn for the site it resolved, with `cache-control: no-store`.

  An extension's API route keeps no session: a session the pipeline fetched is read but never
  written back, so the answer carries no cookie and a cache in front of the site may keep it.

  The extension's OTP app is read from its `Routes` module once and kept in `:persistent_term`.
  """
  @behaviour Plug

  import Plug.Conn

  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Install.Extensions

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :extension)

  @impl Plug
  def call(conn, extension) do
    with %{id: site_id} when is_binary(site_id) <- conn.assigns[:current_site],
         app when is_atom(app) and not is_nil(app) <- app(extension),
         true <- Extensions.active?(site_id, app) do
      keep_session_unwritten(conn)
    else
      _off -> not_found!(conn)
    end
  end

  @doc "The OTP app `extension` (`MishkaBlogWeb`) belongs to, read from its `Routes` module."
  @spec app(module()) :: atom() | nil
  def app(extension) do
    key = {__MODULE__, extension}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        app = Application.get_application(Module.concat(extension, Routes))
        if app, do: :persistent_term.put(key, app)
        app

      app ->
        app
    end
  end

  defp keep_session_unwritten(%Plug.Conn{private: %{plug_session_fetch: :done}} = conn),
    do: configure_session(conn, ignore: true)

  defp keep_session_unwritten(conn), do: conn

  defp not_found!(conn) do
    raise Plug.Conn.WrapperError,
      conn: put_resp_header(conn, "cache-control", "no-store"),
      kind: :error,
      reason: %NotFoundError{message: "Not found"},
      stack: []
  end
end
