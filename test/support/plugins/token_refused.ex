defmodule MishkaCmsCore.Test.Plugins.TokenRefused do
  @moduledoc """
  Test plugin for `api:request:token_refused`: reports the refused user and the site to the
  `:__plugin_hook_probe__` process and returns the conn unchanged.
  """
  use MishkaInstaller.Event.Hook, event: "api:request:token_refused"

  @impl true
  def call(conn, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:token_refused, meta[:user_id], meta[:site] && meta[:site].id})

    {:reply, conn}
  end
end
