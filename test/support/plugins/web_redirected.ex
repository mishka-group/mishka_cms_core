defmodule MishkaCmsCore.Test.Plugins.WebRedirected do
  @moduledoc """
  Test plugin for `web:request:redirected`: reports what it was told to the `:__plugin_hook_probe__`
  process and sends the visitor to its own address instead, proving a plugin can change the answer.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:redirected"

  @impl true
  def call(conn, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:redirected, meta[:site].id, meta[:from], meta[:to], meta[:status]})

    {:reply, Plug.Conn.put_resp_header(conn, "location", "/chosen-by-a-plugin")}
  end
end
