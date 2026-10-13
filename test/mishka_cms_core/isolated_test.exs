defmodule MishkaCmsCore.IsolatedTest do
  @moduledoc """
  `MishkaCmsCore.Isolated.run/4`: a function run in a peer BEAM of its own, whose crash, exception
  or delay comes back as `{:error, reason}` while the caller goes on.
  """
  use ExUnit.Case, async: true

  # A peer that crashes is meant to: its own processes report it.
  @moduletag :capture_log

  alias MishkaCmsCore.Isolated

  test "answers what the function returned" do
    assert Isolated.run(String, :upcase, ["mishka"]) == {:ok, "MISHKA"}
  end

  test "runs the caller's own code, from its code path" do
    assert {:ok, %URI{host: "mishka.tools"}} =
             Isolated.run(URI, :parse, ["https://mishka.tools/blog"])

    assert {:ok, "MishkaCmsCore.Isolated"} =
             Isolated.run(Kernel, :inspect, [MishkaCmsCore.Isolated])
  end

  test "a function that raises is an error, and the caller goes on" do
    assert {:error, {:badarg, [_ | _]}} =
             Isolated.run(String, :to_integer, ["not a number"])

    assert Process.alive?(self())
  end

  test "a peer that dies whole is an error, and the caller goes on" do
    assert {:error, _reason} = Isolated.run(:erlang, :halt, [139])
    assert Isolated.run(String, :upcase, ["after"]) == {:ok, "AFTER"}
  end

  test "past the timeout the peer is stopped and the answer is a timeout" do
    assert Isolated.run(Process, :sleep, [5_000], timeout: 500) == {:error, :timeout}
  end

  test "the peer has the environment it is given, and not what it is told to drop" do
    System.put_env("MISHKA_ISOLATED_DROPPED", "yes")

    assert Isolated.run(System, :get_env, ["MISHKA_ISOLATED_GIVEN"],
             env: [{~c"MISHKA_ISOLATED_GIVEN", ~c"given"}]
           ) == {:ok, "given"}

    assert Isolated.run(System, :get_env, ["MISHKA_ISOLATED_DROPPED"],
             env: [{~c"MISHKA_ISOLATED_DROPPED", false}]
           ) == {:ok, nil}
  after
    System.delete_env("MISHKA_ISOLATED_DROPPED")
  end

  test "with nice, the peer runs that much below the caller's priority" do
    caller = niceness(:os.cmd(~c"ps -o nice= -p $$"))

    assert {:ok, peer} = Isolated.run(:os, :cmd, [~c"ps -o nice= -p $$"], nice: 10)
    assert niceness(peer) == min(caller + 10, 19)

    assert {:ok, same} = Isolated.run(:os, :cmd, [~c"ps -o nice= -p $$"])
    assert niceness(same) == caller
  end

  test "without nice, or with 0, the peer is started as erl itself" do
    assert Isolated.exec(0) == Isolated.erl()
    assert {nice, [~c"-n", ~c"5", erl]} = Isolated.exec(5)
    assert List.to_string(nice) in ["/usr/bin/nice", "/bin/nice"]
    assert erl == Isolated.erl()
  end

  test "starts the Erlang of the caller's own ERTS, whatever is on PATH" do
    erl = List.to_string(Isolated.erl())

    assert File.regular?(erl)
    assert String.starts_with?(erl, List.to_string(:code.root_dir()))
    assert erl =~ "erts-#{:erlang.system_info(:version)}"
  end

  defp niceness(output), do: output |> List.to_string() |> String.trim() |> String.to_integer()
end
