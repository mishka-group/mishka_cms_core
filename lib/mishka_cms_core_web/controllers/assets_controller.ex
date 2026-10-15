defmodule MishkaCmsCoreWeb.AssetsController do
  @moduledoc """
  High-performance asset delivery controller for CSS and JavaScript resources.

  Provides optimized asset serving with intelligent compression selection,
  aggressive caching strategies, and multi-site support. Designed for
  production-grade performance with minimal latency and maximum throughput.

  ## Key Features

  - **Multi-site Asset Management**: Site-specific asset delivery and isolation
  - **Intelligent Compression**: Automatic Brotli/Gzip selection based on client capabilities
  - **Aggressive Caching**: Long-term browser caching with immutable cache directives
  - **CSRF Protection**: Automatic CSRF bypass for JavaScript assets
  - **Graceful Fallbacks**: Custom error handling with informative fallback content
  - **Optimal Headers**: Production-optimized HTTP headers for performance

  ## Asset Types Supported

  - **CSS Assets**: Stylesheets with appropriate content-type headers
  - **JavaScript Assets**: Scripts with CSRF protection disabled

  ## Compression Strategy

  The controller implements intelligent compression selection:
  1. **Brotli**: Preferred compression for modern browsers (highest efficiency)
  2. **Gzip**: Fallback compression for broader browser support
  3. **Uncompressed**: Raw assets for clients without compression support

  ## Who gets a bundle

  A bundle is answered only at its current hash, and only to whom may see its site, read from ETS:

    * on the address of its own site: anyone while the site is up; while it is offline, its
      stylesheet to anyone, since the offline page its visitors get links it, and its script to its
      admins and the masters;
    * on any other address: a master, as the page builder's canvas asks for it, and whoever holds
      a preview link of that site (`?preview=<token>`), by the same rule as its own address;
    * the content editor's stylesheet for a site (`MishkaCmsCore.Runtime.ContentEditorStyles`): a
      master, and an admin of that site;
    * `__shared_base__`, the base every site's bundle starts with: anyone.

  Anything else — a stale or unknown hash, another site's bundle, a site that is down — is a 404
  that no cache keeps. A plugin on `web:request:asset_unavailable` hears it first, with
  `%{site: site_name, type: "css" | "js", reason: reason}` as its meta, and may answer instead by
  halting the conn.

  ## Caching Strategy

  The URL carries the bundle's hash, so a bundle never changes at a given URL, and no answer sends
  the session cookie:
  - **Site up**: `public, max-age=31536000, immutable`
  - **Site down, to its admins or a master, or its stylesheet while it is offline**:
    `private, max-age=31536000, immutable`

  ## Usage Examples

  ### CSS Asset Delivery
  ```
  GET /assets/css/mysite
  Accept-Encoding: br, gzip, deflate

  Response:
  Content-Type: text/css
  Content-Encoding: br
  Cache-Control: public, max-age=31536000, immutable
  ```

  ### JavaScript Asset Delivery
  ```
  GET /assets/js/mysite
  Accept-Encoding: gzip, deflate

  Response:
  Content-Type: text/javascript
  Content-Encoding: gzip
  Cache-Control: public, max-age=31536000, immutable
  ```

  ## Route Integration

  Registered via `MishkaCmsCoreWeb.Routes` under the `:public` extension route type:

      def routes(:public) do
        [
          {:get, "/assets/css/:site/:hash", MishkaCmsCoreWeb.AssetsController, :css},
          {:get, "/assets/js/:site/:hash", MishkaCmsCoreWeb.AssetsController, :js}
        ]
      end

  ## Asset Storage Integration

  Integrates with `MishkaCmsCore.Runtime.States.AssetsState` for:
  - Site-specific asset retrieval
  - Compressed asset variants (brotli_css, gzip_css, brotli_js, gzip_js)
  - Raw asset fallbacks
  - High-performance ETS-based lookups

  ## Error Handling

  A missing bundle, or a hash that is not the current one, is a 404 with `cache-control: no-store`.
  A missing compressed variant falls back to the uncompressed bundle.

  ## Performance Optimizations

  - **Zero Database Queries**: Direct ETS state access
  - **Minimal Processing**: Streamlined request handling
  - **Header Optimization**: Production-tuned response headers
  - **Compression Selection**: Client-optimized encoding selection

  ## Security Considerations

  - **CSRF Protection**: Automatically disabled for JavaScript assets
  - **Site Isolation**: Assets scoped to requesting site
  - **Content-Type Validation**: Proper MIME types for asset security
  - **Cache Security**: Immutable caching prevents cache poisoning

  ## CDN Integration

  Optimized for CDN deployment:
  - Long-term caching headers for edge caching
  - Immutable directive for aggressive caching
  - Optional CORS headers for cross-domain assets (commented)

  ## Production Considerations

  - Monitor asset hit rates and cache performance
  - Implement asset versioning for cache invalidation
  - Consider CDN integration for global distribution
  - Monitor compression ratios and client capabilities
  - Implement asset preloading strategies
  - Consider HTTP/2 server push for critical assets

  ## Multi-site Architecture

  Assets are isolated per site:
  - Site parameter determines asset scope
  - Independent asset compilation per site
  - Site-specific fallback messages
  - Tenant-isolated asset storage

  ## Extension Points

  The controller includes commented extension points for:
  - CORS header configuration for external assets
  - Additional asset types (fonts, images, etc.)
  - Custom compression algorithms
  - Asset fingerprinting and versioning
  """
  use Phoenix.Controller, formats: [:html, :json]
  import Plug.Conn
  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.{ContentEditorStyles, DraftPreviewAssets, SiteAvailability}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaInstaller.Event.Hook

  @shared_base "__shared_base__"
  @public "public, max-age=31536000, immutable"
  @private "private, max-age=31536000, immutable"

  plug :keep_session_unwritten

  def css(conn, params), do: serve(conn, params, "css")

  def js(conn, params),
    do: put_private(conn, :plug_skip_csrf_protection, true) |> serve(params, "js")

  # The viewer is read off the session, which a bundle never changes, so no answer sends the cookie.
  defp keep_session_unwritten(conn, _opts), do: configure_session(conn, ignore: true)

  defp serve(conn, %{"site" => site, "hash" => hash}, type) do
    case access(conn, site, type, Path.rootname(hash)) do
      {:ok, cache_control} -> send_bundle(conn, site, type, cache_control)
      {:error, reason} -> refuse(conn, site, type, reason)
    end
  end

  defp access(conn, site, type, hash) do
    case AssetsState.get!(site, type) do
      %{hash: ^hash, value: value} when is_binary(value) and value != "" ->
        audience(conn, site, type)

      _missing_or_stale ->
        {:error, :missing}
    end
  end

  defp audience(_conn, @shared_base, _type), do: {:ok, @public}

  defp audience(conn, site, type) do
    viewer = conn.assigns[:current_user]

    cond do
      match?(%{name: ^site}, conn.assigns[:current_site]) ->
        by_state(cached_site_id(site), viewer, type)

      Helper.master_admin?(viewer, :dashboard) ->
        {:ok, @private}

      editor_admin?(site, viewer) ->
        {:ok, @private}

      true ->
        preview(conn.params["preview"], cached_site_id(site), viewer, type)
    end
  end

  # The content editor's stylesheet for a site (`ContentEditorStyles`), to an admin of that site.
  defp editor_admin?(id, viewer) do
    case ContentEditorStyles.site_of(id) do
      {:ok, site_id} -> Helper.site_admin?(viewer, site_id, :dashboard)
      :error -> false
    end
  end

  # A preview link of this site, by the same rule as its own address.
  defp preview(token, site_id, viewer, type) when is_binary(site_id) do
    case DraftPreviewAssets.site(token) do
      {:ok, ^site_id} ->
        with {:ok, _cache} <- by_state(site_id, viewer, type), do: {:ok, @private}

      _another_site_or_none ->
        {:error, :address}
    end
  end

  defp preview(_token, _not_cached, _viewer, _type), do: {:error, :address}

  defp by_state(site_id, viewer, type) do
    case SiteAvailability.state(site_id) do
      :open ->
        {:ok, @public}

      # The offline page an offline site shows its visitors links this stylesheet.
      :offline when type == "css" ->
        {:ok, @private}

      state ->
        if SiteAvailability.allowed_in?(state, site_id, viewer),
          do: {:ok, @private},
          else: {:error, state}
    end
  end

  defp cached_site_id(site) do
    case SiteState.get_by_name(site) do
      {:ok, %{id: site_id}} -> site_id
      _not_cached -> nil
    end
  end

  defp refuse(conn, site, type, reason) do
    conn =
      Hook.call("web:request:asset_unavailable", conn,
        meta: %{site: site, type: type, reason: reason}
      )

    if conn.halted,
      do: conn,
      else: conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "") |> halt()
  end

  defp send_bundle(conn, site, type, cache_control) do
    :telemetry.span(
      [:mishka_cms, :assets, :serve],
      %{site: site, asset_type: type},
      fn ->
        conn =
          %{conn: conn, site: site, type: type}
          |> then(&Hook.call("AssetsController.Serve.BeforeServe", &1))
          |> Map.get(:conn)

        accepted =
          conn |> get_req_header("accept-encoding") |> List.first("") |> String.downcase()

        {encoding, key} =
          cond do
            accepted =~ "br" -> {"br", "brotli_#{type}"}
            accepted =~ "gzip" -> {"gzip", "gzip_#{type}"}
            true -> {nil, type}
          end

        %{content: content, encoding: encoding} =
          %{site: site, key: key, type: type, encoding: encoding}
          |> then(&Hook.call("AssetsController.Serve.BeforeAssetLookup", &1))
          |> then(fn data ->
            {get_asset, encoding} =
              case AssetsState.get_value(data.site, data.key) do
                nil -> {AssetsState.get_value(data.site, data.type), nil}
                found -> {found, data.encoding}
              end

            :telemetry.execute(
              [:mishka_cms, :assets, if(get_asset, do: :cache_hit, else: :cache_miss)],
              %{count: 1, size: if(get_asset, do: byte_size(get_asset), else: 0)},
              %{site: data.site, asset_type: data.type, key: data.key}
            )

            %{content: get_asset, encoding: encoding}
          end)
          |> then(&Hook.call("AssetsController.Serve.AfterAssetLookup", &1))

        result =
          %{
            conn: conn,
            content: content,
            encoding: encoding,
            type: type,
            headers: %{
              "content-type" => if(type == "css", do: "text/css", else: "text/javascript"),
              "cache-control" => cache_control
            }
          }
          |> then(&Hook.call("AssetsController.Serve.BeforeResponse", &1))
          |> then(fn
            %{content: nil} = data ->
              refuse(data.conn, site, type, :missing)

            data ->
              data.conn
              |> put_resp_header("content-type", data.headers["content-type"])
              |> then(
                &if(data.encoding,
                  do: put_resp_header(&1, "content-encoding", data.encoding),
                  else: &1
                )
              )
              |> put_resp_header("cache-control", data.headers["cache-control"])
              # If you have external assets, you can add them here or BeforeResponse events plugins
              # |> then(
              #   &if(type == "css", do: put_resp_header(&1, "access-control-allow-origin", "*"), else: &1)
              # )
              |> send_resp(200, data.content)
          end)

        {result, %{}}
      end
    )
  end
end
