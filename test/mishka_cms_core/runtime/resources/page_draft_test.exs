# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageDraftTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import MishkaCmsCore.Test.Factory
  require Ash.Query
  @moduletag :integration

  alias MishkaCmsCore.Runtime.{Page, PageDraft}
  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook
  alias MishkaCmsCore.Test.EventCannotRun

  # A FIXTURE, NOT AN AUTHOR: it has no actor, so it says what it is — the code check applies to a
  # person writing code into a draft. See `MishkaCmsCore.Runtime.Resources.Validations.CodeChange`.
  defp create_draft!(site_id, attrs) do
    PageDraft
    |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, context: %{page_code: :package})
    |> Ash.create!(authorize?: false)
  end

  defp publish!(draft, site_id) do
    draft
    |> Ash.Changeset.for_update(:publish, %{}, tenant: site_id)
    |> Ash.update!(authorize?: false)
  end

  defp page_by_path(site_id, path) do
    Page
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(path == ^path and site_id == ^site_id)
    |> Ash.read_one!(authorize?: false)
  end

  test "a brand-new draft auto-generates a token and starts unpublished" do
    site = create_site!()

    draft =
      create_draft!(site.id, %{
        name: "New Hero",
        title: "New Hero",
        path: "/hero",
        template: "<h1>hi</h1>"
      })

    assert is_binary(draft.preview_token) and byte_size(draft.preview_token) > 20
    assert draft.status == :draft
    assert is_nil(draft.applied_at)
    assert is_nil(draft.source_page_id)
  end

  test "publishing a draft-only draft creates the live page and marks the draft published" do
    site = create_site!()

    draft =
      create_draft!(site.id, %{
        name: "Brand New",
        title: "Brand New",
        path: "/brand-new",
        template: "<h1>new</h1>"
      })

    published = publish!(draft, site.id)

    assert published.status == :published
    assert published.applied_at

    page = page_by_path(site.id, "/brand-new")
    assert page
    assert page.template == "<h1>new</h1>"
  end

  test "publishing a draft with source_page_id updates the existing page" do
    site = create_site!()
    page = create_page!(site_id: site.id)

    draft =
      create_draft!(site.id, %{
        name: page.name,
        title: page.title,
        path: page.path,
        template: "<p>updated body</p>",
        source_page_id: page.id
      })

    publish!(draft, site.id)

    reloaded =
      Page
      |> Ash.Query.for_read(:read_any)
      |> Ash.Query.filter(id == ^page.id)
      |> Ash.read_one!(authorize?: false)

    assert reloaded.template == "<p>updated body</p>"
  end

  # THE LIVE PAGE KEEPS ITS OWN CODE. The builder's code drawer writes it to the page itself, and a
  # draft only holds the copy it forked. Publishing wrote that copy back: a draft taken before any
  # code deleted every handler saved since, and one taken before a change made the publish refuse.
  for {shape, draft_code} <- [
        {"no code", []},
        {"older code", [%{name: "taken_with", code: "{:noreply, socket}"}]}
      ] do
    test "publishing a draft holding #{shape} keeps the page's own code" do
      site = create_site!()

      page =
        create_page!(
          site_id: site.id,
          events: [%{name: "saved_since", code: "{:noreply, socket}"}],
          infos: [%{name: ":saved_since", code: "{:noreply, socket}"}],
          helpers: [%{name: "saved_since", args: "", code: ":ok"}]
        )

      draft =
        create_draft!(site.id, %{
          name: page.name,
          title: page.title,
          path: page.path,
          template: "<p>from the draft</p>",
          source_page_id: page.id,
          events: unquote(Macro.escape(draft_code)),
          infos: unquote(Macro.escape(draft_code)),
          helpers: []
        })

      publish!(draft, site.id)

      reloaded =
        Page
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(id == ^page.id)
        |> Ash.read_one!(authorize?: false)

      assert reloaded.template == "<p>from the draft</p>"

      for {field, kept} <- [events: "saved_since", infos: ":saved_since", helpers: "saved_since"] do
        names = reloaded |> Map.get(field) |> Enum.map(&(Map.get(&1, :name) || &1["name"]))

        assert names == [kept], "the draft's #{field} replaced the page's"
      end
    end
  end

  test "preview tokens are unique across drafts" do
    site = create_site!()
    d1 = create_draft!(site.id, %{name: "One", title: "One", path: "/one", template: "<i>1</i>"})
    d2 = create_draft!(site.id, %{name: "Two", title: "Two", path: "/two", template: "<i>2</i>"})

    refute d1.preview_token == d2.preview_token
  end

  test "a tenant-scoped read does NOT see another site's draft (multitenancy isolation)" do
    site_a = create_site!()
    site_b = create_site!()

    draft =
      create_draft!(site_a.id, %{
        name: "Alpha draft",
        title: "Alpha draft",
        path: "/a",
        template: "<i>alpha</i>"
      })

    # The primary :read scoped to site_b must not return site_a's draft.
    assert {:ok, []} =
             MishkaCmsCore.Runtime.PageDraft
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(id == ^draft.id)
             |> Ash.read(tenant: site_b.id, authorize?: false)

    # ...but scoped to its own site it is found.
    assert {:ok, [%{id: found_id}]} =
             MishkaCmsCore.Runtime.PageDraft
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(id == ^draft.id)
             |> Ash.read(tenant: site_a.id, authorize?: false)

    assert found_id == draft.id
  end

  # `TenantContext`'s master branch — "this action requires a master user" — reads the actor the
  # changeset was BUILT with; `Ash.destroy(actor: …)` after the fact does not reach it. So a tenant
  # named on the changeset is refused, and a changeset built with NO actor is refused too: a missing
  # actor is nobody, never a master. That is why every draft write in `PageBuilder.Drafts` and the
  # preview bar names its actor where the changeset is built.
  test "the master destroy refuses a tenant actor named on the changeset, and one built with none" do
    site = create_site!()
    other = create_site!()
    tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: other.id)

    # Written through the master action, so the row carries no tenant of its own and the branch
    # under test is the one that reads the ACTOR rather than the one that reads the tenant.
    master_draft = fn name ->
      PageDraft
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          site_id: site.id,
          name: name,
          title: name,
          path: "/#{name}",
          template: "<i>#{name}</i>"
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
    end

    assert {:error, error} =
             master_draft.("named-actor")
             |> Ash.Changeset.for_destroy(:master_destroy, %{}, actor: tenant)
             |> Ash.destroy(actor: tenant)

    assert Exception.message(error) =~ "requires a master user"

    unnamed = master_draft.("unnamed-actor")

    assert {:error, %Ash.Error.Forbidden{} = error} =
             unnamed
             |> Ash.Changeset.for_destroy(:master_destroy)
             |> Ash.destroy(actor: tenant)

    assert Exception.message(error) =~ "requires a master user"
    assert {:ok, _} = Ash.get(PageDraft, unnamed.id, action: :master_get, authorize?: false)
  end

  test "by_token resolves a draft regardless of tenant" do
    site = create_site!()

    draft =
      create_draft!(site.id, %{name: "Tok", title: "Tok", path: "/tok", template: "<i>t</i>"})

    found =
      PageDraft
      |> Ash.Query.for_read(:by_token, %{preview_token: draft.preview_token})
      |> Ash.read_one!(authorize?: false)

    assert found.id == draft.id
  end

  test "label is stored verbatim (name is slugified, label is not)" do
    site = create_site!()

    draft =
      create_draft!(site.id, %{
        name: "My Page",
        title: "My Page",
        path: "/p",
        template: "<h1>x</h1>",
        label: "Hero Redesign v2"
      })

    assert draft.label == "Hero Redesign v2"
    assert draft.name == "my-page"
  end

  test "a page can have multiple labeled drafts, listed paginated newest-first with a count" do
    site = create_site!()
    page = create_page!(site_id: site.id)

    for i <- 1..7 do
      create_draft!(site.id, %{
        name: "draft-#{i}",
        title: "Draft #{i}",
        path: page.path,
        template: "<h1>#{i}</h1>",
        source_page_id: page.id,
        label: "Label #{i}"
      })
    end

    first =
      PageDraft
      |> Ash.Query.for_read(:master_drafts_for_page, %{source_page_id: page.id},
        authorize?: false
      )
      |> Ash.read!(page: [limit: 5, offset: 0, count: true], authorize?: false)

    assert first.count == 7
    assert length(first.results) == 5
    assert hd(first.results).label == "Label 7"

    second =
      PageDraft
      |> Ash.Query.for_read(:master_drafts_for_page, %{source_page_id: page.id},
        authorize?: false
      )
      |> Ash.read!(page: [limit: 5, offset: 5, count: true], authorize?: false)

    assert length(second.results) == 2

    # Each draft is fully independent — its own preview token (hence its own compiled preview).
    tokens =
      (first.results ++ second.results) |> Enum.map(& &1.preview_token) |> Enum.uniq()

    assert length(tokens) == 7
  end

  test "drafts_for_page (tenant) only lists the tenant's own page drafts, unpublished only" do
    site = create_site!()
    page = create_page!(site_id: site.id)

    pending =
      create_draft!(site.id, %{
        name: "pending",
        title: "Pending",
        path: page.path,
        template: "<i>p</i>",
        source_page_id: page.id
      })

    to_publish =
      create_draft!(site.id, %{
        name: "done",
        title: "Done",
        path: page.path,
        template: "<i>d</i>",
        source_page_id: page.id
      })

    publish!(to_publish, site.id)

    listed =
      PageDraft
      |> Ash.Query.for_read(:drafts_for_page, %{source_page_id: page.id})
      |> Ash.read!(page: [limit: 5, offset: 0, count: true], tenant: site.id, authorize?: false)

    ids = Enum.map(listed.results, & &1.id)
    assert pending.id in ids
    refute to_publish.id in ids
  end

  # A DELETE IS THE RESOURCE'S ALONE. What else a deleted draft takes with it — the editor releases
  # its editing history — hangs off the announcements its two destroy actions fire after they
  # commit, so with nothing able to answer them (no editor installed) the draft still goes, and the
  # delete answers as it always does.
  describe "a draft deleted with nothing listening on its destroy" do
    setup do
      EventCannotRun.stub!([
        PluginHook.event_name(PageDraft, :destroy),
        PluginHook.event_name(PageDraft, :master_destroy)
      ])
    end

    test "is gone, through a site admin's destroy and a master's" do
      site = create_site!()

      for action <- [:destroy, :master_destroy] do
        draft =
          create_draft!(site.id, %{
            name: "gone-#{action}",
            title: "Gone",
            path: "/gone-#{action}",
            template: "<i>gone</i>"
          })

        assert :ok =
                 draft
                 |> Ash.Changeset.for_destroy(action, %{}, tenant: site.id, authorize?: false)
                 |> Ash.destroy(authorize?: false)

        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.get(PageDraft, draft.id, action: :master_get, authorize?: false),
               "the #{action} left the draft behind"
      end
    end
  end
end
