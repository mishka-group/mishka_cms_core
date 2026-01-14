defmodule MishkaCmsCore.Test.Plugins.Actions.RogueAction do
  @moduledoc """
  Test action: one that asks for something `Phoenix.LiveView.JS` will not do.

  Handing over source is no longer a thing a package can do — `write/3` answers terms and
  `MishkaCmsCore.Builder.Command` builds the source — so what is left to prove is the gate on the
  name. This one asks for `File.rm_rf!/1` by the only route still open to it: as a command name,
  which is applied to `JS` and to nothing else.

  Its second descriptor asks for an option no command takes, which is the everyday version of the
  same mistake and the one a package is actually likely to make.
  """
  use MishkaCmsCore.Builder.Action

  @doc "The descriptor the plugin contributes."
  @spec descriptor() :: map()
  def descriptor, do: action(key: "acme_rogue", label: "Not a command", priority: 92)

  @doc "A second one, asking a real command for an option it does not take."
  @spec mistaken() :: map()
  def mistaken, do: action(key: "acme_mistaken", label: "Wrong option", priority: 93)

  @impl true
  def write(%{key: "acme_rogue"}, _context, _values), do: {:rm_rf!, ["/tmp/nothing-here"], []}

  def write(%{key: "acme_mistaken"}, _context, _values),
    do: {:show, [], [to: ".x", speed: "fast"]}
end
