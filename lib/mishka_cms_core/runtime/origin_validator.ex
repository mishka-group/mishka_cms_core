# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.OriginValidator do
  @moduledoc """
  Validates origins against sites stored in ETS for WebSocket connections and CORS, and reads the
  host or the address out of what a request or a setting carries (`host_name/1`, `web_url?/1`,
  `site_path?/1`) with `URI.parse/1` rather than by cutting strings.

  ## Origins

  A CORS origin is a scheme, a host and a port, held as `t:origin/0`. `request_origin/1` reads the
  one a request's `Origin` header names and `site_origins/1` lists the ones a site allows; both go
  through the same reading, so the two compare as equal or not at all. `serialize/1` writes one back
  the way a browser writes it.
  """

  @typedoc """
  `{scheme, host, port}`: the scheme `"http"` or `"https"`, the host lowercased and without IPv6
  brackets, and the port always written — `https://Site.com` is `{"https", "site.com", 443}`.
  """
  @type origin :: {String.t(), String.t(), 1..65_535}

  @schemes ["http", "https"]
  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @doc """
  Whether `host`, already read out of an address and lowercased, names this machine: `localhost`, a
  name under `.localhost` (RFC 6761), `127.0.0.1` or `::1`. Usable in a guard.

      is_loopback_host("site-a.localhost")    #=> true
      is_loopback_host("evil-localhost.com")  #=> false
      is_loopback_host("localhost.evil.com")  #=> false
  """
  defguard is_loopback_host(host)
           when host in @loopback_hosts or
                  (is_binary(host) and byte_size(host) > 10 and
                     binary_part(host, byte_size(host) - 10, 10) == ".localhost")

  @doc """
  The host a `Host` header names, without its port: `"example.com:4000"` is `"example.com"` and
  `"[::1]:4000"` is `"::1"`. `nil` for a header that names none.
  """
  @spec host_name(String.t() | nil) :: String.t() | nil
  def host_name(header) when is_binary(header) do
    case URI.parse("//" <> header) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _no_host -> nil
    end
  end

  def host_name(_header), do: nil

  @doc """
  Whether `value` is an absolute `http` or `https` address with a host. A bare domain such as
  `"httpbin.example.com"` is not one, whatever its first letters are.
  """
  @spec web_url?(term()) :: boolean()
  def web_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.trim(value) == value

      _not_a_web_address ->
        false
    end
  end

  def web_url?(_value), do: false

  @doc """
  Whether `value` is a path on this site (`"/uploads/a.png"`): one leading slash, so neither a
  protocol-relative address (`"//host/a"`) nor a backslash form a browser reads as one.
  """
  @spec site_path?(term()) :: boolean()
  def site_path?(value) when is_binary(value) do
    String.starts_with?(value, "/") and not String.starts_with?(value, "//") and
      not String.contains?(value, ["\\", "\n", "\r"])
  end

  def site_path?(_value), do: false

  @doc """
  The origin a request's `Origin` header names, or `:error`.

  Only a bare origin is one: an `http` or `https` scheme, a host and an optional port from 1 to
  65535, with no path, query, fragment or credentials. `null`, a malformed value and a port that is
  not a number are `:error`.

      request_origin("HTTPS://Site.com")       #=> {:ok, {"https", "site.com", 443}}
      request_origin("http://[::1]:3000")      #=> {:ok, {"http", "::1", 3000}}
      request_origin("https://site.com/path")  #=> :error
      request_origin("null")                   #=> :error
  """
  @spec request_origin(term()) :: {:ok, origin()} | :error
  def request_origin(value) when is_binary(value), do: value |> URI.parse() |> origin()
  def request_origin(_value), do: :error

  @doc """
  Every origin `site` allows, read from its `:host`, `:frontend_domain` and `:allowed_origins`:

    * `host` is a domain, allowed as `https://<host>` on port 443. A loopback host (see
      `is_loopback_host/1`) is also allowed as `http://<host>` on port 80.
    * `frontend_domain` written as an origin (`https://app.example.com:8443`) is that origin. Written
      as a bare domain (`app.example.com`, `app.example.com:3000`) it is read as `host` is, on the
      port it writes.
    * each entry of `allowed_origins` is the origin it writes, on the scheme's own port when it
      writes none. What follows the host and port is ignored, so `https://partner.com/` is
      `https://partner.com`.

  A value that is none of these allows nothing.
  """
  @spec site_origins(map()) :: [origin()]
  def site_origins(site) when is_map(site) do
    declared =
      site |> Map.get(:allowed_origins) |> List.wrap() |> Enum.flat_map(&written_origin/1)

    Enum.uniq(
      domain_origins(Map.get(site, :host)) ++
        domain_origins(Map.get(site, :frontend_domain)) ++ declared
    )
  end

  @doc """
  `origin` written the way a browser writes it in an `Origin` header: no port when it is the
  scheme's own, and an IPv6 host in brackets.

      serialize({"https", "site.com", 443})  #=> "https://site.com"
      serialize({"http", "::1", 3000})       #=> "http://[::1]:3000"
  """
  @spec serialize(origin()) :: String.t()
  def serialize({scheme, host, port}) do
    case default_port(scheme) == port do
      true -> scheme <> "://" <> bracket(host)
      false -> scheme <> "://" <> bracket(host) <> ":" <> Integer.to_string(port)
    end
  end

  def verify_origin?(nil), do: false

  def verify_origin?(%URI{host: nil}), do: false

  def verify_origin?(%URI{host: host}) do
    cond do
      Application.get_env(:mishka_cms_core, :env_test?, false) ->
        true

      Application.get_env(:mishka_cms_core, :env_dev?, false) ->
        true

      # While the CMS is uninstalled, the only reachable page is the installer (the gate redirects
      # everything to /install) and there is no site to validate against — so allow the connect.
      !MishkaCmsCore.Install.installed?() ->
        true

      true ->
        MishkaCmsCore.Runtime.States.SiteState.host_exists?(host)
    end
  end

  def verify_origin?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{host: nil} -> false
      uri -> verify_origin?(uri)
    end
  end

  def verify_origin?(_), do: false

  # THE ONE READING BOTH SIDES GO THROUGH: a request's `Origin` and every address a site allows
  # become `{scheme, host, port}` here and nowhere else. `URI.parse/1` falls back to the scheme's
  # port for text it cannot read as one (`:abc`), so the authority has to be exactly the host and
  # port it was read as. The host holds only what a host name or an IP address holds, so what
  # `serialize/1` writes into a response header is never more than that.
  defp origin(%URI{
         scheme: scheme,
         host: host,
         port: port,
         authority: authority,
         userinfo: nil,
         path: path,
         query: nil,
         fragment: nil
       })
       when scheme in @schemes and is_binary(host) and host != "" and is_binary(authority) and
              port in 1..65_535 and path in [nil, ""] do
    host = String.downcase(host)
    written = [bracket(host), bracket(host) <> ":" <> Integer.to_string(port)]

    case host_characters?(host) and String.downcase(authority) in written do
      true -> {:ok, {scheme, host, port}}
      false -> :error
    end
  end

  defp origin(_uri), do: :error

  # A site's `host` or `frontend_domain`: a domain, `domain:port`, or a whole origin.
  defp domain_origins(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in @schemes and is_binary(host) ->
        written_origin(value)

      _bare_domain ->
        bare_origins(URI.parse("//" <> value))
    end
  end

  defp domain_origins(_value), do: []

  defp bare_origins(%URI{host: host} = uri) when is_binary(host) do
    schemes =
      case String.downcase(host) do
        loopback when is_loopback_host(loopback) -> ["https", "http"]
        _host -> ["https"]
      end

    for scheme <- schemes,
        {:ok, origin} <- [
          origin(%URI{uri | scheme: scheme, port: uri.port || default_port(scheme)})
        ],
        do: origin
  end

  defp bare_origins(_uri), do: []

  defp written_origin(value) when is_binary(value) do
    uri = value |> String.trim() |> URI.parse()

    case origin(%URI{uri | path: nil, query: nil, fragment: nil}) do
      {:ok, origin} -> [origin]
      :error -> []
    end
  end

  defp written_origin(_value), do: []

  defp host_characters?(<<>>), do: true

  defp host_characters?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?0..?9 or char in [?., ?-, ?_, ?:],
       do: host_characters?(rest)

  defp host_characters?(_host), do: false

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80

  defp bracket(host), do: if(String.contains?(host, ":"), do: "[" <> host <> "]", else: host)
end
