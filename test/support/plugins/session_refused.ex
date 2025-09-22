defmodule MishkaCmsCore.Test.Plugins.SessionRefused do
  @moduledoc """
  Test plugin for `web:request:session_refused`: reports the refused user and the site to the
  `:__plugin_hook_probe__` process and returns the conn unchanged.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:session_refused"

  @impl true
  def call(conn, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:session_refused, meta[:user_id], meta[:site].id})

    {:reply, conn}
  end
end
