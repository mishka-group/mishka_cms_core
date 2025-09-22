defmodule MishkaCmsCoreWeb.ReturnTo do
  @moduledoc """
  Where a sign-in goes back to, as a token this application signed.

  A page that refuses a visitor who is not signed in sends them to `/auth` with the address they
  asked for, and that address then travels through the URL, through the sign-in and register form
  actions and through the `sign_in_with_token` handoff before `MishkaCmsCoreWeb.AuthController`
  redirects to it. Everything on that road is writable by whoever is walking it, so a `return_to`
  taken at its word would make `/auth` the front door of a phishing site.

  Nothing here parses what arrives. `sign/2` takes a path the router itself matched — built with
  `~p`, never assembled from a parameter — and returns a `Phoenix.Token`; `verify/2` hands that
  exact path back, and hands back nothing for a token that was tampered with, signed with another
  secret or salt, signed too long ago, or never a token at all. A plain path is never a token, so
  `?return_to=/en/members` and `?return_to=https://evil.example` are refused alike, and the caller
  sends whoever cannot be verified home.
  """

  @salt "return_to"

  # Long enough for a mistyped password and a second try, short enough that an address bar someone
  # copied out of is no use to whoever they paste it to.
  @max_age 900

  # WHAT `Phoenix.Controller.redirect/2` REFUSES TO HAND OUT: with these turned away at signing
  # time, no token can ever verify into a value that redirect raises on. The first five are what a
  # browser's URL parser strips or reinterprets, which `Phoenix.URL` turns away; the null byte is
  # what `Plug.Conn.put_resp_header/3` turns away, since the address becomes a `location` header.
  # Both are lists this application does not own, so `MishkaCmsCoreWeb.Test.AuthControllerTest`
  # holds this one against the real `redirect/2` character by character rather than on trust — a
  # Phoenix or a Plug that refuses one more fails that test, instead of answering a visitor who just
  # signed in with a 500.
  @reinterpreted ["\\", "/%09", "/\t", "\n", "\r", "\0"]

  @typedoc "Whatever names the endpoint holding the secret: a conn, a socket, or the endpoint itself"
  @type context :: Plug.Conn.t() | Phoenix.LiveView.Socket.t() | module()

  @doc """
  Signs a same-site path into the opaque token that travels as `return_to`.

  Same-site is exactly what `Phoenix.Controller.redirect/2` will hand out: a single leading `/`, and
  none of the characters a browser's URL parser strips or reinterprets or a response header cannot
  carry. That is a rule about what a browser does with an address, not about how the address reads,
  so an escaped `/%2F/elsewhere.example` is a page of this site and is signed as one — nothing on
  the way to the browser turns that escape into another origin.

  Returns `nil` for anything else, so the sign-in it starts simply has nowhere to come back to.
  """
  @spec sign(context(), term()) :: String.t() | nil
  def sign(context, path) when is_binary(path) do
    if same_site?(path), do: Phoenix.Token.sign(context, @salt, path)
  end

  def sign(_context, _path), do: nil

  @doc """
  Gives back the path a token was signed for, or `nil` when it cannot be verified.
  """
  @spec verify(context(), term()) :: String.t() | nil
  def verify(context, token) when is_binary(token) do
    case Phoenix.Token.verify(context, @salt, token, max_age: @max_age) do
      {:ok, path} when is_binary(path) -> if same_site?(path), do: path
      _unverifiable -> nil
    end
  end

  def verify(_context, _token), do: nil

  # DEFENCE IN DEPTH RATHER THAN THE CHECK ITSELF: a path reaches `sign/2` from `~p`, which escapes
  # or raises on all of this rather than build it, so this can only fail for a later caller that
  # hands over something it did not build — and the signature, not this, is what keeps a stranger's
  # string out. Asked again on the way back so that a token minted before this module refused such a
  # value cannot be spent now.
  defp same_site?("//" <> _elsewhere), do: false
  defp same_site?("/" <> _here = path), do: not String.contains?(path, @reinterpreted)
  defp same_site?(_not_a_path), do: false
end
