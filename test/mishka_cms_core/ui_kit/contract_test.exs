defmodule MishkaCmsCore.UiKit.ContractTest do
  @moduledoc """
  The boundary between this CMS and a third party's bundle file.

  Everything downstream — the picker, the palette, the inspector, the runtime compiler — assumes a
  component has a name to find it by and a template to compile. Until this contract existed the only
  check was that `components` was a list, so a component missing either travelled into `Ash.create!`
  and raised there; from the Studio's Install button that took the editor's LiveView with it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.UiKit.Contract

  defp component(overrides \\ %{}) do
    Map.merge(%{"name" => "acme-alert", "template" => "<div class={@class}></div>"}, overrides)
  end

  describe "check/1" do
    test "the minimum a component needs is a name and a template" do
      assert Contract.check(component()) == :ok
    end

    test "a missing name or template is named as missing" do
      assert Contract.check(Map.delete(component(), "name")) == {:error, {:missing, :name}}

      assert Contract.check(Map.delete(component(), "template")) ==
               {:error, {:missing, :template}}
    end

    # An absent field and a field holding rubbish are different failures, and the installer's log
    # line says which.
    test "a blank one is not the same as a missing one" do
      assert Contract.check(component(%{"template" => "   "})) == {:error, {:blank, :template}}
      assert Contract.check(component(%{"name" => 42})) == {:error, {:not_a_string, :name}}
    end

    test "a name too short to find anything by is refused" do
      assert {:error, _reason} = Contract.check(component(%{"name" => "x"}))
    end

    # `attrs` as an object rather than an array is the shape mistake a hand-written bundle actually
    # makes, and every reader downstream assumes a list.
    test "a collection field that is not a collection is refused" do
      assert {:error, _reason} = Contract.check(component(%{"attrs" => %{"variant" => "base"}}))
      assert {:error, _reason} = Contract.check(component(%{"slots" => "none"}))
      assert {:error, _reason} = Contract.check(component(%{"extra" => []}))
    end

    # The contract is about SHAPE. A kit is free to carry fields this CMS has never heard of — they
    # are dropped later, at the Ash boundary, not treated as a reason to reject the component.
    test "a field this CMS does not know is not a reason to refuse" do
      assert Contract.check(component(%{"args" => ["a"], "doc_url" => "https://x", "n" => 1})) ==
               :ok
    end

    test "atom keys are accepted, since a caller may have already normalised them" do
      assert Contract.check(%{name: "acme-alert", template: "<div></div>"}) == :ok
    end

    test "something that is not a map at all is not a component" do
      assert Contract.check("acme-alert") == {:error, :not_a_component}
      assert Contract.check(nil) == {:error, :not_a_component}
    end
  end

  # THE THREE BOOLEANS A KIT MAY SET. `precompile` and `required` have been accepted from a bundle
  # since they existed and governed by nothing — and every component in a bundle is created inside
  # ONE `Ash.transaction`, with `Ash.create!` raising. So `"required": "yes"` did not cost that
  # component, it cost all 136. `stateful` joins them, governed from the day it arrives rather than
  # after the first kit gets it wrong.
  describe "the boolean flags" do
    test "a kit that says nothing about them is still a valid component" do
      assert Contract.check(component()) == :ok
    end

    test "and one that sets them properly is too" do
      assert Contract.check(
               component(%{"stateful" => true, "precompile" => true, "required" => false})
             ) == :ok
    end

    test "a value that is not a boolean costs that component and no other" do
      for flag <- ~w(stateful precompile required) do
        assert {:error, _reason} = Contract.check(component(%{flag => "yes"})),
               "#{flag} accepted a string, which reaches Ash.Type.Boolean and raises the transaction"
      end

      assert {:error, _reason} = Contract.check(component(%{"precompile" => 1}))
    end

    test "the bad one is dropped and the rest of the kit installs" do
      {kept, rejected} =
        Contract.partition([
          component(%{"name" => "acme-alert"}),
          component(%{"name" => "acme-yes", "required" => "yes"}),
          component(%{"name" => "acme-live", "stateful" => true})
        ])

      assert Enum.map(kept, & &1["name"]) == ["acme-alert", "acme-live"]
      assert [{"acme-yes", _reason}] = rejected
    end

    test "they are part of the governed surface" do
      for flag <- [:stateful, :precompile, :required] do
        assert flag in Contract.fields()
      end
    end
  end

  describe "partition/1" do
    test "one bad component costs that component, not the kit" do
      {kept, rejected} =
        Contract.partition([
          component(%{"name" => "acme-alert"}),
          Map.delete(component(%{"name" => "acme-broken"}), "template"),
          component(%{"name" => "acme-card"})
        ])

      assert Enum.map(kept, & &1["name"]) == ["acme-alert", "acme-card"]
      assert rejected == [{"acme-broken", {:missing, :template}}]
    end

    test "a rejected component with no name is still reported" do
      {[], [{nil, {:missing, :name}}]} = Contract.partition([%{"template" => "<div></div>"}])
    end

    test "an empty or non-list components key partitions to nothing" do
      assert Contract.partition([]) == {[], []}
      assert Contract.partition(nil) == {[], []}
    end
  end
end
