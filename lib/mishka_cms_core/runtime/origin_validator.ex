# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.OriginValidator do
  @moduledoc """
  Validates origins against sites stored in ETS for WebSocket connections and CORS.
  """

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
        host
        |> String.split(":")
        |> List.first()
        |> MishkaCmsCore.Runtime.States.SiteState.host_exists?()
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
