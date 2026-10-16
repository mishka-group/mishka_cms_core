# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.LanguageDeleteRefused do
  @moduledoc """
  Test plugin for `runtime:language:delete_refused`: reports each original refused for its live
  translations to the `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:language:delete_refused"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do:
        send(
          pid,
          {:language_delete_refused, data.id, data.site_id, data.translations, data.message}
        )

    {:reply, data}
  end
end
