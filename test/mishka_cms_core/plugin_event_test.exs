defmodule MishkaCmsCore.PluginEventTest do
  @moduledoc """
  An event whose plugins cannot all run answers the caller with the state it was handed
  (`MishkaCmsCore.PluginEvent.call/3`), and the answer it stands for is told apart from any other
  (`MishkaCmsCore.PluginEvent.cannot_run?/1`).
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.PluginEvent
  alias MishkaCmsCore.Test.EventCannotRun

  @event "plugin_event_test:transform"

  test "an event whose plugins cannot run hands back the state it was given" do
    EventCannotRun.stub!(@event)

    assert {:error, [%{action: :call, field: :event}]} =
             MishkaInstaller.Event.Hook.call(@event, %{n: 1})

    assert PluginEvent.call(@event, %{n: 1}) == %{n: 1}
  end

  test "an event with no plugins answers with its state, as Hook.call/3 does" do
    assert PluginEvent.call("plugin_event_test:nobody_listens", %{n: 1}) == %{n: 1}
  end

  test "cannot_run?/1 is true for that answer alone" do
    assert PluginEvent.cannot_run?(
             {:error, [%{message: "…", action: :call, field: :event, plugins: [Nope]}]}
           )

    refute PluginEvent.cannot_run?({:error, [%{action: :create, field: :name}]})
    refute PluginEvent.cannot_run?({:error, :refused})
    refute PluginEvent.cannot_run?(%{allowed?: false})
    refute PluginEvent.cannot_run?(nil)
  end
end
