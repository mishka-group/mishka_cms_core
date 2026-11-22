# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SidebarStatusCardProbe do
  @moduledoc """
  Test plugin on `sidebar:status:card`: puts the title a test put in
  `Application.put_env(:mishka_cms_core, :sidebar_status_card_title, title)` on the card, hides the
  card when the test put `:hide`, and leaves it as it came when the test put nothing.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:status:card"

  @impl true
  def call(%{card: card} = data) do
    case Application.get_env(:mishka_cms_core, :sidebar_status_card_title) do
      nil -> {:reply, data}
      :hide -> {:reply, %{data | card: nil}}
      title when is_map(card) -> {:reply, %{data | card: %{card | title: title}}}
      _title -> {:reply, data}
    end
  end
end
