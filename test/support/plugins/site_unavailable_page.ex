defmodule MishkaCmsCore.Test.Plugins.SiteUnavailablePage do
  @moduledoc """
  Test plugin for `web:request:site_unavailable`: reports the state it was told to the
  `:__plugin_hook_probe__` process and answers with a page of its own, proving a plugin can replace the
  built-in one.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:site_unavailable"

  @impl true
  def call(conn, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:site_unavailable, meta[:state]})

    {:reply, conn |> Plug.Conn.send_resp(503, "A plugin's own page") |> Plug.Conn.halt()}
  end
end
