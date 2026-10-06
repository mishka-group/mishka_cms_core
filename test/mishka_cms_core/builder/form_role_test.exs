defmodule MishkaCmsCore.Builder.FormRoleTest do
  @moduledoc """
  The reader for a kit's `extra.form` declaration.

  Two things are pinned here. Every role a kit may declare reads back unchanged, and everything a
  kit may get wrong — an invented role, no role at all, a value that is not a map — costs the
  declaration and nothing more, so `MishkaCmsCore.Runtime.PageBuilder.Fields` infers instead.

  The binding tests are the point of the module. A key naming an attribute the component does not
  declare has to be dropped: kept, it would write `bind={f[:email]}` onto a component with no `bind`
  attribute, the renderer would drop the unknown attribute, and the field would be called with
  neither a binding nor a name — a `KeyError` on `:name` from inside LiveView's diff.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.FormRole

  defp component(attrs \\ [], slots \\ []) do
    %{"name" => "acme-input", "attrs" => attrs, "slots" => slots}
  end

  defp attr(name, type \\ "string"), do: %{"name" => name, "type" => type}

  describe "the five roles" do
    test "each one a kit may declare reads back" do
      for role <- FormRole.roles() do
        assert {:ok, %FormRole{role: ^role, bindings: %{}}} =
                 FormRole.build(%{"role" => role}, component())
      end
    end

    test "roles/0 is the whole vocabulary, so a kit author can read it rather than guess" do
      assert FormRole.roles() == ~w(wrapper field error fieldset submit)
    end

    test "a role is trimmed and downcased on the way in" do
      assert {:ok, %FormRole{role: "field"}} =
               FormRole.build(%{"role" => "  Field "}, component())
    end

    test "an atom-keyed declaration reads the same as a string-keyed one" do
      assert {:ok, %FormRole{role: "wrapper"}} = FormRole.build(%{role: "wrapper"}, component())
    end
  end

  describe "a declaration this module cannot read" do
    test "an unknown role is not a role" do
      assert FormRole.build(%{"role" => "input"}, component()) == :none
    end

    test "a missing role is not a role" do
      assert FormRole.build(%{"field" => "bind"}, component()) == :none
    end

    test "an empty declaration is not a role" do
      assert FormRole.build(%{}, component()) == :none
    end

    test "a declaration that is not a map is not a role" do
      assert FormRole.build("not a map", component()) == :none
      assert FormRole.build(nil, component()) == :none
      assert FormRole.build(["role", "field"], component()) == :none
    end

    test "a role that is not a string is not a role" do
      assert FormRole.build(%{"role" => :field}, component()) == :none
      assert FormRole.build(%{"role" => 1}, component()) == :none
    end
  end

  describe "bindings name the component's own attributes" do
    test "a key naming an attribute the component declares is kept" do
      entry = component([attr("bind", "Phoenix.HTML.FormField"), attr("input_name")])

      assert {:ok, %FormRole{bindings: bindings}} =
               FormRole.build(
                 %{"role" => "field", "field" => "bind", "name" => "input_name"},
                 entry
               )

      assert bindings == %{"field" => "bind", "name" => "input_name"}
    end

    # A SLOT IS NOT AN ATTRIBUTE, and every key here names one the editor writes into or reads out
    # of. Accepting slots reopened the very failure this module exists to prevent from the other
    # side: `"field": "inner_block"` names something the component really declares, so the key
    # survived validation, and the editor then wrote `inner_block={f[:email]}` — which the component
    # accepts no more than the `bind` it never had.
    test "a key naming a slot is dropped, even one the component really declares" do
      entry = component([attr("errors")], [%{"name" => "content"}])

      assert {:ok, %FormRole{bindings: bindings}} =
               FormRole.build(
                 %{"role" => "fieldset", "errors" => "errors", "content" => "content"},
                 entry
               )

      assert bindings == %{"errors" => "errors"}
    end

    test "a key naming an attribute the component does NOT declare is dropped, because writing it would call the field with neither a binding nor a name" do
      entry = component([attr("value")])

      assert {:ok, %FormRole{role: "field", bindings: bindings}} =
               FormRole.build(
                 %{"role" => "field", "field" => "bind", "value" => "value"},
                 entry
               )

      assert bindings == %{"value" => "value"}
      refute Map.has_key?(bindings, "field")
    end

    test "a component declaring nothing keeps no bindings at all" do
      assert {:ok, %FormRole{role: "field", bindings: %{}}} =
               FormRole.build(%{"role" => "field", "field" => "bind"}, component())
    end

    test "the role key is never a binding, even on a component with an attribute called role" do
      entry = component([attr("role")])

      assert {:ok, %FormRole{bindings: %{}}} =
               FormRole.build(%{"role" => "submit"}, entry)
    end

    test "a key whose value is not a string is dropped" do
      entry = component([attr("bind")])

      assert {:ok, %FormRole{bindings: %{}}} =
               FormRole.build(%{"role" => "field", "field" => %{"attr" => "bind"}}, entry)
    end

    test "atom-named attributes are matched the same as string-named ones" do
      entry = %{name: "acme-input", attrs: [%{name: :bind}], slots: []}

      assert {:ok, %FormRole{bindings: %{"field" => "bind"}}} =
               FormRole.build(%{"role" => "field", "field" => "bind"}, entry)
    end

    test "an entry carrying no attrs or slots at all costs the bindings, not the role" do
      assert {:ok, %FormRole{role: "wrapper", bindings: %{}}} =
               FormRole.build(%{"role" => "wrapper", "for" => "for"}, %{})
    end
  end
end
