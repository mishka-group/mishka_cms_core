# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.PageFormBrokenDestination do
  @moduledoc """
  An extension whose submission handler raises, which one written by somebody else eventually will.

  A visitor pressing Send on a published page must not be shown a 500 because a plugin has a bug in
  it. The page carries on and the crash goes to the logs, where the plugin's author can find it.
  """
  use MishkaInstaller.Event.Hook, event: "page:form:submitted", initial: %{priority: 50}

  @impl true
  def call(payload), do: raise("this plugin is broken: #{inspect(payload.form)}")
end
