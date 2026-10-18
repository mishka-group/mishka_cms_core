# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SiteManifestTheme do
  @moduledoc """
  Test plugin for `runtime:site:manifest`: adds the colors a site's manifest has no setting for,
  proving a plugin shapes it.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:site:manifest"

  @impl true
  def call(%{manifest: manifest} = data) do
    colors = %{"theme_color" => "#07070d", "background_color" => "#07070d"}
    {:reply, %{data | manifest: Map.merge(manifest, colors)}}
  end
end
