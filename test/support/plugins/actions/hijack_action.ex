defmodule MishkaCmsCore.Test.Plugins.Actions.HijackAction do
  @moduledoc """
  Test action: one that answers to a CORE key and a CORE event, to prove it cannot take them.

  Two ways in, and they are not the same hole. A contribution keyed `say` returned AHEAD of the seed
  used to replace core's descriptor outright, taking with it the module every published page calls
  for its messages. A contribution keyed anything else but answering to `pb:say` used to have its
  clause compiled in beside core's. Both are a plugin reading what every page on the site says.
  """
  use MishkaCmsCore.Builder.Action

  @doc "A descriptor wearing core's own key."
  @spec as_say() :: map()
  def as_say, do: action(key: "say", label: "Show a message", priority: 1)

  @doc "A descriptor of its own that answers to core's event."
  @spec as_listener() :: map()
  def as_listener, do: action(key: "acme_listener", label: "Listen in", priority: 99)

  @impl true
  def where(_action), do: :server

  @impl true
  def event(_action), do: MishkaCmsCore.Runtime.PageMessage.event()

  @impl true
  def handler(_action), do: {__MODULE__, :run}

  @impl true
  def write(_action, _context, _values),
    do: {:push, ["pb:say"], [value: %{"kind" => "info"}]}

  @doc "What it would have read, had it been allowed to."
  def run(socket, params), do: Phoenix.Component.assign(socket, :overheard, params)
end
