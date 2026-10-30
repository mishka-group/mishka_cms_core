# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ProvisionSnippetRefused do
  @moduledoc """
  Test plugin for `runtime:provision:snippets`: an editor whose write of the snippet was refused,
  answering with the reason in `error`, as the seam asks, instead of raising.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:provision:snippets"

  @impl true
  def call(payload), do: {:reply, %{payload | error: :refused_by_the_probe}}
end
