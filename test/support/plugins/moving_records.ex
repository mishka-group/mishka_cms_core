# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.MovingRecords do
  @moduledoc """
  Test plugin for `runtime:page:records`: names `test:moving`, a kind whose records move
  (`moves: true`), and `test:still`, one whose records do not. Asked for a site, `test:moving` names
  one sample, `old-post` in English. Reports each call to the `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:page:records"

  @impl true
  def call(%{records: records} = state) do
    if pid = Process.whereis(:__plugin_hook_probe__), do: send(pid, {:records, state.site_id})

    {:reply,
     %{
       state
       | records:
           records ++
             [
               %{
                 id: "test:moving",
                 group: "Test",
                 label: "Moving",
                 captures: ["slug"],
                 moves: true,
                 samples: samples(state.site_id)
               },
               %{id: "test:still", group: "Test", label: "Still", captures: ["slug"]}
             ]
     }}
  end

  defp samples(nil), do: []

  defp samples(_site_id),
    do: [%{label: "Old post", params: %{"slug" => "old-post", "lang" => "en"}}]
end
