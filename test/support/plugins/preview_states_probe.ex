# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.PreviewStatesProbe do
  @moduledoc """
  Test plugin for `runtime:page:preview_states`: names states for the pages whose `extra` holds
  `"role" => "confirm"`, one of them whole and the rest each wrong in one way, and hands every other
  page back untouched.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:page:preview_states"

  @impl true
  def call(%{page: %{extra: %{"role" => "confirm"}}, states: states} = given) do
    {:reply,
     %{
       given
       | states:
           states ++
             [
               %{
                 id: "confirmed",
                 label: "Confirmed",
                 params: %{"state" => "confirmed", "token" => "real", "count" => 2}
               },
               %{id: "no-label", params: %{"state" => "x"}},
               %{id: "", label: "No id", params: %{}},
               %{id: "no-params", label: "No params"}
             ]
     }}
  end

  def call(given), do: {:reply, given}
end
