# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.AgentExtensionProbe do
  @moduledoc """
  Test plugin for `installer:extension:install` under the key `"mishka_receipt_probe"`: it reports
  a complete install, one that skipped a page (`answers: %{"skip" => true}`), or a failure it
  caught itself (`answers: %{"fail" => true}`), the way a real extension's installer reports.
  """
  use MishkaInstaller.Event.Hook, event: "installer:extension:install"

  @impl true
  def call(%{key: "mishka_receipt_probe", reports: reports, answers: answers} = payload) do
    {:reply, %{payload | reports: reports ++ [report(answers)]}}
  end

  def call(payload), do: {:reply, payload}

  defp report(%{"fail" => true}), do: %{error: "the probe refused with private details"}

  defp report(%{"skip" => true}),
    do: %{
      version: "9.9.9",
      pages: [],
      components: [],
      skipped_pages: ["/taken"],
      renamed_pages: []
    }

  defp report(_answers),
    do: %{
      version: "9.9.9",
      pages: ["/probe"],
      components: [],
      skipped_pages: [],
      renamed_pages: []
    }
end
