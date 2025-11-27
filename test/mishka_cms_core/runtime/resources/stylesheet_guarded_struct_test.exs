defmodule MishkaCmsCore.Runtime.Resources.StylesheetGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.Stylesheet`.

    * `:content` — `sanitize(no_zero_width, no_control)` strips invisible
      unicode and control bytes from raw CSS (newlines/tabs preserved).
    * `:permissions` — `sanitize(each=[trim, downcase], reject_empty, uniq)
      validate(list)`.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.Stylesheet
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute" do
      assert MapSet.new([
               :name,
               :description,
               :content,
               :format,
               :kind,
               :priority,
               :active,
               :extra,
               :permissions
             ]) == Stylesheet.__guarded_field_name_set__()
    end
  end

  describe "direct __guarded_change__/1" do
    test "content: zero-width unicode stripped; newlines/tabs preserved" do
      assert {:ok, %{content: "body {\n\tcolor: red;\n}"}} =
               Stylesheet.__guarded_change__(%{
                 content: "bo​dy {\n\tcolor: red;\n}"
               })
    end

    test "content: control bytes stripped" do
      assert {:ok, %{content: ".x { padding: 1rem; }"}} =
               Stylesheet.__guarded_change__(%{
                 content: ".x { pad\x01ding: 1rem; }"
               })
    end

    test "permissions: trim + downcase + reject empties + uniq" do
      assert {:ok, %{permissions: ["css:read", "css:write"]}} =
               Stylesheet.__guarded_change__(%{
                 permissions: ["  CSS:READ  ", "Css:Read", "", "CSS:WRITE"]
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
              ]} = Stylesheet.__guarded_change__(%{permissions: "not a list"})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    test "content sanitize lands in DB", %{site_id: site_id} do
      attrs = %{
        name: "GS Stylesheet",
        content: ".btn { col​or: blue; }",
        format: :css,
        kind: :custom
      }

      assert {:ok, %Stylesheet{content: ".btn { color: blue; }"}} =
               Stylesheet
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end

    test "permissions cleanup lands in DB", %{site_id: site_id} do
      attrs = %{
        name: "GS Perms Sheet",
        content: ".tag { display: block; }",
        format: :css,
        kind: :custom,
        permissions: ["  ADMIN  ", "admin", "USER"]
      }

      assert {:ok, %Stylesheet{permissions: ["admin", "user"]}} =
               Stylesheet
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end
  end
end
