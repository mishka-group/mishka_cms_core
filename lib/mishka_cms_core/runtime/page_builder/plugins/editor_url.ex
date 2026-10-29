# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.EditorUrl do
  @moduledoc """
  Answers `runtime:document:editor_url` with the visual editor's address for a document.

  The core asks this event wherever it offers to open the editor — the "+ Add" button of the page,
  layout, component and error-page lists, their "Fill in the form, then open the editor" way, and
  the inspector's Visual Editor link (`MishkaCmsCore.Runtime.PageBuilder.Section.editor_url/3`). It
  spells no address of the editor's itself, so with this plugin absent those buttons are simply
  not drawn.

  A section the editor does not open, or a payload another plugin already answered, passes through
  untouched.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:document:editor_url", initial: %{priority: 50}

  alias MishkaCmsCore.Runtime.PageBuilder.Section

  @impl true
  def call(%{section: section, id: id, status: status, url: nil} = payload) do
    case Section.known?(section) do
      true -> {:reply, %{payload | url: Section.builder_path(section, id, status)}}
      false -> {:reply, payload}
    end
  end

  def call(payload), do: {:reply, payload}
end
