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
    "#{uri.scheme}://#{host}#{port}#{address_path(path)}"
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
  kept as they are.

  The one rule behind the sitemap, the canonical address, `og:url`, the `hreflang` alternates, the
  JSON-LD `url`s and `site_url/2`; none of them writes an address of its own.

      address_path("/blog/")         #=> "/blog"
      address_path("//blog//post/")  #=> "/blog/post"
      address_path("/blog/?page=2")  #=> "/blog?page=2"
      address_path("/")              #=> ""
  """
  @spec address_path(String.t()) :: String.t()
  def address_path(path) when is_binary(path) do
    {location, tail} =
      case :binary.match(path, ["?", "#"]) do
        {at, _length} -> {binary_part(path, 0, at), binary_part(path, at, byte_size(path) - at)}
        :nomatch -> {path, ""}
      end

    for(segment <- String.split(location, "/", trim: true), into: "", do: "/" <> segment) <> tail
  end
end
