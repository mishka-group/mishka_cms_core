defmodule MishkaCmsCore.Test.Plugins.AuthEmailHeld do
  @moduledoc """
  Test plugin for `auth:email:held`: reports the tenant an email was held back for to the
  `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "auth:email:held"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__), do: send(pid, {:email_held, data.tenant})
    {:reply, data}
  end
end
