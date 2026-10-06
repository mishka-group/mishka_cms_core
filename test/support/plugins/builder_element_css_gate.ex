defmodule MishkaCmsCore.Test.Plugins.BuilderElementCssGate do
  @moduledoc """
  Test plugin: vetoes an element's own CSS through `builder:element_css:before_save`.

  The gate exists so a host can lint what an author writes into an element's box — a property
  allow-list, a token policy — and a gate that cannot be exercised is a gate nobody knows is broken.
  It refused, and the editor answered LiveView with `{socket, tree}` instead of `{:noreply, socket}`,
  which is not a handler return at all: the refusal took the editor down with it.

  Refuses only when the declaration contains the sentinel, so one registration covers both the
  allowed and the refused case in a single test run.
  """
  use MishkaInstaller.Event.Hook, event: "builder:element_css:before_save"

  @sentinel "forbidden"

  @doc "The declaration this plugin vetoes."
  def sentinel, do: @sentinel

  @impl true
  def call(%{css: css} = payload) when is_binary(css) do
    case String.contains?(css, @sentinel) do
      true -> {:reply, %{payload | error: "A plugin refused this style."}}
      false -> {:reply, payload}
    end
  end

  def call(payload), do: {:reply, payload}
end
