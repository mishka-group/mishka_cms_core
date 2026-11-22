# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderComponentNotesPlugin do
  @moduledoc """
  Test plugin on `builder:component:notes`: a warning for `acme-product` naming the product its
  `product` attribute points at, a note of the wrong shape for `acme-broken`, and a raise for
  `acme-raise`. Every other component gets nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:component:notes"

  @impl true
  def call(%{component: "acme-product", attrs: %{"product" => product}} = payload) do
    note = %{
      severity: :warning,
      message: "The product #{product} was archived.",
      detail: "Visitors see nothing here."
    }

    {:reply, %{payload | notes: payload.notes ++ [note]}}
  end

  def call(%{component: "acme-broken"} = payload),
    do: {:reply, %{payload | notes: payload.notes ++ [%{severity: :loud, message: 1}]}}

  def call(%{component: "acme-raise"}), do: raise("a broken extension")

  def call(payload), do: {:reply, payload}
end
