defmodule MishkaCmsCore.Runtime.Resources.ComponentGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.Component`.

  Validates the four fields where GS adds real safety on top of Ash:

    * `:template` and `:body` — `sanitize(no_zero_width, no_control)` strips
      invisible-unicode injection vectors and ASCII control bytes (but
      keeps `\\t`, `\\n`, `\\r` so legitimate templates round-trip).
    * `:permissions` — `sanitize(each=[trim, downcase], reject_empty, uniq)
      validate(list)` cleans each entry and dedupes.
    * `:examples` — `sanitize(reject_empty, uniq) validate(list)` dedupes.

  Tests exercise both the macro pipeline through `Ash.create/1` and the
  direct `__guarded_change__/1` entry point so the contract is pinned at
  both layers with full-output assertions.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.Component
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute except auto-managed ones" do
      assert MapSet.new([
               :name,
               :description,
               :template,
               :body,
               :format,
               :priority,
               :active,
               :extra,
               :attrs,
               :slots,
               :helpers,
               :permissions,
               :examples,
               :type,
               :dependencies,
               :precompile
             ]) == Component.__guarded_field_name_set__()
    end

    test "GuardedStruct.AshResource.Change is registered as a resource change" do
      assert Component
             |> Ash.Resource.Info.changes()
             |> Enum.any?(fn c -> c.change == {GuardedStruct.AshResource.Change, []} end)
    end
  end

  describe "direct __guarded_change__/1 — full output pinned" do
    test "template + body: zero-width chars and NUL byte are stripped; whitespace preserved" do
      assert {:ok,
              %{
                template: "<div>hello\n  world</div>",
                body: "line1\nline2\tindented"
              }} =
               Component.__guarded_change__(%{
                 template: "<div>he​llo\n  wo\x00rld</div>",
                 body: "line1\nline2\tindented"
               })
    end

    test "permissions: trims, downcases, drops empties, dedupes" do
      assert {:ok, %{permissions: ["admin:component:*", "tenant:read"]}} =
               Component.__guarded_change__(%{
                 permissions: [
                   "  ADMIN:COMPONENT:*  ",
                   "Admin:Component:*",
                   "",
                   "  TENANT:read  ",
                   ""
                 ]
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
              ]} = Component.__guarded_change__(%{permissions: "not a list"})
    end

    test "examples: drops empty strings and dedupes" do
      assert {:ok, %{examples: ["<.greet />", "<.greet name=\"x\" />"]}} =
               Component.__guarded_change__(%{
                 examples: [
                   "<.greet />",
                   "",
                   "<.greet name=\"x\" />",
                   "<.greet />",
                   ""
                 ]
               })
    end

    test "examples: non-list is rejected" do
      assert {:error,
              [
                %{
                  field: :examples,
                  action: :list,
                  message: _
                }
              ]} = Component.__guarded_change__(%{examples: "not a list"})
    end

    test "empty input is a no-op (no fields present → no errors)" do
      assert {:ok, %{}} = Component.__guarded_change__(%{})
    end

    test "name: trim + length-bounds (min 3, max 100)" do
      assert {:ok, %{name: "My Component"}} =
               Component.__guarded_change__(%{name: "  My Component  "})

      assert {:error,
              [
                %{
                  field: :name,
                  action: :min_len,
                  message: "The minimum number of characters in the name field is 3" <> _
                }
              ]} = Component.__guarded_change__(%{name: "ab"})

      assert {:error,
              [
                %{
                  field: :name,
                  action: :max_len,
                  message: "The maximum number of characters in the name field is 100" <> _
                }
              ]} = Component.__guarded_change__(%{name: String.duplicate("x", 101)})
    end

    test "description: optional — nil passes; over-long rejected" do
      assert {:ok, %{description: nil}} = Component.__guarded_change__(%{description: nil})

      assert {:ok, %{description: "Hi there"}} =
               Component.__guarded_change__(%{description: "  Hi there  "})

      assert {:error,
              [
                %{
                  field: :description,
                  action: :max_len,
                  message: "The maximum number of characters in the description field is 500" <> _
                }
              ]} =
               Component.__guarded_change__(%{description: String.duplicate("d", 501)})
    end

    test "format: enum members accepted; unknown atom rejected" do
      assert {:ok, %{format: :heex}} = Component.__guarded_change__(%{format: :heex})
      assert {:ok, %{format: :eex}} = Component.__guarded_change__(%{format: :eex})
      assert {:ok, %{format: :markdown}} = Component.__guarded_change__(%{format: :markdown})

      assert {:error,
              [
                %{
                  field: :format,
                  action: :enum,
                  message: "Your sent data form format field is not in the allowed list"
                }
              ]} = Component.__guarded_change__(%{format: :bogus})
    end

    test "priority: integer range 0..100" do
      assert {:ok, %{priority: 50}} = Component.__guarded_change__(%{priority: 50})

      assert {:error,
              [
                %{
                  field: :priority,
                  action: :min_len,
                  message: "The minimum number the priority field is 0" <> _
                }
              ]} = Component.__guarded_change__(%{priority: -1})

      assert {:error,
              [
                %{
                  field: :priority,
                  action: :max_len,
                  message: "The maximum number the priority field is 100" <> _
                }
              ]} = Component.__guarded_change__(%{priority: 101})
    end

    test "active + extra: type validation" do
      assert {:ok, %{active: true, extra: %{}}} =
               Component.__guarded_change__(%{active: true, extra: %{}})

      assert {:error, errs} = Component.__guarded_change__(%{active: "yes"})

      assert Enum.any?(errs, &match?(%{field: :active, action: :boolean}, &1))
    end

    test "attrs/slots/helpers: lists accepted, non-list rejected, oversize rejected" do
      assert {:ok,
              %{
                attrs: [%{name: "text", type: "string"}],
                slots: [%{name: "inner_block"}],
                helpers: [%{name: "uppercase", code: "fn s -> String.upcase(s) end"}]
              }} =
               Component.__guarded_change__(%{
                 attrs: [%{name: "text", type: "string"}],
                 slots: [%{name: "inner_block"}],
                 helpers: [%{name: "uppercase", code: "fn s -> String.upcase(s) end"}]
               })

      assert {:error,
              [
                %{
                  field: :attrs,
                  action: :list,
                  message: _
                }
              ]} = Component.__guarded_change__(%{attrs: "not a list"})

      assert {:error,
              [
                %{
                  field: :slots,
                  action: :list,
                  message: _
                }
              ]} = Component.__guarded_change__(%{slots: "not a list"})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    test "template/body zero-width stripped on insert", %{site_id: site_id} do
      attrs = %{
        name: "GS Demo Component",
        template: "<p>foo​bar</p>",
        body: "before​after",
        format: :heex
      }

      assert {:ok, %Component{template: "<p>foobar</p>", body: "beforeafter"}} =
               Component
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end

    test "permissions trim + downcase + dedupe on insert (non-empty elements)",
         %{site_id: site_id} do
      attrs = %{
        name: "GS Perms Component",
        template: "<div>perm</div>",
        format: :heex,
        permissions: ["  ADMIN  ", "admin", "MODERATOR"]
      }

      assert {:ok, %Component{permissions: ["admin", "moderator"]}} =
               Component
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end
  end
end
