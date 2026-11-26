# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.DevSeedSecond do
  @moduledoc """
  A second `dev:seed` plugin, so a test can register two extensions' seeds side by side, or one an
  operator switched off. It answers no key, so it never reports.
  """
  use MishkaInstaller.Event.Hook, event: "dev:seed"

  @impl true
  def call(payload), do: {:reply, payload}
end
