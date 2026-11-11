# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.HealthPlug do
  @moduledoc """
  Answers `GET /_health` (and `HEAD`) with whether this node is ready to serve its sites, for a
  deploy's health check: a proxy that sends visitors to a new container only once it answers 200
  keeps them on the old one while the new one is still warming up.

  It is ready when, in this order:

    1. the boot is done (`MishkaCmsCore.Runtime.Handlers.BootHandler.get_status/0` is `:ready`):
       every site is loaded and every precompiled page, layout, component and error page is built;
    2. every active site in `MishkaCmsCore.Runtime.States.SiteState` has its CSS and its JS bundle in
       `MishkaCmsCore.Runtime.States.AssetsState`, the bundles the boot queued;
    3. every plugin on the `runtime:health:ready` event answers `:ok`;
    4. the repo answers `SELECT 1`.

  Ready is `200` with `ok`; anything else is `503` with a short reason, such as `booting`,
  `boot failed`, `building assets: blog css` or `database unavailable`. Both are plain text with
  `cache-control: no-store`. The checks read the caches the boot fills, so a probe costs ETS reads
  and one `SELECT 1`. A bundle whose build failed keeps the node at 503 and names the failure, so a
  release that cannot build a site's CSS never takes its traffic.

  The answer does not depend on the `Host` header, the scheme or a site, so mount it in the endpoint
  before anything that does, such as the site lookup and the session:

      defmodule MyAppWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :my_app

        plug MishkaCmsCore.Runtime.Plugs.HealthPlug
        # ... sockets, static files, parsers, session, router
      end

  Phoenix runs `force_ssl` before the endpoint's first plug, and it leaves `localhost` and
  `127.0.0.1` alone, so a probe inside the container (`curl http://localhost:4000/_health`) reaches
  it as it is. To answer plain http on any host too, exclude the path:

      config :my_app, MyAppWeb.Endpoint,
        force_ssl: [
          rewrite_on: [:x_forwarded_proto],
          host: nil,
          exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/_health"]]
        ]

  `_health` is one of `MishkaCmsCore.ExtensionRouter.host_prefixes/0`, so no extension route takes
  it.

  ## Holding readiness from an extension

  An extension that warms something of its own at boot holds the node at 503 with a plugin on
  `runtime:health:ready`. It is handed `:ok`, and answers `:ok` when ready, or `{:error, reason}`,
  where `reason` is the short text the probe shows; a plugin handed an `{:error, _}` passes it on.
  The check runs on every probe, so it reads state and does no work:

      defmodule MyExtension.Plugins.SearchIndexReady do
        use MishkaInstaller.Event.Hook, event: "runtime:health:ready"

        def call(:ok) do
          if MyExtension.SearchIndex.loaded?(),
            do: {:reply, :ok},
            else: {:reply, :halt, {:error, "search index loading"}}
        end

        def call(error), do: {:reply, error}
      end

  A plugin that raises answers `{:error, "extension check failed"}`.
  """
  @behaviour Plug

  import Plug.Conn

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.Hook

  @bundles ~w(css js)
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["_health"], method: method} = conn, _opts)
      when method in ["GET", "HEAD"] do
    {status, body} =
      case check() do
        :ok -> {200, "ok"}
        {:error, reason} -> {503, reason}
      end

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  @doc """
  Whether this node is ready to serve its sites: `:ok`, or `{:error, reason}` with the first check
  that is not, in the order the moduledoc lists them.
  """
  @spec check() :: :ok | {:error, String.t()}
  def check do
    with :ok <- boot(),
         :ok <- bundles(),
         :ok <- extensions() do
      repo()
    end
  end

  defp boot do
    case BootHandler.get_status() do
      :ready -> :ok
      :initializing -> {:error, "booting"}
      {:failed, _reason} -> {:error, "boot failed"}
    end
  end

  defp bundles do
    missing =
      for %{name: site} <- SiteState.get_active_sites(),
          type <- @bundles,
          not AssetsState.exists?(site, type),
          do: missing(site, type)

    case missing do
      [] -> :ok
      missing -> {:error, "building assets: " <> Enum.join(missing, ", ")}
    end
  end

  defp missing(site, type) do
    case Helpers.asset_build_failure(site, type) do
      nil -> "#{site} #{type}"
      _failure -> "#{site} #{type} failed"
    end
  end

  defp extensions do
    case Hook.call("runtime:health:ready", :ok, raised: {:error, "extension check failed"}) do
      :ok -> :ok
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "extension check failed"}
    end
  end

  defp repo do
    case Ecto.Adapters.SQL.query(@repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, "database unavailable"}
    end
  rescue
    _error -> {:error, "database unavailable"}
  catch
    :exit, _reason -> {:error, "database unavailable"}
  end
end
