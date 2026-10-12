defmodule MishkaCmsCore.EventCannotRunTest do
  @moduledoc """
  An event whose plugins cannot all run (`MishkaCmsCore.Test.EventCannotRun.stub!/1`) answers
  `MishkaInstaller.Event.Hook.call/3` with the state it was handed, or with the caller's
  `cannot_run:` answer. An event with no plugins answers with its state.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaInstaller.Event.Hook

  @event "event_cannot_run_test:transform"

  test "an event whose plugins cannot run hands back the state it was given" do
    EventCannotRun.stub!(@event)

    assert Hook.call(@event, %{n: 1}) == %{n: 1}
  end

  test "an event whose plugins cannot run answers the caller's cannot_run: answer" do
    EventCannotRun.stub!(@event)

    assert Hook.call(@event, %{n: 1}, cannot_run: :refused) == :refused
  end

  test "an event with no plugins answers with its state, whatever cannot_run: says" do
    assert Hook.call("event_cannot_run_test:nobody_listens", %{n: 1}, cannot_run: :refused) ==
             %{n: 1}
  end
end
