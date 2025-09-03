defmodule MishkaCmsCore.Runtime.CspNonce do
  @moduledoc """
  The Content-Security-Policy nonce, carried from the plug into a LiveView's own assigns.

  ## Why a LiveView needs it at all

  The root layout can read `conn.assigns` and so marks its inline `<script>` without help. A
  LiveView's OWN template cannot: it renders from its socket, which never saw the conn. Several
  templates here emit a `<style>` element — the editor's canvas draws its chrome, its icons and the
  site's theme that way, and the theme builder previews a palette that changes as you drag — and
  every one of them is refused by `style-src-elem` without a nonce.

  Enforcing the policy on public pages without this broke `/theme-builder` outright: both of its
  `<style>` blocks were refused and the page rendered with its layout collapsed.

  ## Why the SESSION and not the request

  A nonce is conventionally minted per response, and for a dead render that is right. A LiveView
  re-renders over the socket for as long as the page is open, long after the response that carried
  the header is gone — so a per-request nonce would put a value in the DOM that the live policy no
  longer names, and the first re-render of a `<style>` would be refused. The nonce therefore lives
  in the session, which the dead render and every later re-render agree on.

  That is weaker than per-response and worth being clear about: it is stable for the length of a
  session. It still does the one thing a nonce is for — markup injected into the page cannot carry
  it, because whoever injects it does not get to write the attribute.

  ## Use

      live_session :something, on_mount: [MishkaCmsCore.Runtime.CspNonce] do

  and then `nonce={@csp_nonce}` on the `<style>` or `<script>` the template renders.
  """
  import Phoenix.Component, only: [assign_new: 3]

  @session_key "csp_nonce"

  @doc "The session key the plug writes and `on_mount/4` reads."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc false
  def on_mount(:default, _params, session, socket),
    do: {:cont, assign_new(socket, :csp_nonce, fn -> session[@session_key] end)}

  def on_mount(_name, params, session, socket), do: on_mount(:default, params, session, socket)
end
