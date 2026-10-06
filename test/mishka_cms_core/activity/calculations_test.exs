defmodule MishkaCmsCore.Activity.CalculationsTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Calculations.{ResourceLabel, Severity}

  describe "Severity.calculate/3" do
    test "maps destroy-class actions to :warn and the rest to :info" do
      versions = [
        %{version_action_name: :create},
        %{version_action_name: :master_update},
        %{version_action_name: :destroy},
        %{version_action_name: :master_destroy},
        %{version_action_name: :permanent_destroy},
        %{version_action_name: :unarchive}
      ]

      # Through init/1, as Ash calls it — that is what defaults :field to :version_action_name.
      # Passing raw opts makes every record read `Map.get(record, nil)` and come back :info.
      {:ok, opts} = Severity.init([])

      assert Severity.calculate(versions, opts, %{}) ==
               [:info, :info, :warn, :warn, :warn, :info]
    end

    test "empty list returns empty list" do
      {:ok, opts} = Severity.init([])
      assert Severity.calculate([], opts, %{}) == []
    end
  end

  describe "ResourceLabel" do
    test "init/1 accepts a non-empty :label option" do
      assert {:ok, opts} = ResourceLabel.init(label: "Page")
      assert opts[:label] == "Page"
    end

    test "init/1 rejects missing label" do
      assert {:error, _} = ResourceLabel.init([])
    end

    test "init/1 rejects empty-string label" do
      assert {:error, _} = ResourceLabel.init(label: "")
    end

    test "init/1 rejects non-string label" do
      assert {:error, _} = ResourceLabel.init(label: :page)
    end

    test "calculate/3 returns the configured label for every record" do
      assert ResourceLabel.calculate([%{}, %{}, %{}], [label: "Component"], %{}) ==
               ["Component", "Component", "Component"]
    end

    test "calculate/3 on empty list returns empty list" do
      assert ResourceLabel.calculate([], [label: "Page"], %{}) == []
    end
  end
end
