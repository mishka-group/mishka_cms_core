defmodule MishkaCmsCore.Test.Plugins.NoTenantRefused do
  @moduledoc """
  Test plugin for `api:request:no_tenant_refused`: reports the site that ignored the master accounts'
  switch to the `:__plugin_hook_probe__` process and returns the conn unchanged.
  """
  use MishkaInstaller.Event.Hook, event: "api:request:no_tenant_refused"

  @impl true
  def call(conn, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:no_tenant_refused, meta[:site].id})

    {:reply, conn}
  end
end
