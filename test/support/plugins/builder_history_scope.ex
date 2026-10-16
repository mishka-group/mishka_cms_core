# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderHistoryScope do
  @moduledoc """
  A plugin that narrows the editor's timeline — an integration that writes a great many rows and
  would rather not drown the person reading it, or a compliance extension that must hide some.

  It scopes the read rather than the loaded rows, because the sheet pages: dropping rows afterwards
  leaves a page of twenty showing twelve, with no way to ask for the missing eight.
  """
  use MishkaInstaller.Event.Hook, event: "builder:history:query"

  require Ash.Query

  @impl true
  def call(%{query: %Ash.Query{} = query} = payload),
    do: {:reply, %{payload | query: Ash.Query.filter(query, kind != :ai)}}

  def call(payload), do: {:reply, payload}
end
