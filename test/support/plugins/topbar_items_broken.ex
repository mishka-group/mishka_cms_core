# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.TopbarItemsBroken do
  @moduledoc """
  Test plugin on `topbar:items` that raises, proving a broken plugin leaves the top bar without
  items and the admin page still opens.
  """
  use MishkaInstaller.Event.Hook, event: "topbar:items"

  @impl true
  def call(_data), do: raise("topbar plugin is broken")
end
