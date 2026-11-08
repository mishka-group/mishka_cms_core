# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.WebRedirected do
  @moduledoc """
  Test plugin for `web:request:redirected`: reports the answer it was handed to the
  `:__plugin_hook_probe__` process and changes it, proving a plugin decides what is served: a
  redirect goes to its own address, `/retire` is turned into a 410 and `/let-through` is served
  nothing, so the request goes on to its page.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:redirected"

  @impl true
  def call(answer, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:redirected, meta[:site_id], meta[:path], answer})

    {:reply, changed(answer, meta[:path])}
  end

  defp changed(_answer, "/retire"), do: {:gone, nil, 410}
  defp changed(_answer, "/let-through"), do: nil
  defp changed({:redirect, _to, status}, _path), do: {:redirect, "/chosen-by-a-plugin", status}
  defp changed(answer, _path), do: answer
end
