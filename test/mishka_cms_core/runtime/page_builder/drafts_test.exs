defmodule MishkaCmsCore.Runtime.PageBuilder.DraftsTest do
  @moduledoc """
  The draft façade's own rules, as against the resources'.

  Everything here is about the CAP: one row per editing session means the count grows with use, so
  the façade drops the oldest as a new one is made. The resources themselves are uncapped on
  purpose — a migration, a seed or a test may write as many as it likes — which is why these tests
  go through `Drafts` rather than through `Ash.create`.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import MishkaCmsCore.Test.Factory
  @moduletag :integration

  alias MishkaCmsCore.Runtime.PageBuilder.Drafts
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.States.AssetsState

  setup do
    site = create_site!()
    page = create_page!(site_id: site.id)
    master = create_user_with_permissions!(["*"])

    {:ok, site: site, page: page, master: master}
  end

  defp save!(page, actor, label) do
    {:ok, draft} = Drafts.save_as("page", page, nil, "<p>#{label}</p>", actor, nil, label, nil)
    draft
  end

  defp labels(page, actor), do: "page" |> Drafts.list(page, actor) |> Enum.map(& &1.label)

  # An error page's draft keeps one template per status, so an assertion about a template has to say
  # which status it is reading — the whole hazard here is work arriving under the wrong one.
  defp by_status(draft) do
    Map.new(draft.error_pages, fn entry ->
      {entry["status"] || entry[:status], entry["template"] || entry[:template]}
    end)
  end

  # A DRAFT'S PREVIEW CSS IS COMPILED ONCE AND KEYED BY THE DRAFT'S TOKEN. `ensure_css/2` compiles
  # only when the key is absent — which is what keeps opening a preview cheap, and also meant every
  # edit after the first preview was served against the stylesheet of the version before it. A class
  # typed a moment ago had no rule, so the element it was typed on drew unstyled and nothing told the
  # author that apart from the result looking wrong.
  describe "the preview stylesheet" do
    test "is dropped when the draft it belongs to is written again", %{
      page: page,
      master: master
    } do
      draft = save!(page, master, "First")
      assert is_binary(draft.preview_token)

      AssetsState.save(%{
        id: draft.preview_token,
        type: "css",
        value: ".stale{}",
        hash: "deadbeef",
        updated_at: DateTime.utc_now()
      })

      assert AssetsState.exists?(draft.preview_token, "css")

      {:ok, _same} =
        Drafts.autosave(
          "page",
          page,
          ~s(<p class="mt-9">again</p>),
          master,
          draft.id,
          "First",
          nil
        )

      refute AssetsState.exists?(draft.preview_token, "css"),
             "the preview kept serving the stylesheet of the version before the edit"
    end

    test "and again when it is saved under a name", %{page: page, master: master} do
      draft = save!(page, master, "First")

      AssetsState.save(%{
        id: draft.preview_token,
        type: "css",
        value: ".stale{}",
        hash: "deadbeef",
        updated_at: DateTime.utc_now()
      })

      {:ok, _renamed} =
        Drafts.save_as("page", page, nil, "<p>renamed</p>", master, draft.id, "Second", nil)

      refute AssetsState.exists?(draft.preview_token, "css")
    end
  end

  describe "prune" do
    test "a document keeps the newest drafts and drops the rest", %{page: page, master: master} do
      for i <- 1..(Drafts.keep() + 3), do: save!(page, master, "Sitting #{i}")

      kept = labels(page, master)

      assert length(kept) == Drafts.keep()
      assert "Sitting #{Drafts.keep() + 3}" in kept
      refute "Sitting 1" in kept
      refute "Sitting 3" in kept
      assert "Sitting 4" in kept
    end

    test "under the cap nothing is dropped", %{page: page, master: master} do
      for i <- 1..3, do: save!(page, master, "Sitting #{i}")

      assert length(labels(page, master)) == 3
    end

    test "writing to an existing draft does not drop anything", %{page: page, master: master} do
      for i <- 1..Drafts.keep(), do: save!(page, master, "Sitting #{i}")
      [newest | _rest] = Drafts.list("page", page, master)

      {:ok, _same} =
        Drafts.autosave("page", page, "<p>again</p>", master, newest.id, newest.label, nil)

      kept = labels(page, master)
      assert length(kept) == Drafts.keep()
      assert "Sitting 1" in kept
    end

    test "another document's drafts are not counted or dropped", %{
      site: site,
      page: page,
      master: master
    } do
      other = create_page!(site_id: site.id)
      keeper = save!(other, master, "Elsewhere")

      for i <- 1..(Drafts.keep() + 2), do: save!(page, master, "Sitting #{i}")

      assert labels(other, master) == ["Elsewhere"]
      assert Ash.get!(PageDraft, keeper.id, action: :master_get, authorize?: false)
    end

    test "a published draft is left alone, because it is the record of a publish", %{
      site: site,
      page: page,
      master: master
    } do
      applied =
        PageDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: page.name,
            title: page.title,
            path: page.path,
            template: "<p>out</p>",
            source_page_id: page.id
          },
          tenant: site.id
        )
        |> Ash.create!(authorize?: false)
        |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      for i <- 1..(Drafts.keep() + 2), do: save!(page, master, "Sitting #{i}")

      assert length(labels(page, master)) == Drafts.keep()
      assert Ash.get!(PageDraft, applied.id, action: :master_get, authorize?: false).applied_at
    end

    test "a tenant prunes its own document the same way", %{site: site} do
      page = create_page!(site_id: site.id)
      tenant = create_user_with_permissions!(["*"], site_id: site.id)

      for i <- 1..(Drafts.keep() + 1), do: save!(page, tenant, "Sitting #{i}")

      assert length(labels(page, tenant)) == Drafts.keep()
      refute "Sitting 1" in labels(page, tenant)
    end
  end

  # PUBLISHING A DRAFT WRITES ITS FIELDS OVER THE LIVE PAGE — the inspector's draft picker lists the
  # editor's drafts beside its own — so a field the draft never took from the page comes back as its
  # default.
  describe "the fields a draft takes from its page" do
    setup %{site: site, page: original} do
      layout =
        create_layout!(
          site_id: site.id,
          path: "/layouts/drafts-#{System.unique_integer([:positive])}"
        )

      translation =
        create_page!(
          site_id: site.id,
          path: "/fa/drafts-#{System.unique_integer([:positive])}",
          language: "fa",
          language_group_id: original.id,
          layout_id: layout.id,
          section: "company",
          active: false,
          seo_tags: [%{tag: "meta", attrs: %{"name" => "description"}, content: "درباره"}]
        )

      %{translation: translation, layout: layout}
    end

    test "are every one its create accepts", %{translation: translation, master: master} do
      draft = save!(translation, master, "Sitting")

      assert %{language: "fa", section: "company", active: false} = draft
      assert draft.language_group_id == translation.language_group_id
      assert draft.layout_id == translation.layout_id
      assert [%{"content" => "درباره"}] = Enum.map(draft.seo_tags, &stringify/1)
    end

    test "so publishing one changes the template and nothing else", %{
      site: site,
      translation: translation,
      master: master
    } do
      translation
      |> save!(master, "Sitting")
      |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      published =
        Ash.get!(MishkaCmsCore.Runtime.Page, translation.id,
          action: :master_get,
          authorize?: false
        )

      kept = [:language, :language_group_id, :layout_id, :section, :active]

      assert published.template == "<p>Sitting</p>"
      assert Map.take(published, kept) == Map.take(translation, kept)
    end

    # AND A COPY TAKES THEM FROM THE DRAFT IT COPIES, not from the page as it stands today. The two
    # part company the moment anyone edits the live page — the Configuration form, another draft
    # published — and a fork that read the page handed the author a copy of today's settings under a
    # "Copied to …" flash. Publishing that copy then writes them back over the page.
    test "while a copy takes them from the draft it was made from", %{
      translation: translation,
      master: master
    } do
      draft = save!(translation, master, "Sitting")

      moved =
        translation
        |> Ash.Changeset.for_update(:master_update, %{section: "landing"},
          actor: master,
          authorize?: false
        )
        |> Ash.update!(authorize?: false)

      {:ok, copy} =
        Drafts.save_as("page", moved, draft, "<p>copied</p>", master, nil, "Sitting copy", nil)

      assert moved.section == "landing"
      assert copy.section == "company", "the copy took the page's section, not the draft's"
      assert copy.layout_id == draft.layout_id
      assert copy.template == "<p>copied</p>"
      assert copy.source_page_id == translation.id
    end

    # AND A FIELD THE DRAFT HAS NONE OF STAYS NONE. Filling a copy's blanks from the page makes it
    # something its source is not — this page had no layout when it was drafted and has one now — and
    # the two then publish differently, which is the one thing a copy may not do.
    test "while a field the draft has none of stays out of the copy", %{
      page: page,
      layout: layout,
      master: master
    } do
      draft = save!(page, master, "Sitting")
      refute draft.layout_id, "the fixture page already had a layout, so there is nothing to miss"

      given_a_layout =
        page
        |> Ash.Changeset.for_update(:master_update, %{layout_id: layout.id},
          actor: master,
          authorize?: false
        )
        |> Ash.update!(authorize?: false)

      {:ok, copy} =
        Drafts.save_as(
          "page",
          given_a_layout,
          draft,
          "<p>copied</p>",
          master,
          nil,
          "Sitting copy",
          nil
        )

      assert given_a_layout.layout_id == layout.id
      refute copy.layout_id, "the copy took a layout the draft it copies has never had"
    end
  end

  # AN ERROR PAGE'S DRAFT IS A SNAPSHOT OF EVERY STATUS IT DEFINES, so a write has to say which entry
  # it replaces. Everything above drives a page, where there is no such argument to get wrong, and
  # that is why nothing here caught the caller that left it off and wrote the 500 into the 404.
  describe "an error page's draft" do
    setup %{site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<p>Not found</p>", "layout" => %{}},
            %{"status" => 500, "template" => "<p>Boom</p>", "layout" => %{}}
          ]
        )

      %{error_page: error_page}
    end

    test "is written to the status it was given, and leaves the others as they were", %{
      error_page: error_page,
      master: master
    } do
      {:ok, draft} =
        Drafts.autosave("error-page", error_page, "<p>edited</p>", master, nil, "Sitting", 500)

      assert by_status(draft)[500] == "<p>edited</p>"
      assert by_status(draft)[404] == "<p>Not found</p>", "the edit landed on the wrong status"
    end

    # THE SECOND WRITE READS THE DRAFT, NOT THE RECORD. The first status's work exists only in the
    # draft, so taking the list from the live error page would put the published 500 back over it.
    test "and writing another status keeps what the first write put there", %{
      error_page: error_page,
      master: master
    } do
      {:ok, draft} =
        Drafts.autosave("error-page", error_page, "<p>edited</p>", master, nil, "Sitting", 500)

      {:ok, same} =
        Drafts.autosave(
          "error-page",
          error_page,
          "<p>fresh</p>",
          master,
          draft.id,
          "Sitting",
          404
        )

      assert same.id == draft.id
      assert by_status(same)[404] == "<p>fresh</p>"
      assert by_status(same)[500] == "<p>edited</p>", "the sitting's other status was rolled back"
    end

    # AND A COPY OF THE DRAFT KEEPS ALL FIVE. `error_pages` is one field like any other, so a create
    # that read the live record put the published markup back over every status but the one being
    # written — the author forked from the 404 and lost the 500 they had edited an hour earlier,
    # under a flash that said the draft had been copied.
    test "and a copy of it keeps the statuses the copy is not writing", %{
      error_page: error_page,
      master: master
    } do
      {:ok, draft} =
        Drafts.autosave("error-page", error_page, "<p>edited</p>", master, nil, "Sitting", 500)

      {:ok, copy} =
        Drafts.save_as(
          "error-page",
          error_page,
          draft,
          "<p>copied</p>",
          master,
          nil,
          "Sitting copy",
          404
        )

      assert by_status(copy)[404] == "<p>copied</p>"
      assert by_status(copy)[500] == "<p>edited</p>", "the copy rolled the other status back"
    end

    # AND THE STATUS CANNOT BE LEFT OFF THE CALL. A default for it is a caller writing the 404 by
    # accident — the editor's way out did exactly that — so both entry points take it, and a section
    # with one template answers `nil` at the call site rather than by saying nothing. The same rule
    # covers the source a copy is taken from: `save_as/8` asks for it, and a fork that forgets it is
    # a compile error rather than a copy of the live record.
    test "and neither entry point has a shorter form to forget it in" do
      writes =
        Drafts.__info__(:functions)
        |> Enum.filter(fn {name, _arity} -> name in [:autosave, :save_as] end)

      assert writes == [autosave: 7, save_as: 8]
    end
  end

  # A DRAFT REMEMBERS THE DOCUMENT IT WAS MADE FROM, as a hash, so the editor can say the original
  # changed since — a notice, nothing is blocked.
  describe "the original a draft was made from" do
    defp reread_page(page),
      do: Ash.get!(MishkaCmsCore.Runtime.Page, page.id, action: :read_any, authorize?: false)

    defp change_page!(page, attrs) do
      page
      |> Ash.Changeset.for_update(:update, attrs, tenant: page.site_id, authorize?: false)
      |> Ash.update!(authorize?: false)
    end

    test "is fingerprinted when the draft is made, the same way every time it is read", %{
      page: page,
      master: master
    } do
      draft = save!(page, master, "Fingerprinted")

      assert draft.source_hash == Drafts.hash("page", page)
      assert Drafts.hash("page", reread_page(page)) == Drafts.hash("page", page)
      refute Drafts.original_changed?("page", reread_page(page), draft)
      refute Drafts.original_changed?(draft)
    end

    test "says so once the original is changed, and only then", %{page: page, master: master} do
      draft = save!(page, master, "Before the change")
      changed = change_page!(page, %{title: "Changed elsewhere"})

      assert Drafts.original_changed?("page", changed, draft)
      assert Drafts.original_changed?(draft)
    end

    test "a copy of a draft is as old as that draft", %{page: page, master: master} do
      older = save!(page, master, "Older")
      changed = change_page!(page, %{title: "Changed after the older draft"})

      {:ok, copy} =
        Drafts.save_as("page", changed, older, "<p>copy</p>", master, nil, "Copy", nil)

      assert copy.source_hash == older.source_hash
      assert Drafts.original_changed?("page", changed, copy)
    end

    test "a draft with no fingerprint, or a published one, never says so", %{
      page: page,
      master: master
    } do
      draft = save!(page, master, "Quiet")
      changed = change_page!(page, %{title: "Changed"})

      refute Drafts.original_changed?("page", changed, %{draft | source_hash: nil})
      refute Drafts.original_changed?("page", changed, %{draft | status: :published})
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
