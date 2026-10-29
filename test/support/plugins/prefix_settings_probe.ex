# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.PrefixSettingsProbe do
  @moduledoc """
  Test plugin for `settings:register`: gates every `acme.` key with one prefix definition, a
  deeper `acme.deep.` with another, and names one key under them exactly — as an extension gates
  the keys it writes for itself without declaring each one.
  """
  use MishkaInstaller.Event.Hook, event: "settings:register"

  alias MishkaCmsCore.Settings

  @doc "What writing an `acme.` key takes."
  @spec prefix_permission() :: String.t()
  def prefix_permission, do: "admin:dashboard:probe:acme"

  @doc "What writing an `acme.deep.` key takes."
  @spec deep_permission() :: String.t()
  def deep_permission, do: "admin:dashboard:probe:acme_deep"

  @doc "What writing `acme.exact` takes."
  @spec exact_permission() :: String.t()
  def exact_permission, do: "admin:dashboard:probe:acme_exact"

  @impl true
  def call(%{definitions: definitions} = data) do
    contributed = [
      Settings.define("acme.", :string,
        match: :prefix,
        permission: [prefix_permission()],
        source: :plugin
      ),
      Settings.define("acme.deep.", :string,
        match: :prefix,
        permission: [deep_permission()],
        source: :plugin
      ),
      Settings.define("acme.exact", :boolean,
        default: false,
        category: "acme_probe",
        permission: exact_permission(),
        source: :plugin
      )
    ]

    {:reply, %{data | definitions: definitions ++ contributed}}
  end
end
