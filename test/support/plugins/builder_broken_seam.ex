# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderBrokenSeam do
  @moduledoc """
  A plugin that raises, which is the case the editor is judged on.

  A broken extension is its author's problem to fix and must never become the editor's problem to
  survive. MishkaInstaller discards the whole chain when a hook raises and hands back the original
  payload, so the editor keeps the value it already had — asserted rather than assumed.
  """
  use MishkaInstaller.Event.Hook, event: "builder:preset:choices"

  @impl true
  def call(_payload), do: raise("this extension is broken")
end
