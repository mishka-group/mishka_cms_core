# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.ReturnTo do
  @moduledoc """
  Where a sign-in goes back to: a path of this site, as typed or as a token this application signed.

  A page that sends a visitor to `/auth` with the address to come back to puts that address in the
  URL, and it then travels through the sign-in and register form actions and through the
  `sign_in_with_token` handoff before `MishkaCmsCoreWeb.AuthController` redirects to it. Everything
  on that road is writable by whoever is walking it, so a `return_to` that may name another origin
  would make `/auth` the front door of a phishing site.

  `return_to` comes in two shapes, and both end on a page of this site or nowhere:

    * a plain path, `?return_to=/buy/product-d`, the way a link or a person writes it. It is
      followed only when it is one `Phoenix.Controller.redirect/2` hands out as a local path: a
      single leading `/` and none of the characters a browser strips or reinterprets, so
      `//evil.example`, `https://evil.example`, `/\\evil.example` and `javascript:` are refused;
    * a `Phoenix.Token` that `sign/2` made over such a path, which an extension hands out when the
      address comes from a request and should not be read in the clear. It expires after fifteen
      minutes and is refused when tampered with or signed with another secret or salt.

  `verify/2` hands back the path, or `nil`, and the caller sends whoever has no path home.
  """

  @salt "return_to"

  # Long enough for a mistyped password and a second try, short enough that an address bar someone
  # copied out of is no use to whoever they paste it to.
  @max_age 900

  # WHAT `Phoenix.Controller.redirect/2` REFUSES TO HAND OUT: with these turned away, no token and
  # no plain path can ever verify into a value that redirect raises on. The first five are what a
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
  Gives back the path a `return_to` names, or `nil`.

  A plain path comes back as it is when it is a path of this site. A token comes back as the path
  it was signed for, and `nil` when it cannot be verified.
  """
  @spec verify(context(), term()) :: String.t() | nil
  def verify(_context, "/" <> _here = path), do: if(same_site?(path), do: path)

  def verify(context, token) when is_binary(token) do
    case Phoenix.Token.verify(context, @salt, token, max_age: @max_age) do
      {:ok, path} when is_binary(path) -> if same_site?(path), do: path
      _unverifiable -> nil
    end
  end

  def verify(_context, _token), do: nil

  # A PATH OF THIS SITE: what `Phoenix.Controller.redirect/2` hands out as a local path, asked of a
  # plain path and of a token's path alike.
  defp same_site?("//" <> _elsewhere), do: false
  defp same_site?("/" <> _here = path), do: not String.contains?(path, @reinterpreted)
  defp same_site?(_not_a_path), do: false
end
