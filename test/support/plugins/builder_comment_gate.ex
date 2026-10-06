defmodule MishkaCmsCore.Test.Plugins.BuilderCommentGate do
  @moduledoc """
  A house rule on review notes, as an extension would write it: a note that only says "wip" is not a
  note.

  It proves the review composer's gate is binding rather than advisory — the same shape the save
  gate uses, on a different section of the editor.
  """
  use MishkaInstaller.Event.Hook, event: "builder:review:before_comment"

  @refused "wip"

  @doc "The body this plugin refuses."
  @spec refused() :: String.t()
  def refused, do: @refused

  @impl true
  def call(%{body: body} = payload) when is_binary(body) do
    case String.trim(String.downcase(body)) == @refused do
      true -> {:reply, %{payload | error: "Say what needs doing, not that something does."}}
      false -> {:reply, payload}
    end
  end

  def call(payload), do: {:reply, payload}
end
