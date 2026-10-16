# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ContentEditorPalette do
  @moduledoc """
  Test plugin for `runtime:content:editor_palette`: takes every component whose name holds
  `-unlisted-` out of the content editor's palette, and tells a process registered as
  `:__content_editor_palette_probe__` what it heard — proving a plugin hears the palette before it
  is shown and may narrow what an author can place.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:content:editor_palette"

  @impl true
  def call(%{components: components} = data, meta) do
    if pid = Process.whereis(:__content_editor_palette_probe__),
      do: send(pid, {:editor_palette, data.site_id, length(components), meta[:current_user]})

    {:reply, %{data | components: Enum.reject(components, &(&1.name =~ "-unlisted-"))}}
  end

  def call(data, _meta), do: {:reply, data}
end
