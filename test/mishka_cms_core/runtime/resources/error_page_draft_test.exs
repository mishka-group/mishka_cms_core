defmodule MishkaCmsCore.Runtime.ErrorPageDraftTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import MishkaCmsCore.Test.Factory
  require Ash.Query
  @moduletag :integration

  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage, ErrorPageDraft, RuntimePreview}

  @pages [
    %{status: 404, template: "<h1>Not Found</h1>"},
    %{status: 500, template: "<h1>Server Error</h1>"}
  ]

  defp create_draft!(attrs) do
    ErrorPageDraft
    |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp publish!(draft) do
    draft
    |> Ash.Changeset.for_update(:master_publish, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp error_page_by_path(path) do
    ErrorPage
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(path == ^path)
    |> Ash.read_one!(authorize?: false)
  end

  defp error_page_by_id(id) do
    ErrorPage
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp statuses(error_pages),
    do: error_pages |> Enum.map(&(Map.get(&1, "status") || Map.get(&1, :status))) |> Enum.sort()

  test "a brand-new error-page draft auto-generates a token and starts unpublished" do
    site = create_site!()

    draft =
      create_draft!(%{name: "Errors", path: "/errors", error_pages: @pages, site_id: site.id})

    assert is_binary(draft.preview_token) and byte_size(draft.preview_token) > 20
    assert draft.status == :draft
    assert length(draft.error_pages) == 2
  end

  test "publishing creates the live error page with its error_pages collection" do
    site = create_site!()

    create_draft!(%{
      name: "Site Errors",
      path: "/site-errors",
      error_pages: @pages,
      site_id: site.id
    })
    |> publish!()

    # PUBLISHED AT THE SITE'S ADDRESS, not at the one the draft was given: publishing goes through
    # the live resource's create, and `Changes.ErrorPageAddress` writes the path there for every
    # caller. See `MishkaCmsCore.Runtime.ErrorAddress`.
    assert statuses(error_page_by_path(ErrorAddress.for_site(site.id)).error_pages) == [404, 500]
  end

  test "publishing with source_error_page_id updates the existing error page" do
    site = create_site!()
    ep = create_error_page!(site_id: site.id)

    create_draft!(%{
      name: ep.name,
      path: ep.path,
      error_pages: [%{status: 418, template: "<h1>Teapot</h1>"}],
      source_error_page_id: ep.id,
      site_id: site.id
    })
    |> publish!()

    assert 418 in statuses(error_page_by_id(ep.id).error_pages)
  end

  test "the Code-editor source round-trips through the error_pages collection" do
    site = create_site!()

    draft =
      create_draft!(%{name: "RoundTrip", path: "/rt", error_pages: @pages, site_id: site.id})

    source = RuntimePreview.source(draft)
    assert source =~ "<!-- 404 -->"
    assert source =~ "<!-- 500 -->"

    parsed = RuntimePreview.parse_error_pages(source)
    assert Enum.map(parsed, & &1.status) == [404, 500]
    assert Enum.at(parsed, 0).template == "<h1>Not Found</h1>"
  end

  test "an error page can have multiple labeled drafts, paginated with a count" do
    site = create_site!()
    ep = create_error_page!(site_id: site.id)

    for i <- 1..7 do
      create_draft!(%{
        name: "draft-#{i}",
        path: ep.path,
        error_pages: [%{status: 400 + i, template: "<h1>#{i}</h1>"}],
        source_error_page_id: ep.id,
        label: "Label #{i}",
        site_id: site.id
      })
    end

    first =
      ErrorPageDraft
      |> Ash.Query.for_read(:master_drafts_for_error_page, %{source_error_page_id: ep.id},
        authorize?: false
      )
      |> Ash.read!(page: [limit: 5, offset: 0, count: true], authorize?: false)

    assert first.count == 7
    assert length(first.results) == 5
  end
end
