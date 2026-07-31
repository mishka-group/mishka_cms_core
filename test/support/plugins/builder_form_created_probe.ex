defmodule MishkaCmsCore.Test.Plugins.BuilderFormCreatedProbe do
  @moduledoc """
  Test plugin: sends what `builder:form:after_create` announced to the process registered as
  `waiter/0`, and does nothing when none is registered.
  """
  use MishkaInstaller.Event.Hook, event: "builder:form:after_create"

  @waiter :builder_form_created_waiter

  @doc "The name a test registers itself under to receive the announcement."
  @spec waiter() :: atom()
  def waiter, do: @waiter

  @impl MishkaInstaller.Event.Hook
  def call(summary) do
    case Process.whereis(@waiter) do
      nil -> :ok
      waiter -> send(waiter, {__MODULE__, summary})
    end

    {:reply, summary}
  end
end
