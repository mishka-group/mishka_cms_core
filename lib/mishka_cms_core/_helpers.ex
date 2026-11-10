# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Helpers do
  @moduledoc """
  Runtime helpers for extensions.
  """

  # The host's endpoint, named by configuration rather than hardcoded — this library does not know
  # which application it is installed into. Applied rather than called so it stays a runtime
  # dispatch: the host's endpoint is not compile-visible from here.
  @host_endpoint Application.compile_env!(:mishka_cms_core, :endpoint)

  # The host's OTP application, named by configuration for the same reason: the version a page shows
  # is the one of the application the CMS is installed into, which this library cannot know.
  @host_app Application.compile_env!(:mishka_cms_core, :host_app)

  @doc """
  Generates a path with the correct script_name prefix for deployment.

  Extracts the router from the socket/conn to determine the script_name prefix.
  Does NOT verify the route exists - only ensures the path has the correct
  prefix for your deployment configuration.

  ## Parameters

    * `socket_or_conn` - A `Phoenix.LiveView.Socket` or `Plug.Conn`
    * `path` - The path string (e.g., `"/admin/dashboard"`)

  ## Examples

      # In templates:
      <.link navigate={path(@socket, "/admin/dashboard")}>Dashboard</.link>

      # With dynamic segments:
      <.link navigate={path(@socket, "/posts/\#{@post.id}")}>View Post</.link>

      # If deployed at example.com/cms/:
      path(@socket, "/admin")  # => "/cms/admin"

  Provides path generation and other utilities that work at runtime
  without compile-time dependencies on the main CMS router/endpoint.

  ## Path Generation

  Since extensions compile before the main CMS, they cannot use `~p` sigils
  which require compile-time knowledge of the router. Instead, use the
  runtime `path/2` and `url/2` functions:

      # In your LiveView template:
      <.link navigate={path(@socket, "/admin/dashboard/blog")}>Blog</.link>

      # Or in your LiveView module:
      def handle_event("navigate", _, socket) do
        {:noreply, push_navigate(socket, to: path(socket, "/posts"))}
      end

  ## How It Works

  These functions use `Phoenix.VerifiedRoutes.unverified_path/3` internally.
  The router parameter is needed to get the **script_name prefix**, not for
  route verification.

  ### What is script_name?

  When your app is deployed under a subdirectory (e.g., `example.com/cms/`),
  the script_name is `/cms`. The path helper ensures all generated paths
  include this prefix:

      # App deployed at: https://example.com/cms/
      path(@socket, "/admin/dashboard")
      # => "/cms/admin/dashboard"

      # App deployed at root: https://example.com/
      path(@socket, "/admin/dashboard")
      # => "/admin/dashboard"

  ### Verified vs Unverified

  | Feature                    | `~p"/path"`  | `path(@socket, "/path")` |
  |----------------------------|--------------|--------------------------|
  | Compile-time route check   | Yes          | No                       |
  | Adds script_name prefix    | Yes          | Yes                      |
  | Works in extensions        | No           | Yes                      |

  Extensions cannot use `~p` because the router doesn't exist at compile time.
  These helpers provide the same script_name handling at runtime.

  > **Note:** These functions do NOT verify routes exist - that's your
  > responsibility. They only ensure paths have the correct deployment prefix.
  """
  def path(%Phoenix.LiveView.Socket{} = socket, path) when is_binary(path) do
    router = socket.router
    Phoenix.VerifiedRoutes.unverified_path(socket, router, path)
  end

  def path(%Plug.Conn{} = conn, path) when is_binary(path) do
    router = conn.private.phoenix_router
    Phoenix.VerifiedRoutes.unverified_path(conn, router, path)
  end

  @doc """
  Generates a full URL with scheme, host, port, and script_name prefix.

  Extracts the router from the socket/conn to build the complete URL.
  Does NOT verify the route exists - only ensures the URL has the correct
  configuration for your deployment.

  ## Parameters

    * `socket_or_conn` - A `Phoenix.LiveView.Socket` or `Plug.Conn`
    * `path` - The path string (e.g., `"/posts/123"`)

  ## Examples

      # Generate full URL:
      url(@socket, "/posts/\#{@post.id}")
      # => "https://example.com/posts/123"

      # If deployed at example.com/cms/:
      url(@socket, "/admin")
      # => "https://example.com/cms/admin"

  """
  def url(%Phoenix.LiveView.Socket{} = socket, path) when is_binary(path),
    do: Phoenix.VerifiedRoutes.unverified_url(socket, path(socket, path))

  def url(%Plug.Conn{} = conn, path) when is_binary(path),
    do: Phoenix.VerifiedRoutes.unverified_url(conn, path(conn, path))

  @doc """
  The absolute URL of `path` on a site's own address: its `host`, with the scheme and port the
  endpoint answers on. Needs no conn or socket, so a sitemap, a robots.txt or an admin page can link
  a site it is not being asked from. A port of 80, 443 or none is left out. `path` is written as
  `address_path/1` writes it, so the home page is the address alone.

  ## Examples

      # In production:
      site_url("blog.example.com", "/sitemap.xml")
      # => "https://blog.example.com/sitemap.xml"
      site_url("blog.example.com", "/")
      # => "https://blog.example.com"

      # In development:
      site_url("blog.localhost", "/sitemap.xml")
      # => "http://blog.localhost:4000/sitemap.xml"

  Not `url/2` for a site: that builds on the endpoint's own configured host, which is `localhost`
  in production whatever site is asked.
  """
  @spec site_url(String.t(), String.t()) :: String.t()
  def site_url(host, path) when is_binary(host) and is_binary(path) do
    uri = apply(@host_endpoint, :struct_url, [])
    port = if uri.port in [80, 443, nil], do: "", else: ":#{uri.port}"
    "#{uri.scheme}://#{host}#{port}#{url_path(path)}"
  end

  @doc """
  The version of the application this CMS runs in — the host's own, as its `mix.exs` declares it and
  `config :mishka_cms_core, :host_app` names it — as a string, read when it is asked for.

  What a page that wants to say which version it is drawn by calls, so no template writes one:

      MishkaCmsCore.Helpers.host_version()   #=> "0.0.1"

  A template writes `v{MishkaCmsCore.Helpers.host_version()}`; the installer's own header reads the
  same function. Empty when the application is not loaded, which only a test that never started it
  can see.
  """
  @spec host_version() :: String.t()
  def host_version, do: @host_app |> Application.spec(:vsn) |> to_string()

  @doc """
  A path as every address of a site writes it: no slash at its end and never two in a row, so the
  home page is empty and the site's address stands alone. The query and the fragment, if any, are
  kept as they are. Its segments are left as they are given; `url_path/1` is the same path as a URL
  writes it.

  The one slash rule behind the sitemap, the canonical address, `og:url`, the `hreflang` alternates,
  the JSON-LD `url`s and `site_url/2`; none of them writes an address of its own.

      address_path("/blog/")         #=> "/blog"
      address_path("//blog//post/")  #=> "/blog/post"
      address_path("/blog/?page=2")  #=> "/blog?page=2"
      address_path("/")              #=> ""
  """
  @spec address_path(String.t()) :: String.t()
  def address_path(path) when is_binary(path), do: written_path(path, & &1)

  @doc """
  `address_path/1` with each segment written in one form, whether it comes raw or already
  percent-encoded: a character a path segment may hold as it is (RFC 3986 `pchar`: letters, digits,
  `-._~!$&'()*+,;=:@`) stands as it is, every other byte — a non-ASCII letter, a space, or a `%`
  that starts no escape — is `%XX` with upper-case hex, and an escape already there is never
  encoded twice. A browser asks for `/fa/داستان` as `/fa/%D8%AF…`, so a stored path and the path a
  visit came on name one URL.

  What `site_url/2` and `MishkaCmsCore.Runtime.Seo.absolute/2` write, so the canonical address,
  `og:url`, every `hreflang` alternate, the sitemap's `<loc>` and a feed's links agree.

      url_path("/fa/ما/")           #=> "/fa/%D9%85%D8%A7"
      url_path("/fa/%d9%85%D8%A7")  #=> "/fa/%D9%85%D8%A7"
      url_path("/a%3Ab/50%")        #=> "/a:b/50%25"
      url_path("/blog?q=ما")        #=> "/blog?q=ما"
  """
  @spec url_path(String.t()) :: String.t()
  def url_path(path) when is_binary(path), do: written_path(path, &path_segment(&1, ""))

  defp written_path(path, segment_fun) do
    {location, tail} =
      case :binary.match(path, ["?", "#"]) do
        {at, _length} -> {binary_part(path, 0, at), binary_part(path, at, byte_size(path) - at)}
        :nomatch -> {path, ""}
      end

    for(
      segment <- String.split(location, "/", trim: true),
      into: "",
      do: "/" <> segment_fun.(segment)
    ) <> tail
  end

  defguardp is_hex(char) when char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defp path_segment(<<?%, high, low, rest::binary>>, written)
       when is_hex(high) and is_hex(low) do
    path_segment(rest, written <> path_byte(List.to_integer([high, low], 16)))
  end

  defp path_segment(<<byte, rest::binary>>, written),
    do: path_segment(rest, written <> path_byte(byte))

  defp path_segment(<<>>, written), do: written

  defp path_byte(byte) when byte in ~c"!$&'()*+,;=:@", do: <<byte>>

  defp path_byte(byte) do
    if URI.char_unreserved?(byte), do: <<byte>>, else: "%" <> Base.encode16(<<byte>>)
  end
end
