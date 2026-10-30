# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.FieldsTest do
  @moduledoc """
  A previewed form field appears in a form; a dropped one does not.

  The detector fails OPEN — get it wrong and every field previews bare, exactly as before, with no
  error anywhere to notice. So the set it selects is pinned against the installed bundles rather than
  against a fixture, and the two components that sit one signal away from inclusion are named.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Fields

  @moduletag :unit

  @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

  setup_all do
    components =
      @kits_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path |> File.read!() |> Jason.decode!() |> Map.get("components", [])
      end)

    {:ok, components: components, by_name: Map.new(components, &{&1["name"], &1})}
  end

  defp entry(component) do
    %{
      name: component["name"],
      global?: true,
      attrs: component["attrs"] || [],
      slots: component["slots"] || [],
      helpers: component["helpers"] || [],
      template: component["template"] || ""
    }
  end

  describe "field?/1 against the installed kits" do
    test "the installed kits ship form fields at all", %{components: components} do
      fields = for c <- components, Fields.field?(entry(c)), do: c["name"]

      assert length(fields) >= 15,
             "expected the kit's form fields to be recognised; found #{length(fields)}"
    end

    test "the obvious ones are in", %{by_name: by_name} do
      for name <- ~w(chelekom-text-field chelekom-native-select chelekom-file-field
                     chelekom-checkbox-field chelekom-toggle-field chelekom-combobox) do
        assert Fields.field?(entry(by_name[name])), "#{name} should be a field"
      end
    end

    # `chelekom-input-button` renders a real `<input>` and `chelekom-fieldset` declares both `name`
    # and `value` — each is one signal away from the set, and each is the reason the detector needs
    # more than one signal. A submit button previewed inside a form would be a form inside a form the
    # moment the author put one on the page.
    test "the two that only look like fields are out", %{by_name: by_name} do
      refute Fields.field?(entry(by_name["chelekom-input-button"]))
      refute Fields.field?(entry(by_name["chelekom-fieldset"]))
    end

    # Helper clauses are bundled per source MODULE, so this component carries `native_select`'s
    # `%Phoenix.HTML.FormField{}` clause head while rendering nothing but `<option>`. Reading helpers
    # would have called it a field.
    test "a component that only inherited a form-field helper is out", %{by_name: by_name} do
      refute Fields.field?(entry(by_name["chelekom-select-option-group"]))
    end

    test "ordinary components are out", %{by_name: by_name} do
      for name <- ~w(chelekom-card chelekom-banner chelekom-table chelekom-button) do
        refute Fields.field?(entry(by_name[name])), "#{name} should not be a field"
      end
    end
  end

  describe "forwarded_type/1" do
    test "reads the type of the input a kit spreads its catch-all onto", %{by_name: by_name} do
      for {name, type} <- [
            {"chelekom-checkbox-field", "checkbox"},
            {"chelekom-toggle-field", "checkbox"},
            {"chelekom-radio-field", "radio"},
            {"chelekom-file-field", "file"},
            {"chelekom-text-field", "text"},
            {"chelekom-email-field", "email"},
            {"chelekom-textarea-field", nil}
          ] do
        assert Fields.forwarded_type(entry(by_name[name])) == type, name
      end

      assert Fields.forwarded_type(nil) == nil
    end

    test "an input that only reads one of the catch-all's keys is not the one it is spread onto" do
      row = %{
        "name" => "kit-tagged-field",
        "attrs" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "rest", "type" => "global"}
        ],
        "template" =>
          ~s(<div><input type="hidden" name="kind" value="tag" disabled={@rest[:disabled]} />) <>
            ~s(<input data-type="x" type="search" name={@name} {@rest} /></div>)
      }

      assert Fields.forwarded_type(entry(row)) == "search"
    end
  end

  describe "structural?/1" do
    # The branch a kit with no `Phoenix.HTML.FormField` falls back to. It is deliberately a WIDENING
    # branch, not a cross-check: on this kit it finds 15 of the 23 on its own, so as the primary test
    # it would have missed `combobox`, `file-field`, `native-select` and `rating`.
    test "recognises a field bound the plain way" do
      entry = %{
        name: "acme-text",
        attrs: [%{"name" => "name", "type" => "string"}, %{"name" => "value", "type" => "string"}],
        template: ~S(<input type="text" name={@name} value={@value} />)
      }

      assert Fields.structural?(entry)
      assert Fields.field?(entry)
    end

    test "a control with no name binding is not a field" do
      refute Fields.structural?(%{
               name: "acme-button",
               attrs: [%{"name" => "value", "type" => "string"}],
               template: ~S(<input type="submit" value={@value} />)
             })
    end
  end

  describe "stage/2" do
    test "a field is previewed inside a form", %{by_name: by_name} do
      staged = Fields.stage("<.component/>", entry(by_name["chelekom-text-field"]))

      assert staged =~ "<form"
      assert staged =~ "</form>"
    end

    # A `<form>` with no handler still submits: Enter in a previewed text field would navigate the
    # preview iframe away and the LiveView with it.
    test "the staged form cannot navigate the preview away", %{by_name: by_name} do
      assert Fields.stage("<.component/>", entry(by_name["chelekom-text-field"])) =~
               ~s(phx-submit=")
    end

    test "anything else is left exactly as it was", %{by_name: by_name} do
      assert Fields.stage("<.component/>", entry(by_name["chelekom-card"])) == "<.component/>"
      assert Fields.stage("<.component/>", nil) == "<.component/>"
    end
  end
end
