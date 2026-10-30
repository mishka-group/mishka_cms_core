# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.EditorUrlProbe do
  @moduledoc """
  Test plugin for `runtime:document:editor_url`: an editor that answers every document with an
  address of its own, `/probe-editor/<section>/<id>`, so the core's rules about who is offered that
  address can be tested with no editor installed.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:document:editor_url"

  @impl true
  def call(%{section: section, id: id, url: nil} = payload),
    do: {:reply, %{payload | url: "/probe-editor/#{section}/#{id}"}}

  def call(payload), do: {:reply, payload}
end
