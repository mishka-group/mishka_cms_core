# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.PageMoved do
  @moduledoc """
  Test plugin for `runtime:page:moved`: reports what it was asked to the `:__plugin_hook_probe__`
  process. The record `old-post` lives at `/posts/new-post` now; `same` answers its own address,
  `elsewhere` a host that is not the site's, and every other slug stays where it was asked.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:page:moved"

  @impl true
  def call(answer, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:moved, meta[:record], meta[:params], meta[:path]})

    {:reply, moved(answer, meta[:params]["slug"])}
  end

  defp moved(_answer, "old-post"), do: {"/posts/new-post", 301}
  defp moved(_answer, "temporary"), do: {"/posts/new-post", 302}
  defp moved(_answer, "same"), do: {"/posts/same", 301}
  defp moved(_answer, "elsewhere"), do: {"//evil.com", 301}
  defp moved(answer, _stays), do: answer
end
