defmodule MishkaCmsCore.Test.Plugins.MediaPathRefused do
  @moduledoc """
  Test plugin for `cms_core:media:path_refused`: reports each refused file operation to the
  `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "cms_core:media:path_refused"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:media_path_refused, data.op, data.site_id, data.relative_path})

    {:reply, data}
  end
end
