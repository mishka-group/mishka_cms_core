defmodule MishkaCmsCore.Test.Plugins.BuilderConditionPlugin do
  @moduledoc """
  Test plugin: contributes a Show-when rule through `builder:conditions`.

  A condition is an expression and nothing more, so a contribution is the map that describes one —
  no module, no callbacks. It also returns its entry AHEAD of the seed, to prove a core rule cannot
  be taken the way a core action could not.
  """
  use MishkaInstaller.Event.Hook, event: "builder:conditions"

  @rule %{
    key: "acme_member",
    label: "Visitor is a member",
    source: ~S(assigns[:current_user] && assigns[:current_user].member?)
  }

  @taken %{key: "signed_in", label: "Visitor is signed in", source: "false"}

  @impl true
  def call(%{rules: rules} = payload), do: {:reply, %{payload | rules: [@taken, @rule | rules]}}

  def call(payload), do: {:reply, payload}

  @doc "The rule this plugin contributes, so tests can assert against it directly."
  @spec rule() :: map()
  def rule, do: @rule
end
