defmodule MishkaCmsCore.Runtime.Resources.LayoutGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.Layout`.

    * `:path` — `sanitize(trim) validate(regex=^(?!.*\\.\\.)/[a-zA-Z0-9/_*.:-]*$)`.
    * `:template` and `:example` — `sanitize(no_zero_width, no_control)`.
    * `:permissions` — `sanitize(each=[trim, downcase], reject_empty, uniq)
      validate(list)`.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.Layout
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute" do
      assert MapSet.new([
               :name,
               :path,
               :description,
               :template,
               :format,
               :priority,
               :active,
               :precompile,
               :extra,
               :content,
               :example,
               :resource_links,
               :seo_tags,
               :helpers,
               :permissions
             ]) == Layout.__guarded_field_name_set__()
    end
  end

  describe "direct __guarded_change__/1" do
    test "path: accepted forms" do
      assert {:ok, %{path: "/blog/*"}} = Layout.__guarded_change__(%{path: "  /blog/*  "})
      assert {:ok, %{path: "/users/:id"}} = Layout.__guarded_change__(%{path: "/users/:id"})
      assert {:ok, %{path: "/about"}} = Layout.__guarded_change__(%{path: "/about"})
    end

    test "path: .. traversal rejected with explicit error" do
      assert {:error,
              [
                %{
                  field: :path,
                  action: :regex,
                  message: "Invalid format in the path field"
                }
              ]} = Layout.__guarded_change__(%{path: "/foo/../bar"})
    end

    test "template: zero-width unicode stripped; whitespace preserved" do
      assert {:ok, %{template: "<main>\n  <slot />\n</main>"}} =
               Layout.__guarded_change__(%{template: "<main>\n  <​slot />\n</main>"})
    end

    test "example: control bytes stripped" do
      assert {:ok, %{example: "<div>example</div>"}} =
               Layout.__guarded_change__(%{example: "<div>e\x01x\x02ample</div>"})
    end

    test "permissions: trim + downcase + reject empties + uniq" do
      assert {:ok, %{permissions: ["layout:read", "layout:write"]}} =
               Layout.__guarded_change__(%{
                 permissions: ["  LAYOUT:READ  ", "Layout:Read", "", "LAYOUT:WRITE"]
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
              ]} = Layout.__guarded_change__(%{permissions: "not a list"})
    end

    test "resource_links / seo_tags / helpers: lists accepted, non-list rejected" do
      assert {:ok,
              %{
                resource_links: [%{type: "stylesheet", href: "/css/app.css"}],
                seo_tags: [%{tag: "meta", attrs: %{name: "viewport"}}],
                helpers: [%{name: "uppercase", code: "&String.upcase/1"}]
              }} =
               Layout.__guarded_change__(%{
                 resource_links: [%{type: "stylesheet", href: "/css/app.css"}],
                 seo_tags: [%{tag: "meta", attrs: %{name: "viewport"}}],
                 helpers: [%{name: "uppercase", code: "&String.upcase/1"}]
               })

      assert {:error,
              [
                %{
                  field: :seo_tags,
                  action: :list,
                  message: _
                }
              ]} = Layout.__guarded_change__(%{seo_tags: "not a list"})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    test "valid path + template lands sanitized in DB", %{site_id: site_id} do
      attrs = %{
        name: "GS Layout",
        path: "  /blog/*  ",
        template: "<main>he​llo</main>",
        format: :heex
      }

      assert {:ok, %Layout{path: "/blog/*", template: "<main>hello</main>"}} =
               Layout
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end

    test "bad path with .. rejected through Ash", %{site_id: site_id} do
      attrs = %{
        name: "GS Bad Path",
        path: "/admin/../etc",
        template: "<div>x</div>",
        format: :heex
      }

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Layout
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()

      assert Enum.any?(errors, fn e ->
               match?(%{field: :path}, e) and e.message =~ "Invalid format"
             end)
    end
  end
end
