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

  ## API routes

  `routes(:api)` is for what an extension answers that is not a page: a feed, a JSON endpoint, a
  file it writes. The host mounts them before its catch-all, through a pipeline that resolves the
  site and closes an offline one, with no CSRF check and no sign-in:

      pipeline :extension_api do
        plug :route_accepts, ["json"]
        plug :fetch_session
        plug :put_secure_browser_headers
        plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
        # the host's offline gate
      end

      scope "/" do
        pipe_through :extension_api

        extension_routes(:api)
      end

  Every extension's API routes are put in a scope of their own behind
  `MishkaCmsCore.Runtime.Plugs.ExtensionGatePlug`, so a site that switched the extension off answers
  them with a 404 and no session cookie is ever written. A route that answers something other than
  JSON names it under `private: %{accepts: ...}` (see `route_accepts/2`).

  A `POST`, `PUT`, `PATCH` or `DELETE` to one reads an empty session: the pipeline has no CSRF check,
  so the gate will not let a form on another site act as the visitor signed in here. A route that
  takes those methods authenticates the request itself, as a webhook checks its signature.

  ## What a route may claim

  The `:api` routes are mounted before every host route but `/admin/dashboard`, `/install` and the
  API's own, and the first route that matches answers, so a careless path takes addresses the host
  owns. The router refuses to compile, naming the extension and the route, when a `routes(:api)`
  route:

    * starts with a segment the host answers itself, one of `host_prefixes/0`: `/admin`, `/api`,
      `/auth`, `/gql`, `/install`, `/_preview`, `/dev`, `/oban`, the static `/uploads`, `/assets`,
      `/fonts` and `/images`, and the `/live`, `/ws` and `/phoenix` sockets;
    * is `/`, or starts with a capture (`/:slug`, `/*rest`), which takes every address. The language
      capture is the exception (`MishkaCmsCore.Runtime.Languages.capture/0`, `/:lang/feed`) when a
      fixed segment that is not the host's follows it: `/:lang` alone, `/:lang/:slug` and
      `/:lang/auth` are refused;
    * has the verb and path of another route in the list, of any extension; captures are compared by
      place, not name, so `/feed/:a` and `/feed/:b` are one route;
    * is a `:live` route, which is a page and belongs in `routes(:public)`.

  `routes(:public)` is mounted in the host's page scope before its preview, sign-in and catch-all
  routes, so the capture, `/` and duplicate checks hold for it too. It may start with a host segment
  and list `:live` routes: that list is where an extension serves under the host's addresses on
  purpose (`/admin/language`, `/assets/css/:site/:hash`, `/_preview/doc-example/...`).

  In config.exs:

      config :mishka_cms, :extensions, [
        MishkaBlogWeb,
        MishkaDocumentWeb
      ]
  """

  alias MishkaCmsCore.Runtime.Languages

  @host_prefixes ~w(admin api auth gql install _preview dev oban uploads assets fonts images live ws phoenix)

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
      require MishkaCmsCore.ExtensionRouter

      extension_routes =
        MishkaCmsCore.ExtensionRouter.__routes__(
          Application.compile_env(:mishka_cms_core, :extensions, []),
          unquote(type)
        )

      for {ext, routes} <- extension_routes, routes != [] do
        scope "/", alias: false do
          if unquote(type) == :api,
            do: pipe_through({MishkaCmsCore.Runtime.Plugs.ExtensionGatePlug, extension: ext})

          for route <- routes, do: MishkaCmsCore.ExtensionRouter.__route__(route)
        end
      end
    end
  end

  @doc """
  The top-level path segments the host answers itself, which no `routes(:api)` route may start with
  (see "What a route may claim" in the moduledoc).
  """
  @spec host_prefixes() :: [String.t()]
  def host_prefixes, do: @host_prefixes

  @doc false
  @spec __routes__([module()], route_type()) :: [{module(), [route()]}]
  def __routes__(extensions, type) do
    extensions
    |> Enum.map(&{&1, extension_routes!(&1, type)})
    |> check_routes!(type)
  end

  defp extension_routes!(ext, type) do
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

    routes_module.routes(type)
  end

  defp check_routes!(extension_routes, type) when type in [:api, :public] do
    for {ext, routes} <- extension_routes, route <- routes, do: check_route!(ext, route, type)

    extension_routes
    |> Enum.flat_map(fn {ext, routes} -> Enum.map(routes, &{ext, &1}) end)
    |> Enum.group_by(fn {_ext, route} -> {elem(route, 0), normalized(elem(route, 1))} end)
    |> Enum.each(fn
      {_key, [_one]} -> :ok
      {_key, claimants} -> refuse_duplicate!(claimants, type)
    end)

    extension_routes
  end

  defp check_routes!(extension_routes, _type), do: extension_routes

  defp check_route!(ext, route, :api) when elem(route, 0) == :live,
    do: refuse!(ext, route, :api, "A `:live` route is a page: list it in `routes(:public)`.")

  defp check_route!(ext, route, type) do
    case claim(segments(elem(route, 1)), type) do
      :ok -> :ok
      {:error, reason} -> refuse!(ext, route, type, reason)
    end
  end

  defp claim([], _type),
    do: {:error, "`/` is the site's home page, which the host's catch-all answers."}

  defp claim([":" <> name, next | _rest], type) do
    if name == Languages.capture(),
      do: claim_after_language(next, type),
      else: claim([":" <> name], type)
  end

  defp claim([":" <> _ = first | _rest], _type), do: {:error, bare_capture(first)}
  defp claim(["*" <> _ = first | _rest], _type), do: {:error, bare_capture(first)}
  defp claim([first | _rest], :api) when first in @host_prefixes, do: {:error, host_owned(first)}
  defp claim(_segments, _type), do: :ok

  defp claim_after_language(":" <> _ = next, _type),
    do: {:error, "After `/:#{Languages.capture()}`, " <> bare_capture(next)}

  defp claim_after_language("*" <> _ = next, _type),
    do: {:error, "After `/:#{Languages.capture()}`, " <> bare_capture(next)}

  defp claim_after_language(next, :api) when next in @host_prefixes,
    do: {:error, host_owned(next)}

  defp claim_after_language(_next, _type), do: :ok

  defp bare_capture(segment),
    do:
      "the capture `#{segment}` takes every address there, the host's pages and sign-in among " <>
        "them. Start the path with a fixed segment, such as `/feed/#{segment}`."

  defp host_owned(segment),
    do: "`/#{segment}` belongs to the host (#{Enum.map_join(@host_prefixes, ", ", &"/#{&1}")})."

  defp refuse!(ext, route, type, reason) do
    raise CompileError,
      description: """
      Extension #{inspect(ext)} lists a route the host cannot mount: \
      #{route_name(route)} in routes(#{inspect(type)}).

      #{reason}
      """
  end

  defp refuse_duplicate!([{_ext, route} | _] = claimants, type) do
    raise CompileError,
      description: """
      #{route_name(route)} in routes(#{inspect(type)}) is listed more than once, so only the \
      first would ever answer: #{Enum.map_join(claimants, ", ", &claimant/1)}.

      Give each of these routes an address of its own.
      """
  end

  defp claimant({ext, route}), do: "#{route_name(route)} of #{inspect(ext)}"

  defp route_name(route),
    do: "#{route |> elem(0) |> to_string() |> String.upcase()} #{elem(route, 1)}"

  defp segments(path), do: String.split(path, "/", trim: true)

  defp normalized(path), do: Enum.map(segments(path), &normalized_segment/1)

  defp normalized_segment("*" <> _name), do: "*"

  defp normalized_segment(segment) do
    case String.split(segment, ":", parts: 2) do
      [fixed, _name] -> fixed <> ":"
      [fixed] -> fixed
    end
  end

  @doc false
  defmacro __route__(route) do
    quote do
      case unquote(route) do
        {:live, path, module, action} ->
          live(path, module, action)

        {:live, path, module, action, opts} ->
          live(path, module, action, opts)

        {verb, path, module, action} when verb in [:get, :post, :put, :patch, :delete] ->
          match(verb, path, module, action)

        {verb, path, module, action, opts} when verb in [:get, :post, :put, :patch, :delete] ->
          match(verb, path, module, action, opts)
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
