# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.HeadCodeOrigins do
  @moduledoc """
  Test plugin for `runtime:page:head_origins`: declares an origin of its own and one that is not an
  origin, proving a plugin opens the policy up front and only with a real origin.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:page:head_origins"

  @impl true
  def call(%{origins: origins} = entry),
    do: {:reply, %{entry | origins: origins ++ ["https://ext.example", "javascript:x"]}}
end
