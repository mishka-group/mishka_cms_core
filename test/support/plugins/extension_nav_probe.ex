# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ExtensionNavProbe do
  @moduledoc """
  Test plugin for `installer:extension:install` under the key `"mishka_nav_probe"`: it reports a
  complete install and writes nothing, so a test sees what the core does with the `nav` its
  registration declares.
  """
  use MishkaInstaller.Event.Hook, event: "installer:extension:install"

  @impl true
  def call(%{key: "mishka_nav_probe", reports: reports} = payload) do
    report = %{version: "1.0.0", pages: [], components: [], skipped_pages: [], renamed_pages: []}
    {:reply, %{payload | reports: reports ++ [report]}}
  end

  def call(payload), do: {:reply, payload}
end
