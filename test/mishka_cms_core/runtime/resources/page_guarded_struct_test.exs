defmodule MishkaCmsCore.Runtime.Resources.PageGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.Page`.

    * `:path` — `sanitize(trim) validate(regex=^(?!.*\\.\\.)/[a-zA-Z0-9/_*.:-]*$)`.
    * `:template` — `sanitize(no_zero_width, no_control)`.
    * `:permissions` — `sanitize(each=[trim, downcase], reject_empty, uniq)
      validate(list)`.
    * `:language` — `sanitize(trim, downcase) validate(language_code)`.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.Page
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute" do
      assert MapSet.new([
               :name,
               :title,
               :path,
               :section,
               :template,
               :description,
               :format,
               :priority,
               :active,
               :precompile,
               :extra,
               :content,
               :seo_tags,
               :schema,
               :events,
               :infos,
               :state,
               :resource_links,
               :helpers,
               :uploads,
               :permissions,
               :language,
               :language_group_id
             ]) == Page.__guarded_field_name_set__()
    end
  end

  describe "direct __guarded_change__/1" do
    test "path: trimmed and accepted forms" do
      assert {:ok, %{path: "/blog/posts"}} =
               Page.__guarded_change__(%{path: "  /blog/posts  "})

      assert {:ok, %{path: "/users/:id/edit"}} =
               Page.__guarded_change__(%{path: "/users/:id/edit"})
    end

    test "path: .. traversal rejected" do
      assert {:error,
              [
                %{
                  field: :path,
                  action: :regex,
                  message: "Invalid format in the path field"
                }
              ]} = Page.__guarded_change__(%{path: "/foo/../bar"})
    end

    test "path: must start with /" do
      assert {:error,
              [
                %{
                  field: :path,
                  action: :regex,
                  message: "Invalid format in the path field"
                }
              ]} = Page.__guarded_change__(%{path: "blog/posts"})
    end

    test "template: zero-width unicode stripped; whitespace preserved" do
      assert {:ok, %{template: "<h1>Hello</h1>\n<p>world</p>"}} =
               Page.__guarded_change__(%{template: "<h1>He​llo</h1>\n<p>world</p>"})
    end

    test "permissions: per-element clean + dedupe" do
      assert {:ok, %{permissions: ["page:read", "page:write", "admin:*"]}} =
               Page.__guarded_change__(%{
                 permissions: [
                   "  PAGE:READ  ",
                   "Page:Read",
                   "PAGE:WRITE",
                   "admin:*",
                   ""
                 ]
               })
    end

    test "language: trimmed and downcased, and only a language code" do
      assert {:ok, %{language: "pt-br"}} = Page.__guarded_change__(%{language: "  PT-BR  "})

      assert {:error, [%{field: :language, action: :language_code}]} =
               Page.__guarded_change__(%{language: "english"})
    end

    test "permissions: non-list is rejected" do
      assert {:error,
              [
                %{
                  field: :permissions,
                  action: :list,
                  message: _
                }
              ]} = Page.__guarded_change__(%{permissions: "not a list"})
    end

    test "seo_tags / schema / events / infos / resource_links / helpers: list type checked" do
      assert {:ok,
              %{
                seo_tags: [%{tag: "meta", attrs: %{name: "description"}}],
                events: [%{name: "phx-click", code: "handle_click"}],
                infos: [%{name: "page_info", code: "fn -> :ok end"}],
                resource_links: [%{type: "stylesheet", href: "/css/app.css"}],
                helpers: [%{name: "fmt", code: "&Function.identity/1"}]
              }} =
               Page.__guarded_change__(%{
                 seo_tags: [%{tag: "meta", attrs: %{name: "description"}}],
                 schema: [%{}],
                 events: [%{name: "phx-click", code: "handle_click"}],
                 infos: [%{name: "page_info", code: "fn -> :ok end"}],
                 resource_links: [%{type: "stylesheet", href: "/css/app.css"}],
                 helpers: [%{name: "fmt", code: "&Function.identity/1"}]
               })

      assert {:error,
              [
                %{
                  field: :events,
                  action: :list,
                  message: _
                }
              ]} = Page.__guarded_change__(%{events: "not a list"})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    test "valid path + template lands sanitized in DB", %{site_id: site_id} do
      attrs = %{
        name: "GS Page",
        title: "GS Page",
        path: "  /about  ",
        template: "<article>he​llo</article>",
        format: :heex
      }

      assert {:ok, %Page{path: "/about", template: "<article>hello</article>"}} =
               Page
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()
    end

    test "path with .. rejected through Ash", %{site_id: site_id} do
      attrs = %{
        name: "GS Bad Page",
        title: "GS Bad Page",
        path: "/../../etc/passwd",
        template: "<div>x</div>",
        format: :heex
      }

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Page
               |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, authorize?: false)
               |> Ash.create()

      assert Enum.any?(errors, fn e ->
               match?(%{field: :path}, e) and e.message =~ "Invalid format"
             end)
    end
  end
end
