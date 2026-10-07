defmodule MishkaCmsCore.Runtime.CspNonce do
  @moduledoc """
  The Content-Security-Policy nonce, carried from the plug into a LiveView and into every template
  it renders.

  ## Why a LiveView needs it at all

  The root layout can read `conn.assigns` and so marks its inline `<script>` without help. A
  LiveView's OWN template cannot: it renders from its socket, which never saw the conn. Several
  templates here emit a `<style>` element — the editor's canvas draws its chrome, its icons and the
  site's theme that way — and every one of them is refused by `style-src-elem` without a nonce.

  ## One nonce per response, signed into the LiveView session

  `MishkaCmsWeb.Runtime.Plugs.SecurityHeaders` mints a fresh nonce for every response, as the CSP
  specification asks: a nonce is only worth something while it cannot be guessed, and one that
  outlives its response is one an attacker has longer to learn.

  A LiveView keeps rendering over its socket long after that response, and everything it renders
  must carry the nonce THAT document's header named. The socket's own session is the cookie at the
  moment it connects, so a nonce kept there would follow whichever tab loaded last. Instead,
  `session/1` is a `live_session` `:session` function: Phoenix signs what it returns into the page
  (`data-phx-session`), the connected mount reads it back from that token, and a live navigation
  inside the session carries the same token — so every render of one document agrees with its own
  header, and two tabs never share a nonce.

      live_session :public, session: {MishkaCmsCore.Runtime.CspNonce, :session, []} do

  ## Using it in a template

  `@csp_nonce` in a LiveView's own template, and `csp_nonce()` anywhere a runtime template is
  compiled — a page, a layout, a component — because a component sees only the attrs it is handed:

      <style nonce={csp_nonce()}>…</style>

  A `<style>` is the last resort. A class, the element's CSS box in the editor or a stylesheet row
  is cached, shared between pages and needs no nonce at all.

  `on_mount/4` records the value for the process, and the plug does the same for a response that
  renders no LiveView, so `current/0` is one process-dictionary read on every call.
  """

  import Phoenix.Component, only: [assign_new: 3]

  @session_key "csp_nonce"
  @process_key {__MODULE__, :nonce}

  @doc "The session key `session/1` writes and `on_mount/4` reads."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  What a `live_session` signs into the page for its LiveViews: this response's nonce.

  `%{}` when the plug did not run, so the session carries nothing rather than a `nil` the mount
  would have to tell apart from a real value.
  """
  @spec session(Plug.Conn.t()) :: %{optional(String.t()) => String.t()}
  def session(%Plug.Conn{assigns: %{csp_nonce: nonce}}) when is_binary(nonce),
    do: %{@session_key => nonce}

  def session(_conn), do: %{}

  @doc """
  The nonce of the response this process is rendering, or `nil` outside one.

  Set by the plug for the request process and by `on_mount/4` for a LiveView process.
  """
  @spec current() :: String.t() | nil
  def current, do: Process.get(@process_key)

  @doc "Records `nonce` as the one this process renders with. `nil` clears it."
  @spec put(String.t() | nil) :: :ok
  def put(nonce) when is_binary(nonce) do
    Process.put(@process_key, nonce)
    :ok
  end

  def put(nil) do
    Process.delete(@process_key)
    :ok
  end

  @doc false
  def on_mount(:default, _params, session, socket) do
    socket = assign_new(socket, :csp_nonce, fn -> session[@session_key] end)
    :ok = put(socket.assigns.csp_nonce)
    {:cont, socket}
  end

  def on_mount(_name, params, session, socket), do: on_mount(:default, params, session, socket)
end
