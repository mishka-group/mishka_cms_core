# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.PermissionGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Accounts.Permission`.

  Permission names are colon-separated segments (e.g. `admin:dashboard:runtime:page`,
  `admin:api:*`). The GS pipeline:

    * `:name` — `sanitize(trim, downcase)` normalises to lowercase before any
      uniqueness check. `validate(string, not_empty, min_len=1, max_len=200,
      regex=…)` rejects garbage names. The regex enforces:
        - first segment starts with a lowercase letter; alnum+underscore body
        - any further `:`-separated segments are alnum/underscore, and `*` only
          as the whole last segment (so `admin:api:*` is valid, `admin:*:page`
          and `dash*` are not).
    * `:description` — `sanitize(trim) validate(optional=[string])` — keep
      whitespace clean; nil passes through.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Accounts.Permission
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers name + description" do
      assert MapSet.new([:name, :description]) ==
               Permission.__guarded_field_name_set__()
    end

    test "GuardedStruct.AshResource.Change is registered on the resource" do
      assert Permission
             |> Ash.Resource.Info.changes()
             |> Enum.any?(fn c -> c.change == {GuardedStruct.AshResource.Change, []} end)
    end
  end

  describe "direct __guarded_change__/1 — name" do
    test "two-segment, three-segment, and wildcard forms accepted" do
      assert {:ok, %{name: "admin:dashboard:runtime:page"}} =
               Permission.__guarded_change__(%{name: "admin:dashboard:runtime:page"})

      assert {:ok, %{name: "admin:api:*"}} =
               Permission.__guarded_change__(%{name: "admin:api:*"})

      assert {:ok, %{name: "test:perm:1"}} =
               Permission.__guarded_change__(%{name: "test:perm:1"})
    end

    test "bare * (super-admin wildcard) accepted as a standalone name" do
      assert {:ok, %{name: "*"}} = Permission.__guarded_change__(%{name: "*"})
    end

    test "* only as the whole last segment" do
      for name <- ["admin:*", "admin:dashboard:*", "admin:dashboard:runtime:*", "permission:12"] do
        assert {:ok, %{name: ^name}} = Permission.__guarded_change__(%{name: name})
      end

      for name <- [
            "admin:*:page",
            "admin:dashboard:*:page",
            "dash*",
            "admin:dash*",
            "admin:page*",
            "*:page",
            "admin:**"
          ] do
        assert {:error, [%{field: :name, action: :regex}]} =
                 Permission.__guarded_change__(%{name: name}),
               name
      end
    end

    test "uppercase + surrounding whitespace normalised to lowercase trimmed form" do
      assert {:ok, %{name: "admin:dashboard:runtime:page"}} =
               Permission.__guarded_change__(%{name: "  ADMIN:Dashboard:Runtime:Page  "})
    end

    test "permission with disallowed chars (space) rejected" do
      assert {:error,
              [
                %{
                  field: :name,
                  action: :regex,
                  message: "Invalid format in the name field"
                }
              ]} = Permission.__guarded_change__(%{name: "bad name"})
    end

    test "permission starting with a digit rejected" do
      assert {:error,
              [
                %{
                  field: :name,
                  action: :regex,
                  message: "Invalid format in the name field"
                }
              ]} = Permission.__guarded_change__(%{name: "1admin:dashboard:runtime:page"})
    end

    test "name over 200 chars rejected with explicit error" do
      assert {:error,
              [
                %{
                  field: :name,
                  action: :max_len,
                  message: "The maximum number of characters in the name field is 200" <> _
                }
              ]} = Permission.__guarded_change__(%{name: String.duplicate("x", 201)})
    end
  end

  describe "direct __guarded_change__/1 — description" do
    test "nil passes through unchanged" do
      assert {:ok, %{description: nil}} = Permission.__guarded_change__(%{description: nil})
    end

    test "string is trimmed" do
      assert {:ok, %{description: "Lets users edit blog posts."}} =
               Permission.__guarded_change__(%{description: "  Lets users edit blog posts.  "})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    test "valid permission persists with normalised name" do
      assert {:ok,
              %Permission{
                name: "admin:dashboard:runtime:page",
                description: "Lets users edit blog posts."
              }} =
               Permission
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "  ADMIN:Dashboard:Runtime:Page  ",
                   description: "  Lets users edit blog posts.  "
                 },
                 authorize?: false
               )
               |> Ash.create()
    end

    test "permission name with bad format is rejected through Ash" do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Permission
               |> Ash.Changeset.for_create(:create, %{name: "BAD NAME"}, authorize?: false)
               |> Ash.create()

      assert Enum.any?(errors, fn e ->
               match?(%{field: :name}, e) and e.message =~ "Invalid format"
             end)
    end
  end
end
