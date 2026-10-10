defmodule MishkaCmsCore.Test.Plugins.CorePageAfterSave do
  @moduledoc "Test plugin: reports `cms_core:page:after_save` to the `:__plugin_hook_probe__` process."
  use MishkaInstaller.Event.Hook, event: "cms_core:page:after_save"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:core_page_after_save, record.id, record.title, meta})

    {:reply, record}
  end
end
