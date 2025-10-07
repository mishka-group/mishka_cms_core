defmodule MishkaCmsCore.Test.Plugins.ViewerStateChanged do
  @moduledoc """
  Test plugin for `runtime:state:viewer:changed`: reports each write and drop to the
  `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:state:viewer:changed"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:viewer_changed, data.op, data.key})

    {:reply, data}
  end
end
