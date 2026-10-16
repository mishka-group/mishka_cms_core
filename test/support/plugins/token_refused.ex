# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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
