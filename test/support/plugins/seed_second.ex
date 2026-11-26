# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SeedSecond do
  @moduledoc """
  A second `installer:seed` plugin, so a test can register two extensions' parts side by side, or
  one an operator switched off. It answers no key, so it never reports.
  """
  use MishkaInstaller.Event.Hook, event: "installer:seed"

  @impl true
  def call(payload), do: {:reply, payload}
end
