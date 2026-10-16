defmodule MishkaCmsCore.Runtime.Resources.JsHookGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.JsHook`.

    * `:content` — `sanitize(no_zero_width, no_control)` strips invisible
      unicode and control bytes from JS/TS source (newlines/tabs preserved).
    * `:permissions` — `sanitize(each=[trim, downcase], reject_empty, uniq)
      validate(list)` per-element cleanup + dedupe.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.JsHook
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute" do
      assert MapSet.new([
               :name,
               :description,
               :content,
               :format,
               :priority,
               :active,
               :lazy,
               :permissions
             ]) == JsHook.__guarded_field_name_set__()
    end
  end

  describe "direct __guarded_change__/1" do
    test "content: control bytes stripped; tab and newline preserved" do
      assert {:ok, %{content: "function foo() {\n\treturn 1;\n}"}} =
               JsHook.__guarded_change__(%{
                 content: "function foo() {\n\treturn\x01 1;\n\x07}"
               })
    end

    test "content: zero-width-space alone is stripped" do
      assert {:ok, %{content: "console.log('hi')"}} =
               JsHook.__guarded_change__(%{content: "console.​log('hi')"})
    end

    test "permissions: trim + downcase + reject empties + uniq" do
      assert {:ok, %{permissions: ["js:read", "js:write"]}} =
               JsHook.__guarded_change__(%{
                 permissions: ["  JS:READ  ", "js:read", "", "  ", "JS:Write"]
               })
    end

    test "permissions: non-list is rejected" do
      assert {:error,
              [
                %{
                  field: :permissions,
                  action: :list,
                  message: _
                }
              ]} = JsHook.__guarded_change__(%{permissions: "not a list"})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    test "content sanitize lands in DB", %{site_id: site_id} do
      attrs = %{
        name: "GS Hook",
        content: "export const x = 1;​// note",
        format: :js
      }

      assert {:ok, %JsHook{content: "export const x = 1;// note"}} =
               JsHook
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end

    test "permissions clean+dedupe lands in DB", %{site_id: site_id} do
      attrs = %{
        name: "GS Perms Hook",
        content: "export const y = 2;",
        format: :js,
        permissions: ["  ADMIN  ", "admin", "WRITER"]
      }

      assert {:ok, %JsHook{permissions: ["admin", "writer"]}} =
               JsHook
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end
  end
end
