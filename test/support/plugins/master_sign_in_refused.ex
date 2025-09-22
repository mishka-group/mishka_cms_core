defmodule MishkaCmsCore.Test.Plugins.MasterSignInRefused do
  @moduledoc """
  Test plugin for `web:request:master_sign_in_refused`: reports the site that refused the master
  sign-in to the `:__plugin_hook_probe__` process and returns the conn unchanged.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:master_sign_in_refused"

  @impl true
  def call(conn, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:master_sign_in_refused, meta[:site].id})

    {:reply, conn}
  end
end
