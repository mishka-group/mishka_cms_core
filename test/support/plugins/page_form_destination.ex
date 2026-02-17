defmodule MishkaCmsCore.Test.Plugins.PageFormDestination do
  @moduledoc """
  An extension that stores what a visitor submitted.

  It exists to prove the `page:form:submitted` seam actually round-trips: a plugin's `handled: true`
  has to come back out of `MishkaInstaller.Event.Hook.call/3`, or a page can never tell a submission
  that was stored from one that fell on the floor.

  A hook runs inline in the process that fired it, so the payload is sent to `self()` and a test
  that calls `PageForm` directly reads it with `assert_received/1`. A test whose submission runs in
  a page's own LiveView process registers itself as `probe/0` and reads it with `assert_receive/1`.
  """
  use MishkaInstaller.Event.Hook, event: "page:form:submitted", initial: %{priority: 50}

  @probe :page_form_submitted_probe

  @doc "The name a test registers to receive submissions made in another process."
  def probe, do: @probe

  @impl true
  def call(payload) do
    send(self(), {:page_form_submitted, payload})
    forward(Process.whereis(@probe), payload)
    {:reply, Map.put(payload, :handled, true)}
  end

  defp forward(pid, payload) when is_pid(pid) and pid != self(),
    do: send(pid, {:page_form_submitted, payload})

  defp forward(_nobody_or_self, _payload), do: :ok
end
