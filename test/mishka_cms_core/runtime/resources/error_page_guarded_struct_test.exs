defmodule MishkaCmsCore.Runtime.Resources.ErrorPageGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.ErrorPage`.

    * `:path` — `sanitize(trim) validate(regex=^(?!.*\\.\\.)/[a-zA-Z0-9/_*.:-]*$)`
      anchors the path to start with `/`, allows Phoenix-style `:param` and
      `*` glob, REJECTS `..` (path traversal). It guards what is STORED, and on
      this resource that is never what a caller sent — `Changes.ErrorPageAddress`
      writes the site's own address into the column first.
    * `:root_layout_template` — `sanitize(no_zero_width, no_control)` strips
      invisible-unicode and ASCII control bytes (preserves tab/newline/CR).
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.ErrorAddress
  alias MishkaCmsCore.Runtime.ErrorPage
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute" do
      assert MapSet.new([
               :name,
               :path,
               :root_layout_template,
               :format,
               :priority,
               :active,
               :precompile,
               :extra,
               :error_pages,
               :helpers
             ]) == ErrorPage.__guarded_field_name_set__()
    end
  end

  describe "direct __guarded_change__/1 — path regex" do
    test "accepts plain path, glob path, and Phoenix-style :param" do
      assert {:ok, %{path: "/errors/*"}} =
               ErrorPage.__guarded_change__(%{path: "  /errors/*  "})

      assert {:ok, %{path: "/users/:id"}} =
               ErrorPage.__guarded_change__(%{path: "/users/:id"})

      assert {:ok, %{path: "/"}} = ErrorPage.__guarded_change__(%{path: "/"})
    end

    test "rejects path containing .. (path traversal)" do
      assert {:error,
              [
                %{
                  field: :path,
                  action: :regex,
                  message: "Invalid format in the path field"
                }
              ]} = ErrorPage.__guarded_change__(%{path: "/admin/../etc"})
    end

    test "rejects path without leading /" do
      assert {:error,
              [
                %{
                  field: :path,
                  action: :regex,
                  message: "Invalid format in the path field"
                }
              ]} = ErrorPage.__guarded_change__(%{path: "errors/*"})
    end

    test "rejects path with disallowed characters (space)" do
      assert {:error,
              [
                %{
                  field: :path,
                  action: :regex,
                  message: "Invalid format in the path field"
                }
              ]} = ErrorPage.__guarded_change__(%{path: "/bad path"})
    end
  end

  describe "direct __guarded_change__/1 — root_layout_template sanitize" do
    test "zero-width unicode characters are stripped" do
      assert {:ok, %{root_layout_template: "<html>hello</html>"}} =
               ErrorPage.__guarded_change__(%{
                 root_layout_template: "<html>he​llo</html>"
               })
    end

    test "tab and newline survive (legitimate template whitespace)" do
      assert {:ok, %{root_layout_template: "<html>\n\ttab\n</html>"}} =
               ErrorPage.__guarded_change__(%{
                 root_layout_template: "<html>\n\ttab\n</html>"
               })
    end
  end

  describe "direct __guarded_change__/1 — error_pages + helpers (array-of-map)" do
    test "list accepted; non-list rejected" do
      assert {:ok,
              %{
                error_pages: [%{status: 404, template: "<div>404</div>"}],
                helpers: [%{name: "fmt", code: "fn x -> x end"}]
              }} =
               ErrorPage.__guarded_change__(%{
                 error_pages: [%{status: 404, template: "<div>404</div>"}],
                 helpers: [%{name: "fmt", code: "fn x -> x end"}]
               })

      assert {:error,
              [
                %{
                  field: :error_pages,
                  action: :list,
                  message: _
                }
              ]} = ErrorPage.__guarded_change__(%{error_pages: "not a list"})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    # THE GUARDED STRUCT STILL GUARDS — it validates what is STORED, and what is stored is no longer
    # what the caller sent. `Changes.ErrorPageAddress` writes the site's own address over both of
    # these, which is why the traversal below is not refused but overwritten: there is no longer a
    # way to put one in this column, which is a stronger answer than refusing it. What the regex
    # goes on protecting is the value that lands, and this pins that it lands in a shape the rule
    # accepts.
    test "the site's address is what is stored, and it satisfies the path rule", %{
      site_id: site_id
    } do
      address = ErrorAddress.for_site(site_id)

      good = %{
        name: "GS Error Pages",
        path: "/errors/*",
        error_pages: [%{status: 404, template: "<div>404</div>"}]
      }

      assert {:ok, %ErrorPage{path: ^address}} =
               ErrorPage
               |> Ash.Changeset.for_create(:create, good, tenant: site_id, authorize?: false)
               |> Ash.create()

      refute address =~ ".."
      assert address =~ ~r"^/[a-zA-Z0-9/_*.:-]*$"
    end

    # AND A TRAVERSAL CANNOT BE SMUGGLED PAST IT EITHER. The column is written from the site name,
    # and a site's name is slugified on the way in, so there is no caller-controlled text between
    # the two that could carry one.
    test "a path a caller asks for never reaches the column", %{site_id: site_id} do
      bad = %{
        name: "GS Bad Errors",
        path: "/../etc/passwd",
        error_pages: [%{status: 500, template: "<div>boom</div>"}]
      }

      assert {:ok, %ErrorPage{path: path}} =
               ErrorPage
               |> Ash.Changeset.for_create(:create, bad, tenant: site_id, authorize?: false)
               |> Ash.create()

      refute path =~ "etc/passwd"
      assert path == ErrorAddress.for_site(site_id)
    end
  end
end
