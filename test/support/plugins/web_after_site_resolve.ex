# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.WebAfterSiteResolve do
  @moduledoc """
  Test plugin for the infra request seam `web:request:after_site_resolve` (SiteLookupPlug) — reports to
  the `:__plugin_hook_probe__` process and returns the conn unchanged, proving an infra (non-resource)
  hook dispatches to a plugin.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:after_site_resolve"

  @impl true
  def call(conn, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__), do: send(pid, {:web_after_site_resolve})
    {:reply, conn}
  end
end
