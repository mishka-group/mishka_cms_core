# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.Actions.PingAction do
  @moduledoc """
  Test action: a package's SERVER verb — a push out, a handler back.

  It names its own event and its own `{module, function}`, and a page carrying the push gets that
  clause compiled into it by `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler`, with nothing in the
  compiler knowing this package exists.
  """
  use MishkaCmsCore.Builder.Action

  @event "acme:ping"

  @doc "The descriptor the plugin contributes."
  @spec descriptor() :: map()
  def descriptor, do: action(key: "acme_ping", label: "Ping the server", priority: 91)

  @impl true
  def where(_action), do: :server

  @impl true
  def event(_action), do: @event

  @impl true
  def handler(_action), do: {__MODULE__, :run}

  @impl true
  def needs(_action), do: [text("note", "Note", placeholder: "hello")]

  @impl true
  def write(_action, _context, values),
    do: {:push, [@event], [value: %{"note" => values["note"]}]}

  @impl true
  def read(_action, {:push, [@event], [value: %{"note" => note}]}) when is_binary(note),
    do: {:ok, %{"note" => note}}

  def read(_action, _command), do: :no

  @doc "The runtime half: what the compiled page calls when the push arrives."
  def run(socket, params) do
    Phoenix.Component.assign(socket, :acme_ping, params["note"])
  end
end
