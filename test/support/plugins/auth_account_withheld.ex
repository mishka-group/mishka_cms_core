defmodule MishkaCmsCore.Test.Plugins.AuthAccountWithheld do
  @moduledoc """
  Test plugin for `auth:account:withheld`: reports which of an account's relationships were held
  back to the `:__plugin_hook_probe__` process, and lets the read run as it was handed over.
  """
  use MishkaInstaller.Event.Hook, event: "auth:account:withheld"

  @impl true
  def call(query, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:account_withheld, meta[:withheld]})

    {:reply, query}
  end
end
