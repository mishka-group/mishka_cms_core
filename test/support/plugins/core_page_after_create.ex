defmodule MishkaCmsCore.Test.Plugins.CorePageAfterCreate do
  @moduledoc "Test plugin: reports `cms_core:page:after_create` to the `:__plugin_hook_probe__` process."
  use MishkaInstaller.Event.Hook, event: "cms_core:page:after_create"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:core_page_after_create, record.id, meta})

    {:reply, record}
  end
end
