# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.OriginValidator do
  @moduledoc """
  Validates origins against sites stored in ETS for WebSocket connections and CORS, and reads the
  host or the address out of what a request or a setting carries (`host_name/1`, `web_url?/1`,
  `site_path?/1`) with `URI.parse/1` rather than by cutting strings.
  """

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
end
