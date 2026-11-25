# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderAttrChoicesPlugin do
  @moduledoc """
  Test plugin on `builder:attr:choices`: two products for the source `acme:products` (the second
  given twice), a choice of the wrong shape for `acme:broken`, and a raise for `acme:raise`. Every
  other source gets nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:attr:choices"

  @impl true
  def call(%{source: "acme:products", site_id: site_id} = payload) do
    choices = [
      %{value: "photo-pack", label: "Photo pack (#{site_id})"},
      %{value: "icon-set", label: "Icon set"},
      %{value: "icon-set", label: "Icon set again"}
    ]

    {:reply, %{payload | choices: payload.choices ++ choices}}
  end

  def call(%{source: "acme:broken"} = payload),
    do: {:reply, %{payload | choices: payload.choices ++ [%{value: 1}]}}

  def call(%{source: "acme:raise"}), do: raise("a broken extension")

  def call(payload), do: {:reply, payload}
end
