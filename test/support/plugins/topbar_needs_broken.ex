# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.TopbarNeedsBroken do
  @moduledoc """
  Test plugin on `topbar:needs` that raises, proving a broken plugin leaves the bell with the core's
  own item and the admin page still opens.
  """
  use MishkaInstaller.Event.Hook, event: "topbar:needs"

  @impl true
  def call(_data), do: raise("needs plugin is broken")
end
