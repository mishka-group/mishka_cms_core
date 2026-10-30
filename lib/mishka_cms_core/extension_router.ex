# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.ExtensionRouter do
  @moduledoc """
  Behaviour and macro for extensions to define their routes.

  Extensions implement this behaviour to register their admin, public, and API routes.
  The main CMS router uses `extension_routes/1` macro to load all extension routes.

  ## Usage

  In your extension:

      defmodule MishkaBlogWeb.Routes do
        @behaviour MishkaCmsCore.ExtensionRouter

        @impl true
        def routes(:admin) do
          [
            {:live, "/blog/posts", MishkaBlogWeb.Live.Admin.PostLive, :index}
          ]
        end

        def routes(_), do: []
      end

  In your main router:

      import MishkaCmsCore.ExtensionRouter

      scope "/admin/dashboard" do
        pipe_through [:browser, :require_authenticated_user]

        live_session :admin do
          extension_routes(:admin)
        end

        live_session :admin_standalone do
          extension_routes(:admin_standalone)
        end
      end

  In config.exs:

      config :mishka_cms, :extensions, [
        MishkaBlogWeb,
        MishkaDocumentWeb
      ]
  """

  @type route_type :: :admin | :admin_standalone | :public | :api

  @type route ::
          {:live, String.t(), module(), atom()}
          | {:live, String.t(), module(), atom(), keyword()}
          | {:get | :post | :put | :patch | :delete, String.t(), module(), atom()}
          | {:get | :post | :put | :patch | :delete, String.t(), module(), atom(), keyword()}

  @doc """
  Returns the routes for the given type.

  Types:
  - `:admin` - Admin dashboard routes
  - `:admin_standalone` - Admin routes that need a document of their own (see below)
  - `:public` - Public-facing routes
  - `:api` - API routes

  ## When a route belongs in `:admin_standalone`

  Only when the page needs something in `<head>` that the rest of the admin does not.

  The root layout decides `<head>` from the LiveView's assigns, and it renders once per HTTP
  response. A live navigation does not produce one: the destination LiveView runs inside the
  document the SOURCE page built, with the source page's head. A page whose stylesheets, scripts or
  meta tags differ from its neighbours' therefore arrives half-dressed, with no error anywhere —
  the page builder reached this way lost its Tailwind JIT and the shim that nonces what it creates,
  and its code editor opened unstyled.

  `:admin_standalone` routes are emitted into a `live_session` of their own, and LiveView will not
  live-navigate across a `live_session` boundary: arriving is a full page load, and so is leaving,
  which also sheds whatever the page installed. Navigation BETWEEN two routes in this list stays
  live, which is what makes it the right home for a group of pages that share a head.

  So an admin page links INTO one with `href` (or `redirect/2`), not `navigate` (or
  `push_navigate/2`). A `navigate` link still arrives, but only after LiveView has tried the live
  navigation and refused it, logging "redirecting across live_sessions" on the server and
  "unauthorized live_redirect" in the browser.

  Everything else belongs in `:admin`. The boundary costs a page load in each direction, and a page
  that is dressed like the rest of the admin has nothing to buy with it.
  """
  @callback routes(route_type()) :: [route()]

  @doc """
  Macro to inject all extension routes into your router.

  Extensions are configured in `:mishka_cms, :extensions`.
  This macro is evaluated at compile time - no runtime overhead.
  """
  defmacro extension_routes(type) do
    quote do
      extensions = Application.compile_env(:mishka_cms_core, :extensions, [])

      routes =
        Enum.flat_map(extensions, fn ext ->
          routes_module = Module.concat(ext, Routes)

          case Code.ensure_compiled(routes_module) do
            {:module, _} ->
              :ok

            {:error, reason} ->
              raise CompileError,
                description: """
                Extension #{inspect(ext)} is missing its Routes module.

                Expected module: #{inspect(routes_module)}
                Reason: #{inspect(reason)}

                Please create the module:

                    defmodule #{inspect(routes_module)} do
                      @behaviour MishkaCmsCore.ExtensionRouter

                      @impl true
                      def routes(:admin), do: []
                      def routes(:public), do: []
                      def routes(:api), do: []
                    end
                """
          end

          if !function_exported?(routes_module, :routes, 1) do
            raise CompileError,
              description: """
              Extension #{inspect(routes_module)} does not implement routes/1 callback.

              Please implement the MishkaCmsCore.ExtensionRouter behaviour:

                  defmodule #{inspect(routes_module)} do
                    @behaviour MishkaCmsCore.ExtensionRouter

                    @impl true
                    def routes(:admin), do: []
                    def routes(:public), do: []
                    def routes(:api), do: []
                  end
              """
          end

          routes_module.routes(unquote(type))
        end)

      scope "/", alias: false do
        for route <- routes do
          case route do
            {:live, path, module, action} ->
              live(path, module, action)

            {:live, path, module, action, opts} ->
              live(path, module, action, opts)

            {verb, path, module, action} when verb in [:get, :post, :put, :patch, :delete] ->
              match(verb, path, module, action)

            {verb, path, module, action, opts}
            when verb in [:get, :post, :put, :patch, :delete] ->
              match(verb, path, module, action, opts)
          end
        end
      end
    end
  end

  @doc """
  `Phoenix.Controller.accepts/2` for a pipeline that pages and files share: the formats the matched
  route names under its `:accepts` private, or `formats` for a route that names none.

  Plug it in place of `plug :accepts, formats`, imported from this module:

  ```elixir
  import MishkaCmsCore.ExtensionRouter

  pipeline :browser do
    plug :route_accepts, ["html"]
    # ...
  end
  ```

  A route answering a file of another kind names what it answers, and every other route keeps
  `formats` — so `/robots.txt` answers `Accept: text/plain` while a page asked the same is still
  refused with a 406:

      {:get, "/robots.txt", MyExtWeb.RobotsController, :show,
       private: %{accepts: ["html", "txt", "xml"]}}

  A route serving a stored file as it is names `:any`, and answers whatever `Accept` it is sent, as
  `Plug.Static` does — a crawler asks for a gzipped sitemap as `application/x-gzip`, which no format
  names:

      {:get, "/sitemap-:file", MyExtWeb.SitemapController, :file, private: %{accepts: :any}}

  A route's `private` is on the conn before its pipeline runs, so this reads the route being served.
  """
  @spec route_accepts(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def route_accepts(%Plug.Conn{private: %{accepts: :any}} = conn, _formats), do: conn

  def route_accepts(conn, formats),
    do: Phoenix.Controller.accepts(conn, Map.get(conn.private, :accepts, formats))
end
