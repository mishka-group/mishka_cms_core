defmodule MishkaCmsCore.Test.Plugins.SettingsAfterChangeProbe do
  @moduledoc """
  Test plugin for the `cms_core:setting:after_master_set` event — the hook the `Setting` resource
  emits through its `PluginHook` notifier on every `Settings.put` (the façade writes via the
  `:master_set` upsert). Opts into the read-only `meta` context with `call/2` and reports the changed
  record to the `:__settings_probe__` test process, proving extensions/plugins are notified the same
  way every other resource notifies them.
  """
  use MishkaInstaller.Event.Hook, event: "cms_core:setting:after_master_set"

  @impl true
  def call(setting, meta) do
    if pid = Process.whereis(:__settings_probe__),
      do: send(pid, {:settings_after_change, setting, meta})

    {:reply, setting}
  end
end
