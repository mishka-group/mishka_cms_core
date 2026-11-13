# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.OperationTest do
  @moduledoc """
  A declaration says what "it worked" means, so one that cannot say it is refused when it is built,
  and the installed declarations are the ones the `agent:operations` event answers with.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Agent.Operation

  @valid %{
    name: "test:thing:do",
    stages: [:dispatched, :action_committed, {:db_read_back, expect: [status: :done]}],
    required: [:action_committed, :db_read_back]
  }

  test "builds a valid declaration" do
    assert %Operation{name: "test:thing:do", required: [:action_committed, :db_read_back]} =
             Operation.new!(@valid)
  end

  test "refuses an empty required list, a required name no stage has, and an unknown kind" do
    assert_raise ArgumentError, ~r/required/, fn -> Operation.new!(%{@valid | required: []}) end

    assert_raise ArgumentError, ~r/no stage/, fn ->
      Operation.new!(%{@valid | required: [:job]})
    end

    assert_raise ArgumentError, ~r/not a stage/, fn ->
      Operation.new!(%{@valid | stages: [:dispatched, :teleported]})
    end

    assert_raise ArgumentError, ~r/twice/, fn ->
      Operation.new!(%{@valid | stages: [:action_committed, :action_committed, :db_read_back]})
    end
  end

  test "the core's installer operations are declared on the event" do
    names = Enum.map(Operation.all(), & &1.name)

    assert "installer:extension:install" in names
    assert "installer:plugin:start" in names
    assert %Operation{required: [_ | _]} = Operation.lookup("installer:library:install")
    assert Operation.lookup("nobody:declared:this") == nil
  end
end
