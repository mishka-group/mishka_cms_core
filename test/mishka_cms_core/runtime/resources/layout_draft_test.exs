defmodule MishkaCmsCore.Runtime.LayoutDraftTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import MishkaCmsCore.Test.Factory
  require Ash.Query
  @moduletag :integration

  alias MishkaCmsCore.Runtime.{Layout, LayoutDraft}

  @tmpl "<body>{@inner_content}</body>"

  defp create_draft!(attrs) do
    LayoutDraft
    |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp publish!(draft) do
    draft
    |> Ash.Changeset.for_update(:master_publish, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp layout_by_path(path) do
    Layout
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(path == ^path)
    |> Ash.read_one!(authorize?: false)
  end

  defp layout_by_id(id) do
    Layout
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  test "a brand-new layout draft auto-generates a token and starts unpublished" do
    site = create_site!()

    draft =
      create_draft!(%{
        name: "Hero Layout",
        path: "/layouts/hero",
        template: @tmpl,
        site_id: site.id
      })

    assert is_binary(draft.preview_token) and byte_size(draft.preview_token) > 20
    assert draft.status == :draft
    assert is_nil(draft.applied_at)
  end

  test "publishing a draft-only layout draft creates the live layout" do
    site = create_site!()

    draft =
      create_draft!(%{
        name: "New Layout",
        path: "/layouts/new",
        template: @tmpl,
        site_id: site.id
      })

    published = publish!(draft)
    assert published.status == :published

    layout = layout_by_path("/layouts/new")
    assert layout.template == @tmpl
    assert layout.site_id == site.id
  end

  test "publishing a draft with source_layout_id updates the existing layout" do
    site = create_site!()
    layout = create_layout!(site_id: site.id)

    create_draft!(%{
      name: layout.name,
      path: layout.path,
      template: "<body>UPDATED {@inner_content}</body>",
      source_layout_id: layout.id,
      site_id: site.id
    })
    |> publish!()

    assert layout_by_id(layout.id).template =~ "UPDATED"
  end

  test "a GLOBAL layout draft (no site) creates a global layout on publish" do
    draft =
      create_draft!(%{
        name: "Global Layout",
        path: "/layouts/global",
        template: @tmpl,
        site_id: nil
      })

    assert is_nil(draft.site_id)

    published = publish!(draft)
    assert published.status == :published

    layout = layout_by_path("/layouts/global")
    assert layout
    assert is_nil(layout.site_id)
  end

  test "a layout can have multiple labeled drafts, listed paginated newest-first with a count" do
    site = create_site!()
    layout = create_layout!(site_id: site.id)

    for i <- 1..7 do
      create_draft!(%{
        name: "draft-#{i}",
        path: layout.path,
        template: "<body>#{i} {@inner_content}</body>",
        source_layout_id: layout.id,
        label: "Label #{i}",
        site_id: site.id
      })
    end

    first =
      LayoutDraft
      |> Ash.Query.for_read(:master_drafts_for_layout, %{source_layout_id: layout.id},
        authorize?: false
      )
      |> Ash.read!(page: [limit: 5, offset: 0, count: true], authorize?: false)

    assert first.count == 7
    assert length(first.results) == 5
    assert hd(first.results).label == "Label 7"
  end

  test "example HTML is stored (for rendering real content inside the layout preview)" do
    site = create_site!()

    draft =
      create_draft!(%{
        name: "Layout With Example",
        path: "/layouts/ex",
        template: @tmpl,
        example: "<h1 class=\"text-2xl\">Hello</h1>",
        site_id: site.id
      })

    assert draft.example == "<h1 class=\"text-2xl\">Hello</h1>"
  end
end
