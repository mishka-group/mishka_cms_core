# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ContentEditorBlocks do
  @moduledoc """
  Test plugin for `runtime:content:editor_blocks`: adds the blocks a test put under
  `:persistent_term` key `:__content_editor_blocks__` to the ones the editor offers — proving a
  plugin hears the blocks before they are shown and may add its own.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:content:editor_blocks"

  @impl true
  def call(%{blocks: blocks} = data, _meta),
    do: {:reply, %{data | blocks: blocks ++ :persistent_term.get(:__content_editor_blocks__, [])}}

  def call(data, _meta), do: {:reply, data}
end
