# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.SiteReferencesTest do
  @moduledoc """
  Which records a site's record may name by id.

  One rule across every runtime resource that points at another site-owned record: a page's layout,
  a draft's layout and its live record, a media file's category. The record named belongs to the
  same site, or — where the target can be shared — to no site. Whoever writes, the system included:
  a page wrapped in another site's layout shows that site's template on this one.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Runtime.{ErrorPageDraft, LayoutDraft, Media, Page, PageDraft}

  @moduletag :unit

  setup do
    site = create_site!()
    other = create_site!()
    star = create_user_with_permissions!(["*"], site_id: site.id)

    %{site: site, other: other, star: star}
  end

  defp create_as(resource, action, attrs, actor, tenant) do
    resource
    |> Ash.Changeset.for_create(action, attrs, actor: actor, tenant: tenant)
    |> Ash.create(actor: actor)
  end

  defp update_as(record, attrs, actor, tenant) do
    record
    |> Ash.Changeset.for_update(:update, attrs, actor: actor, tenant: tenant)
    |> Ash.update(actor: actor)
  end

  defp unique, do: System.unique_integer([:positive])

  defp master!, do: create_user_with_permissions!(["*"])

  defp page_draft!(site_id) do
    n = unique()

    PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Draft #{n}", title: "Draft #{n}", path: "/draft-#{n}", template: "<div></div>"},
      tenant: site_id,
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp page_attrs(extra) do
    n = unique()
    Map.merge(%{title: "Page #{n}", path: "/page-#{n}", template: "<div>page</div>"}, extra)
  end

  describe "a page's layout" do
    test "is never another site's, on create", context do
      theirs = create_layout!(site_id: context.other.id)

      assert {:error, error} =
               create_as(
                 Page,
                 :create,
                 page_attrs(%{layout_id: theirs.id}),
                 context.star,
                 context.site.id
               )

      assert Exception.message(error) =~ "layout"
    end

    test "nor on update", context do
      theirs = create_layout!(site_id: context.other.id)
      page = create_page!(site_id: context.site.id)

      assert {:error, _refused} =
               update_as(page, %{layout_id: theirs.id}, context.star, context.site.id)

      assert Ash.get!(Page, page.id, tenant: context.site.id, authorize?: false).layout_id ==
               page.layout_id
    end

    test "nor when the system writes it", context do
      theirs = create_layout!(site_id: context.other.id)
      page = create_page!(site_id: context.site.id)

      assert {:error, _refused} =
               page
               |> Ash.Changeset.for_update(:update, %{layout_id: theirs.id},
                 tenant: context.site.id,
                 authorize?: false
               )
               |> Ash.update(authorize?: false)
    end

    test "is the site's own or a shared one", context do
      own = create_layout!(site_id: context.site.id)
      shared = create_layout!(site_id: nil)

      assert {:ok, page} =
               create_as(
                 Page,
                 :create,
                 page_attrs(%{layout_id: own.id}),
                 context.star,
                 context.site.id
               )

      assert {:ok, %{layout_id: shared_id}} =
               update_as(page, %{layout_id: shared.id}, context.star, context.site.id)

      assert shared_id == shared.id
    end

    test "a draft names none of another site's either", context do
      theirs = create_layout!(site_id: context.other.id)
      source = create_page!(site_id: context.site.id)
      n = unique()

      assert {:error, _refused} =
               create_as(
                 PageDraft,
                 :create,
                 %{
                   source_page_id: source.id,
                   layout_id: theirs.id,
                   name: "Draft #{n}",
                   title: "Draft #{n}",
                   path: "/draft-#{n}",
                   template: "<div></div>"
                 },
                 context.star,
                 context.site.id
               )
    end
  end

  describe "the layout a page is wrapped in" do
    setup context do
      theirs = create_layout!(site_id: context.other.id, description: "B-SECRET-LAYOUT")
      page = create_page!(site_id: context.site.id)

      # A row written before the rule: the reference is there, and the read must not follow it.
      MishkaCmsCore.Repo.query!("UPDATE pages SET layout_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(theirs.id),
        Ecto.UUID.dump!(page.id)
      ])

      %{theirs: theirs, page: page}
    end

    test "is never another site's, for a site user", context do
      assert {:ok, %{loaded_layout: nil}} =
               Page
               |> Ash.Query.filter(id == ^context.page.id)
               |> Ash.Query.load([:loaded_layout])
               |> Ash.read_one(actor: context.star, tenant: context.site.id)
    end

    test "nor for the system compiling the page", context do
      assert {:ok, %{loaded_layout: nil}} =
               Page
               |> Ash.Query.filter(id == ^context.page.id)
               |> Ash.Query.load([:loaded_layout])
               |> Ash.read_one(tenant: context.site.id, authorize?: false)
    end

    test "is the page's own site's or a shared one", context do
      for layout <- [create_layout!(site_id: context.site.id), create_layout!(site_id: nil)] do
        MishkaCmsCore.Repo.query!("UPDATE pages SET layout_id = $1 WHERE id = $2", [
          Ecto.UUID.dump!(layout.id),
          Ecto.UUID.dump!(context.page.id)
        ])

        assert {:ok, %{loaded_layout: %{id: id}}} =
                 Page
                 |> Ash.Query.filter(id == ^context.page.id)
                 |> Ash.Query.load([:loaded_layout])
                 |> Ash.read_one(tenant: context.site.id, authorize?: false)

        assert id == layout.id
      end
    end
  end

  describe "a draft's live record" do
    test "a page draft names no page of another site", context do
      theirs = create_page!(site_id: context.other.id)
      n = unique()

      assert {:error, _refused} =
               create_as(
                 PageDraft,
                 :create,
                 %{
                   source_page_id: theirs.id,
                   name: "Draft #{n}",
                   title: "Draft #{n}",
                   path: "/draft-#{n}",
                   template: "<div></div>"
                 },
                 context.star,
                 context.site.id
               )
    end

    test "an error page draft names no error page of another site", context do
      theirs = create_error_page!(site_id: context.other.id)
      n = unique()

      assert {:error, _refused} =
               create_as(
                 ErrorPageDraft,
                 :create,
                 %{
                   source_error_page_id: theirs.id,
                   name: "errors-#{n}",
                   path: "/errors-#{n}",
                   error_pages: [%{status: 404, template: "<h1>Not Found</h1>"}]
                 },
                 context.star,
                 context.site.id
               )
    end

    test "a layout draft names no layout of another site", context do
      theirs = create_layout!(site_id: context.other.id)
      n = unique()

      assert {:error, _refused} =
               create_as(
                 LayoutDraft,
                 :create,
                 %{
                   source_layout_id: theirs.id,
                   name: "layout-draft-#{n}",
                   path: "/layout-draft-#{n}",
                   template: "<body>{@inner_content}</body>"
                 },
                 context.star,
                 context.site.id
               )
    end

    test "each names its own site's record", context do
      page = create_page!(site_id: context.site.id)
      layout = create_layout!(site_id: context.site.id)
      n = unique()

      assert {:ok, _draft} =
               create_as(
                 PageDraft,
                 :create,
                 %{
                   source_page_id: page.id,
                   layout_id: layout.id,
                   name: "Draft #{n}",
                   title: "Draft #{n}",
                   path: "/draft-#{n}",
                   template: "<div></div>"
                 },
                 context.star,
                 context.site.id
               )

      assert {:ok, _draft} =
               create_as(
                 LayoutDraft,
                 :create,
                 %{
                   source_layout_id: layout.id,
                   name: "layout-draft-#{n}",
                   path: "/layout-draft-#{n}",
                   template: "<body>{@inner_content}</body>"
                 },
                 context.star,
                 context.site.id
               )
    end
  end

  describe "a media file's category" do
    test "is never another site's", context do
      theirs = create_media_category!(site_id: context.other.id)
      media = create_media!(site_id: context.site.id)

      assert {:error, _refused} =
               update_as(media, %{media_category_id: theirs.id}, context.star, context.site.id)

      assert Ash.get!(Media, media.id, tenant: context.site.id, authorize?: false).media_category_id ==
               media.media_category_id
    end

    test "is the site's own", context do
      own = create_media_category!(site_id: context.site.id)
      media = create_media!(site_id: context.site.id)

      assert {:ok, %{media_category_id: id}} =
               update_as(media, %{media_category_id: own.id}, context.star, context.site.id)

      assert id == own.id
    end
  end

  # A JOIN ROW HAS NO SITE OF ITS OWN: `own:` names the parent whose site it has, and the other
  # parent must be that site's (or shared, where allowed). Whoever writes, a master included.
  describe "a record with no site of its own, placed by the parent it names in `own:`" do
    alias MishkaCmsCore.Runtime.Layout
    alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference

    defp check(attrs, extra_opts \\ []) do
      {:ok, opts} =
        SameSiteReference.init(
          [field: :layout_id, resource: Layout, label: "layout", own: {:source_page_id, Page}] ++
            extra_opts
        )

      PageDraft
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(attrs)
      |> SameSiteReference.validate(opts, %{})
    end

    test "names a record of the same site as that parent", context do
      page = create_page!(site_id: context.site.id)
      layout = create_layout!(site_id: context.site.id)

      assert :ok = check(%{source_page_id: page.id, layout_id: layout.id})
    end

    test "never a record of another site than that parent's", context do
      page = create_page!(site_id: context.site.id)
      theirs = create_layout!(site_id: context.other.id)

      assert {:error, error} = check(%{source_page_id: page.id, layout_id: theirs.id})
      assert error[:message] == "That layout is not one this site can use."
    end

    test "a shared record only where shared records are allowed", context do
      page = create_page!(site_id: context.site.id)
      shared = create_layout!(site_id: nil)

      assert {:error, _refused} = check(%{source_page_id: page.id, layout_id: shared.id})
      assert :ok = check(%{source_page_id: page.id, layout_id: shared.id}, shared?: true)
    end

    test "is refused when the parent it names does not exist", context do
      layout = create_layout!(site_id: context.site.id)

      assert {:error, _refused} =
               check(%{source_page_id: Ash.UUID.generate(), layout_id: layout.id})
    end
  end

  describe "an id whose kind another field names" do
    alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, PageComment}
    alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference

    defp kinds_opts do
      {:ok, opts} =
        SameSiteReference.init(
          field: :document_id,
          resource:
            {:section, %{page: Page, layout: Layout, error_page: ErrorPage, component: Component}},
          label: "document",
          shared?: true
        )

      opts
    end

    defp check_kind(changeset), do: SameSiteReference.validate(changeset, kinds_opts(), %{})

    defp note(attrs) do
      PageComment
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(attrs)
    end

    test "names a record of the kind that field picks, on the same site", context do
      page = create_page!(site_id: context.site.id)
      layout = create_layout!(site_id: context.site.id)

      assert :ok =
               check_kind(note(%{site_id: context.site.id, section: :page, document_id: page.id}))

      assert :ok =
               check_kind(
                 note(%{site_id: context.site.id, section: :layout, document_id: layout.id})
               )
    end

    test "never another site's record of that kind", context do
      theirs = create_page!(site_id: context.other.id)

      assert {:error, error} =
               check_kind(
                 note(%{site_id: context.site.id, section: :page, document_id: theirs.id})
               )

      assert error[:message] == "That document is not one this site can use."
    end

    test "never a record of another kind than the one named", context do
      layout = create_layout!(site_id: context.site.id)

      assert {:error, _refused} =
               check_kind(
                 note(%{site_id: context.site.id, section: :page, document_id: layout.id})
               )
    end

    test "a shared record of that kind where shared records are allowed", context do
      shared = create_component!(site_id: nil)

      assert :ok =
               check_kind(
                 note(%{site_id: context.site.id, section: :component, document_id: shared.id})
               )
    end

    test "a kind the map does not hold is refused", context do
      page = create_page!(site_id: context.site.id)

      {:ok, opts} =
        SameSiteReference.init(
          field: :document_id,
          resource: {:section, %{layout: Layout}},
          label: "document"
        )

      assert {:error, _refused} =
               SameSiteReference.validate(
                 note(%{site_id: context.site.id, section: :page, document_id: page.id}),
                 opts,
                 %{}
               )
    end

    test "is checked again when only the kind changes", context do
      page = create_page!(site_id: context.site.id)

      existing = %PageComment{site_id: context.site.id, section: :page, document_id: page.id}

      assert {:error, _refused} =
               existing
               |> Ash.Changeset.new()
               |> Ash.Changeset.force_change_attribute(:section, :layout)
               |> check_kind()
    end
  end

  describe "a user named by a site's record" do
    alias MishkaCmsCore.Accounts.User
    alias MishkaCmsCore.Runtime.PageComment
    alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference

    defp check_user(site_id, user_id, extra_opts \\ [shared?: true]) do
      {:ok, opts} =
        SameSiteReference.init(
          [field: :author_id, resource: User, label: "author", read_action: :related] ++
            extra_opts
        )

      PageComment
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(%{site_id: site_id, author_id: user_id})
      |> SameSiteReference.validate(opts, %{})
    end

    test "is one of that site's accounts", context do
      assert :ok = check_user(context.site.id, create_user!(site_id: context.site.id).id)
    end

    test "or a master, who acts on every site", context do
      master = create_user!(site_id: nil)

      assert :ok = check_user(context.site.id, master.id)
      assert {:error, _refused} = check_user(context.site.id, master.id, [])
    end

    test "never another site's account", context do
      theirs = create_user!(site_id: context.other.id)

      assert {:error, error} = check_user(context.site.id, theirs.id)
      assert error[:message] == "That author is not one this site can use."
    end

    test "a record with no site names only a master", context do
      assert {:error, _refused} =
               check_user(nil, create_user!(site_id: context.site.id).id)

      assert :ok = check_user(nil, create_user!(site_id: nil).id)
    end
  end

  describe "the site a record is judged by" do
    alias MishkaCmsCore.Runtime.{PageBuilderEvent, PageComment, Snippet}

    defp history_row(tenant, attrs, actor, authorize?) do
      PageBuilderEvent
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            source_type: :page,
            label: "Set gap (base)",
            kind: :style,
            op: :set_style
          },
          attrs
        ),
        tenant: tenant,
        actor: actor,
        authorize?: authorize?
      )
      |> Ash.create(actor: actor, authorize?: authorize?)
    end

    defp system_master_create(resource, attrs, tenant) do
      resource
      |> Ash.Changeset.for_create(:master_create, attrs, tenant: tenant, authorize?: false)
      |> Ash.create(authorize?: false)
    end

    test "is the tenant a create stores, not a site_id in its input", context do
      theirs = create_page!(site_id: context.other.id)
      own = create_page!(site_id: context.site.id)

      for {actor, authorize?} <- [{master!(), true}, {nil, false}] do
        assert {:error, error} =
                 history_row(
                   context.site.id,
                   %{site_id: context.other.id, source_id: theirs.id},
                   actor,
                   authorize?
                 )

        assert Exception.message(error) =~ "document is not one this site can use"

        assert {:ok, row} =
                 history_row(
                   context.site.id,
                   %{site_id: context.other.id, source_id: own.id},
                   actor,
                   authorize?
                 )

        assert row.site_id == context.site.id
      end
    end

    test "is none for a master's create that stores the row shared, whatever the tenant",
         context do
      page = create_page!(site_id: context.site.id)
      component = create_component!(site_id: context.site.id)
      shared = create_component!(site_id: nil)
      snippet = %{name: "Hero #{unique()}", source: "<div>hero</div>", section: :page}
      note = %{body: "Check this", type: :bug, section: :component}

      assert {:error, error} =
               system_master_create(
                 Snippet,
                 Map.put(snippet, :document_id, page.id),
                 context.site.id
               )

      assert Exception.message(error) =~ "document is not one this site can use"

      assert {:error, error} =
               system_master_create(
                 PageComment,
                 Map.put(note, :document_id, component.id),
                 context.site.id
               )

      assert Exception.message(error) =~ "document is not one this site can use"

      assert {:ok, %{site_id: nil}} =
               system_master_create(
                 PageComment,
                 Map.put(note, :document_id, shared.id),
                 context.site.id
               )
    end
  end

  describe "a builder history row" do
    alias MishkaCmsCore.Runtime.PageBuilderEvent

    defp event(context, attrs, actor, opts \\ []) do
      attrs =
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            source_type: :page,
            site_id: context.site.id,
            label: "Set gap (base)",
            kind: :style,
            op: :set_style
          },
          attrs
        )

      authorize? = Keyword.get(opts, :authorize?, true)

      PageBuilderEvent
      |> Ash.Changeset.for_create(:create, attrs,
        tenant: context.site.id,
        actor: actor,
        authorize?: authorize?
      )
      |> Ash.create(actor: actor, authorize?: authorize?)
    end

    test "names no document of another site, whoever writes", context do
      theirs = create_page!(site_id: context.other.id)

      for actor <- [context.star, master!()] do
        assert {:error, error} = event(context, %{source_id: theirs.id}, actor)
        assert Exception.message(error) =~ "document is not one this site can use"
      end

      assert {:error, _refused} =
               event(context, %{source_id: theirs.id}, nil, authorize?: false)
    end

    test "nor another site's draft", context do
      page = create_page!(site_id: context.site.id)
      theirs = page_draft!(context.other.id)

      for actor <- [context.star, master!()] do
        assert {:error, error} =
                 event(context, %{source_id: page.id, draft_id: theirs.id}, actor)

        assert Exception.message(error) =~ "draft is not one this site can use"
      end
    end

    test "nor an author of another site", context do
      page = create_page!(site_id: context.site.id)
      stranger = create_user!(site_id: context.other.id)

      assert {:error, error} =
               event(context, %{source_id: page.id}, stranger, authorize?: false)

      assert Exception.message(error) =~ "author is not one this site can use"
    end

    test "names its own site's document and draft, or a shared one", context do
      page = create_page!(site_id: context.site.id)
      draft = page_draft!(context.site.id)
      shared = create_layout!(site_id: nil)

      for actor <- [context.star, master!()] do
        assert {:ok, _row} = event(context, %{source_id: page.id, draft_id: draft.id}, actor)

        assert {:ok, _row} =
                 event(context, %{source_type: :layout, source_id: shared.id}, actor)
      end
    end

    test "a draft adopted later is the row's own site's too", context do
      page = create_page!(site_id: context.site.id)
      {:ok, row} = event(context, %{source_id: page.id}, context.star)

      adopt = fn draft ->
        row
        |> Ash.Changeset.for_update(:adopt_draft, %{draft_id: draft.id},
          tenant: context.site.id,
          actor: context.star
        )
        |> Ash.update(actor: context.star)
      end

      assert {:error, _refused} = adopt.(page_draft!(context.other.id))
      assert {:ok, %{draft_id: _adopted}} = adopt.(page_draft!(context.site.id))
    end

    test "a note is signed by an account of the row's site or a master", context do
      page = create_page!(site_id: context.site.id)
      {:ok, row} = event(context, %{source_id: page.id}, context.star)

      annotate = fn actor ->
        row
        |> Ash.Changeset.for_update(:annotate, %{note: "Deliberate."},
          actor: actor,
          authorize?: false
        )
        |> Ash.update(actor: actor, authorize?: false)
      end

      assert {:error, _refused} = annotate.(create_user!(site_id: context.other.id))
      assert {:ok, %{note: "Deliberate."}} = annotate.(context.star)
      assert {:ok, %{note: "Deliberate."}} = annotate.(master!())
    end
  end

  describe "a review note" do
    alias MishkaCmsCore.Runtime.PageComment

    defp note_as(actor, tenant, attrs) do
      action = if actor.site_id, do: :create, else: :master_create

      PageComment
      |> Ash.Changeset.for_create(
        action,
        Map.merge(%{body: "Check this", type: :bug}, attrs),
        actor: actor,
        tenant: tenant
      )
      |> Ash.create(actor: actor)
    end

    test "is about no document of another site, whoever writes", context do
      theirs = create_page!(site_id: context.other.id)
      attrs = %{section: :page, document_id: theirs.id}

      assert {:error, error} = note_as(context.star, context.site.id, attrs)
      assert Exception.message(error) =~ "document is not one this site can use"

      assert {:error, error} =
               note_as(master!(), nil, Map.put(attrs, :site_id, context.site.id))

      assert Exception.message(error) =~ "document is not one this site can use"
    end

    test "is about its own site's document or a shared one", context do
      page = create_page!(site_id: context.site.id)
      shared = create_component!(site_id: nil)

      for {actor, tenant, extra} <- [
            {context.star, context.site.id, %{}},
            {master!(), nil, %{site_id: context.site.id}}
          ] do
        assert {:ok, _note} =
                 note_as(actor, tenant, Map.merge(extra, %{section: :page, document_id: page.id}))

        assert {:ok, _note} =
                 note_as(
                   actor,
                   tenant,
                   Map.merge(extra, %{section: :component, document_id: shared.id})
                 )
      end
    end

    test "a note with no site is about a shared document only", context do
      theirs = create_layout!(site_id: context.site.id)

      assert {:error, _refused} =
               note_as(master!(), nil, %{section: :layout, document_id: theirs.id})
    end

    test "answers no note of another site", context do
      shared = create_component!(site_id: nil)
      on_shared = %{section: :component, document_id: shared.id}
      other_star = create_user_with_permissions!(["*"], site_id: context.other.id)

      {:ok, theirs} = note_as(other_star, context.other.id, on_shared)
      reply = Map.put(on_shared, :parent_comment_id, theirs.id)

      assert {:error, error} = note_as(context.star, context.site.id, reply)
      assert Exception.message(error) =~ "note is not one this site can use"

      assert {:error, _refused} =
               note_as(master!(), nil, Map.put(reply, :site_id, context.site.id))
    end

    test "answers its own site's note or a shared one", context do
      shared = create_component!(site_id: nil)
      on_shared = %{section: :component, document_id: shared.id}

      {:ok, own} = note_as(context.star, context.site.id, on_shared)
      {:ok, global} = note_as(master!(), nil, on_shared)

      for parent <- [own, global] do
        assert {:ok, _reply} =
                 note_as(
                   context.star,
                   context.site.id,
                   Map.put(on_shared, :parent_comment_id, parent.id)
                 )
      end
    end

    test "names no author of another site", context do
      page = create_page!(site_id: context.site.id)
      attrs = %{site_id: context.site.id, section: :page, document_id: page.id}

      assert {:error, error} =
               note_as(
                 master!(),
                 nil,
                 Map.put(attrs, :author_id, create_user!(site_id: context.other.id).id)
               )

      assert Exception.message(error) =~ "author is not one this site can use"

      assert {:error, _refused} =
               PageComment
               |> Ash.Changeset.for_create(
                 :create,
                 %{body: "Check this", type: :bug, section: :page, document_id: page.id},
                 actor: create_user!(site_id: context.other.id),
                 tenant: context.site.id,
                 authorize?: false
               )
               |> Ash.create(authorize?: false)

      assert {:ok, _note} =
               note_as(master!(), nil, Map.put(attrs, :author_id, master!().id))
    end

    test "is resolved by an account of its site or a master", context do
      page = create_page!(site_id: context.site.id)

      {:ok, note} =
        note_as(context.star, context.site.id, %{section: :page, document_id: page.id})

      resolve = fn action, actor ->
        note
        |> Ash.Changeset.for_update(action, %{},
          actor: actor,
          tenant: context.site.id,
          authorize?: false
        )
        |> Ash.update(authorize?: false)
      end

      for action <- [:resolve, :master_resolve] do
        assert {:error, error} = resolve.(action, create_user!(site_id: context.other.id))
        assert Exception.message(error) =~ "resolver is not one this site can use"
      end

      assert {:ok, %{status: :resolved}} = resolve.(:resolve, context.star)
      assert {:ok, %{status: :resolved}} = resolve.(:master_resolve, master!())
    end
  end

  describe "a saved snippet" do
    alias MishkaCmsCore.Runtime.Snippet

    defp snippet_as(actor, tenant, attrs) do
      action = if actor.site_id, do: :create, else: :master_create

      Snippet
      |> Ash.Changeset.for_create(
        action,
        Map.merge(%{name: "Hero #{unique()}", source: "<div>hero</div>", section: :page}, attrs),
        actor: actor,
        tenant: tenant
      )
      |> Ash.create(actor: actor)
    end

    test "names no document of another site, whoever writes", context do
      theirs = create_page!(site_id: context.other.id)
      attrs = %{scope: :page, document_id: theirs.id}

      assert {:error, error} = snippet_as(context.star, context.site.id, attrs)
      assert Exception.message(error) =~ "document is not one this site can use"

      assert {:error, _refused} =
               snippet_as(master!(), nil, Map.put(attrs, :site_id, context.site.id))
    end

    test "names its own site's document or a shared one", context do
      page = create_page!(site_id: context.site.id)
      shared = create_layout!(site_id: nil)

      for {actor, tenant, extra} <- [
            {context.star, context.site.id, %{}},
            {master!(), nil, %{site_id: context.site.id}}
          ] do
        assert {:ok, _snippet} =
                 snippet_as(
                   actor,
                   tenant,
                   Map.merge(extra, %{scope: :page, document_id: page.id})
                 )

        assert {:ok, _snippet} =
                 snippet_as(
                   actor,
                   tenant,
                   Map.merge(extra, %{section: :layout, document_id: shared.id})
                 )
      end
    end

    test "one for every site names only a shared document", context do
      page = create_page!(site_id: context.site.id)
      shared = create_layout!(site_id: nil)

      assert {:error, _refused} = snippet_as(master!(), nil, %{document_id: page.id})

      assert {:ok, _snippet} =
               snippet_as(master!(), nil, %{section: :layout, document_id: shared.id})
    end

    test "the Studio saves one for every site without the site's document", context do
      page_id = create_page!(site_id: context.site.id).id

      state =
        &%{
          master_user?: true,
          defaults: %{section: :page, editor_document_id: page_id, editor_site_id: &1}
        }

      assert %{"site_id" => nil, "document_id" => nil} =
               Snippet.apply_visibility(%{"visibility" => "global"}, state.(context.site.id))

      assert %{"site_id" => site_id, "document_id" => ^page_id} =
               Snippet.apply_visibility(%{"visibility" => "shared"}, state.(context.site.id))

      assert site_id == context.site.id

      assert %{"site_id" => nil, "document_id" => ^page_id} =
               Snippet.apply_visibility(%{"visibility" => "global"}, state.(nil))
    end
  end

  describe "a notification" do
    alias MishkaCmsCore.Notify.Notification

    defp deliver(tenant, attrs) do
      Notification
      |> Ash.Changeset.for_create(
        :deliver,
        Map.merge(%{type: "cms_core:test", title: "Something happened"}, attrs),
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create(authorize?: false)
    end

    test "reaches no recipient of another site", context do
      theirs = create_user!(site_id: context.other.id)

      assert {:error, error} = deliver(context.site.id, %{user_id: theirs.id})
      assert Exception.message(error) =~ "recipient is not one this site can use"
    end

    test "names no actor of another site", context do
      mine = create_user!(site_id: context.site.id)
      theirs = create_user!(site_id: context.other.id)

      assert {:error, error} = deliver(context.site.id, %{user_id: mine.id, actor_id: theirs.id})
      assert Exception.message(error) =~ "actor is not one this site can use"
    end

    test "names the site's own accounts, or masters", context do
      mine = create_user!(site_id: context.site.id)
      master = create_user!(site_id: nil)

      assert {:ok, _row} = deliver(context.site.id, %{user_id: mine.id, actor_id: master.id})
      assert {:ok, _row} = deliver(context.site.id, %{user_id: master.id, actor_id: mine.id})
    end

    test "one with no site names only masters", context do
      master = create_user!(site_id: nil)
      mine = create_user!(site_id: context.site.id)

      assert {:error, _refused} = deliver(nil, %{user_id: master.id, actor_id: mine.id})
      assert {:ok, _row} = deliver(nil, %{user_id: master.id, actor_id: master.id})
    end
  end

  describe "a page's language group" do
    defp page_as(actor, tenant, attrs) do
      action = if actor.site_id, do: :create, else: :master_create
      create_as(Page, action, page_attrs(attrs), actor, tenant)
    end

    defp regroup(record, group, actor) do
      {action, tenant} =
        if actor.site_id, do: {:update, record.site_id}, else: {:master_update, nil}

      record
      |> Ash.Changeset.for_update(action, %{language_group_id: group},
        actor: actor,
        tenant: tenant
      )
      |> Ash.update(actor: actor)
    end

    defp draft_as(actor, tenant, attrs) do
      action = if actor.site_id, do: :create, else: :master_create
      n = unique()

      create_as(
        PageDraft,
        action,
        Map.merge(
          %{name: "Draft #{n}", title: "Draft", path: "/draft-#{n}", template: "<div></div>"},
          attrs
        ),
        actor,
        tenant
      )
    end

    test "is never another site's, whoever writes", context do
      theirs = create_page!(site_id: context.other.id)
      mine = create_page!(site_id: context.site.id)
      attrs = %{language: "fa", language_group_id: theirs.language_group_id}

      assert {:error, error} = page_as(context.star, context.site.id, attrs)
      assert Exception.message(error) =~ "language group is not one this site can use"

      assert {:error, _refused} =
               page_as(master!(), nil, Map.put(attrs, :site_id, context.site.id))

      draft = page_draft!(context.site.id)

      for actor <- [context.star, master!()] do
        tenant = actor.site_id
        site = %{site_id: context.site.id}
        group = %{language_group_id: theirs.language_group_id}

        assert {:error, error} = regroup(mine, theirs.language_group_id, actor)
        assert Exception.message(error) =~ "language group is not one this site can use"

        assert {:error, error} =
                 draft_as(actor, tenant, if(tenant, do: group, else: Map.merge(group, site)))

        assert Exception.message(error) =~ "language group is not one this site can use"

        assert {:error, error} = regroup(draft, theirs.language_group_id, actor)
        assert Exception.message(error) =~ "language group is not one this site can use"
      end
    end

    test "is the site's own", context do
      master_page = create_page!(site_id: context.site.id)
      attrs = %{language: "fa", language_group_id: master_page.language_group_id}

      assert {:ok, edition} = page_as(context.star, context.site.id, attrs)
      assert edition.language_group_id == master_page.language_group_id

      assert {:ok, %{title: "Renamed"}} =
               update_as(edition, %{title: "Renamed"}, context.star, context.site.id)
    end
  end

  describe "a page a plugin changes before it is created" do
    alias MishkaCmsCore.Test.Plugins.PageLinkSwap
    alias MishkaInstaller.Event.{Event, EventHandler}

    @before_create "cms_core:page:before_create"

    setup do
      {:ok, _} =
        Event.write(%{
          name: PageLinkSwap,
          event: @before_create,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(@before_create, :start, false)
      on_exit(fn -> Event.unregister(:name, PageLinkSwap, false) end)
    end

    defp create_swapped(context, attrs \\ %{}, swap) do
      Page
      |> Ash.Changeset.for_create(:create, page_attrs(attrs),
        actor: context.star,
        tenant: context.site.id
      )
      |> Ash.Changeset.set_context(%{link_swap: swap})
      |> Ash.create(actor: context.star)
    end

    test "names no layout of another site the plugin sets", context do
      theirs = create_layout!(site_id: context.other.id)

      assert {:error, error} = create_swapped(context, %{layout_id: theirs.id})
      assert Exception.message(error) =~ "layout is not one this site can use"
    end

    test "nor a language group of another site", context do
      own = create_page!(site_id: context.site.id)
      theirs = create_page!(site_id: context.other.id)
      translation = %{language: "fa", language_group_id: own.id}

      assert {:error, error} =
               create_swapped(context, translation, %{language_group_id: theirs.id})

      assert Exception.message(error) =~ "language group is not one this site can use"
    end

    test "keeps the site's own layout and group the plugin sets", context do
      own = create_layout!(site_id: context.site.id)
      first = create_page!(site_id: context.site.id)
      group = create_page!(site_id: context.site.id)
      translation = %{language: "fa", language_group_id: first.id}

      assert {:ok, page} =
               create_swapped(context, translation, %{
                 layout_id: own.id,
                 language_group_id: group.id
               })

      assert {page.layout_id, page.language_group_id} == {own.id, group.id}
    end
  end

  describe "a restored version" do
    alias MishkaCmsCore.Runtime.Media

    import MishkaCmsCore.Test.VersionHelpers

    defp restore(record, version, actor) do
      record
      |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
        actor: actor,
        tenant: record.site_id
      )
      |> Ash.update(actor: actor)
    end

    test "brings back no other site's layout a page named before the rule", context do
      theirs = create_layout!(site_id: context.other.id)
      page = create_page!(site_id: context.site.id)

      MishkaCmsCore.Repo.query!("UPDATE pages SET layout_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(theirs.id),
        Ecto.UUID.dump!(page.id)
      ])

      page = Ash.get!(Page, page.id, tenant: context.site.id, authorize?: false)
      {:ok, page} = update_as(page, %{title: "Named elsewhere"}, context.star, context.site.id)
      tainted = version_with_changes(Page.Version, page.id, %{"layout_id" => theirs.id})

      own = create_layout!(site_id: context.site.id)
      {:ok, page} = update_as(page, %{layout_id: own.id}, context.star, context.site.id)

      assert {:error, error} = restore(page, tainted, context.star)
      assert Exception.message(error) =~ "layout is not one this site can use"

      clean = version_with_changes(Page.Version, page.id, %{"layout_id" => own.id})
      assert {:ok, %{layout_id: layout_id}} = restore(page, clean, context.star)
      assert layout_id == own.id
    end

    test "brings back no other site's language group a page joined before the rule", context do
      theirs = create_page!(site_id: context.other.id)
      page = create_page!(site_id: context.site.id)

      MishkaCmsCore.Repo.query!("UPDATE pages SET language_group_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(theirs.language_group_id),
        Ecto.UUID.dump!(page.id)
      ])

      page = Ash.get!(Page, page.id, tenant: context.site.id, authorize?: false)
      {:ok, page} = update_as(page, %{title: "Grouped elsewhere"}, context.star, context.site.id)

      tainted =
        version_with_changes(Page.Version, page.id, %{
          "language_group_id" => theirs.language_group_id
        })

      {:ok, page} = update_as(page, %{language_group_id: page.id}, context.star, context.site.id)

      assert {:error, error} = restore(page, tainted, context.star)
      assert Exception.message(error) =~ "language group is not one this site can use"
    end

    test "brings back no other site's category a media file named before the rule", context do
      theirs = create_media_category!(site_id: context.other.id)
      media = create_media!(site_id: context.site.id)

      MishkaCmsCore.Repo.query!("UPDATE media SET media_category_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(theirs.id),
        Ecto.UUID.dump!(media.id)
      ])

      media = Ash.get!(Media, media.id, tenant: context.site.id, authorize?: false)

      {:ok, media} =
        update_as(media, %{description: "Filed elsewhere"}, context.star, context.site.id)

      tainted = version_with_changes(Media.Version, media.id, %{"media_category_id" => theirs.id})

      own = create_media_category!(site_id: context.site.id)
      {:ok, media} = update_as(media, %{media_category_id: own.id}, context.star, context.site.id)

      assert {:error, error} = restore(media, tainted, context.star)
      assert Exception.message(error) =~ "folder is not one this site can use"
    end

    test "says the site's own layout it named is archived", context do
      first = create_layout!(site_id: context.site.id)
      page = create_page!(site_id: context.site.id)

      {:ok, page} = update_as(page, %{layout_id: first.id}, context.star, context.site.id)
      named = version_with_changes(Page.Version, page.id, %{"layout_id" => first.id})
      second = create_layout!(site_id: context.site.id)
      {:ok, page} = update_as(page, %{layout_id: second.id}, context.star, context.site.id)
      archive!(first, context.site.id)

      for actor <- [context.star, master!()] do
        assert {:error, error} = restore(page, named, actor)
        assert Exception.message(error) =~ "That layout is archived. Restore it first."
      end

      assert Ash.get!(Page, page.id, tenant: context.site.id, authorize?: false).layout_id ==
               second.id
    end

    test "says the same of an archived shared layout, and nothing of another site's", context do
      page = create_page!(site_id: context.site.id)
      shared = create_layout!(site_id: nil)
      theirs = create_layout!(site_id: context.other.id)
      archive!(shared, nil)
      archive!(theirs, context.other.id)

      assert {:error, error} =
               update_as(page, %{layout_id: shared.id}, context.star, context.site.id)

      assert Exception.message(error) =~ "That layout is archived. Restore it first."

      assert {:error, error} =
               update_as(page, %{layout_id: theirs.id}, context.star, context.site.id)

      assert Exception.message(error) =~ "That layout is not one this site can use."
      refute Exception.message(error) =~ "is archived"

      {:ok, own_only} =
        MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference.init(
          field: :layout_id,
          resource: MishkaCmsCore.Runtime.Layout,
          label: "layout"
        )

      assert {:error, [field: :layout_id, message: "That layout is not one this site can use."]} =
               Page
               |> Ash.Changeset.new()
               |> Ash.Changeset.force_change_attributes(%{
                 site_id: context.site.id,
                 layout_id: shared.id
               })
               |> MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference.validate(
                 own_only,
                 %{}
               )
    end

    test "says so in the language of the process that writes, the record's name included",
         context do
      page = create_page!(site_id: context.site.id)
      theirs = create_layout!(site_id: context.other.id)
      own = create_layout!(site_id: context.site.id)
      archive!(own, context.site.id)
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               update_as(page, %{layout_id: theirs.id}, context.star, context.site.id)

      assert Enum.any?(
               errors,
               &(&1.message == "[fa] That [fa] layout is not one this site can use.")
             )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               update_as(page, %{layout_id: own.id}, context.star, context.site.id)

      assert Enum.any?(
               errors,
               &(&1.message == "[fa] That [fa] layout is archived. Restore it first.")
             )
    end

    test "says the site's own media category it named is archived", context do
      first = create_media_category!(site_id: context.site.id)
      media = create_media!(site_id: context.site.id)

      {:ok, media} =
        update_as(media, %{media_category_id: first.id}, context.star, context.site.id)

      named = version_with_changes(Media.Version, media.id, %{"media_category_id" => first.id})
      second = create_media_category!(site_id: context.site.id)

      {:ok, media} =
        update_as(media, %{media_category_id: second.id}, context.star, context.site.id)

      archive!(first, context.site.id)

      assert {:error, error} = restore(media, named, context.star)
      assert Exception.message(error) =~ "That folder is archived. Restore it first."
    end
  end

  describe "a record other records name, moved to another site" do
    alias MishkaCmsCore.Accounts.User
    alias MishkaCmsCore.Runtime.{Component, Layout, PageComment}
    alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference

    @moved_away "still use this"

    defp move(record, site_id, master) do
      record.__struct__
      |> Ash.get!(record.id, action: :get_any, authorize?: false)
      |> Ash.Changeset.for_update(:master_update, %{site_id: site_id}, actor: master)
      |> Ash.update(actor: master)
    end

    defp move_account(user, site_id, master) do
      User
      |> Ash.ActionInput.for_action(:master_update, %{id: user.id, site_id: site_id},
        actor: master
      )
      |> Ash.run_action(actor: master)
    end

    defp move_account_by_form(user, site_id, master) do
      User
      |> Ash.get!(user.id, action: :master_get, authorize?: false)
      |> Ash.Changeset.for_update(:master_form_update, %{site_id: site_id}, actor: master)
      |> Ash.update(actor: master)
    end

    defp site_of(record),
      do: Ash.get!(record.__struct__, record.id, action: :get_any, authorize?: false).site_id

    defp account_site(user),
      do: Ash.get!(User, user.id, action: :master_get, authorize?: false).site_id

    defp wrap(page, layout) do
      page
      |> Ash.Changeset.for_update(:update, %{layout_id: layout.id},
        tenant: page.site_id,
        authorize?: false
      )
      |> Ash.update!(authorize?: false)
    end

    defp note_by(author, attrs) do
      PageComment
      |> Ash.Changeset.for_create(:create, Map.merge(%{body: "Check this", type: :bug}, attrs),
        actor: author,
        tenant: author.site_id
      )
      |> Ash.create!(actor: author)
    end

    test "a layout another site's page uses stays where that page can use it", context do
      master = master!()
      shared = create_layout!(site_id: nil)
      wrap(create_page!(site_id: context.other.id), shared)

      assert {:error, error} = move(shared, context.site.id, master)
      assert Exception.message(error) =~ "Records outside that site #{@moved_away} layout"
      assert site_of(shared) == nil
    end

    test "a layout an archived page of another site uses stays too", context do
      master = master!()
      shared = create_layout!(site_id: nil)
      page = wrap(create_page!(site_id: context.other.id), shared)
      archive!(page, context.other.id)

      assert {:error, _refused} = move(shared, context.site.id, master)
      assert site_of(shared) == nil
    end

    test "a layout a shared record names stays shared", context do
      master = master!()
      shared = create_layout!(site_id: nil)

      {:ok, _note} =
        PageComment
        |> Ash.Changeset.for_create(
          :master_create,
          %{body: "Check this", type: :bug, section: :layout, document_id: shared.id},
          actor: master
        )
        |> Ash.create(actor: master)

      assert {:error, _refused} = move(shared, context.site.id, master)
      assert site_of(shared) == nil
    end

    test "a layout moves to the one site whose records use it, or when nothing uses it",
         context do
      master = master!()
      shared = create_layout!(site_id: nil)
      wrap(create_page!(site_id: context.site.id), shared)
      unused = create_layout!(site_id: context.site.id)

      assert {:ok, %{site_id: site_id}} = move(shared, context.site.id, master)
      assert site_id == context.site.id
      assert {:ok, %{site_id: other_id}} = move(unused, context.other.id, master)
      assert other_id == context.other.id
    end

    test "a component a site's note is about stays on that site, or becomes shared", context do
      master = master!()
      component = create_component!(site_id: context.site.id)
      note_by(context.star, %{section: :component, document_id: component.id})

      assert {:error, error} = move(component, context.other.id, master)
      assert Exception.message(error) =~ "Records outside that site #{@moved_away} component"
      assert site_of(component) == context.site.id

      assert {:ok, %{site_id: nil}} = move(component, nil, master)
    end

    test "a record a link that takes no shared record names does not become shared", context do
      {:ok, opts} = SameSiteReference.init(moves: true, label: "page")
      page = create_page!(site_id: context.site.id)
      n = unique()

      moved = fn site_id ->
        page
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:site_id, site_id)
        |> SameSiteReference.validate(opts, %{})
      end

      assert page.language_group_id == page.id
      assert :ok = moved.(nil)

      {:ok, _draft} =
        create_as(
          PageDraft,
          :create,
          %{
            source_page_id: page.id,
            name: "Draft #{n}",
            title: "Draft #{n}",
            path: "/draft-#{n}",
            template: "<div></div>"
          },
          context.star,
          context.site.id
        )

      assert {:error, [field: :site_id, message: message]} = moved.(nil)
      assert message =~ "cannot become shared"
    end

    test "an account its site's records name stays on that site, or becomes a master",
         context do
      master = master!()
      author = create_user_with_permissions!(["*"], site_id: context.site.id)
      note_by(author, %{section: :page, document_id: create_page!(site_id: context.site.id).id})

      assert {:error, error} = move_account(author, context.other.id, master)
      assert Exception.message(error) =~ "Records outside that site #{@moved_away} account"

      assert {:error, _refused} = move_account_by_form(author, context.other.id, master)
      assert account_site(author) == context.site.id

      assert {:ok, %{site_id: nil}} = move_account(author, nil, master)
    end

    test "an account that wrote a site's history stays on that site", context do
      master = master!()
      editor = create_user_with_permissions!(["*"], site_id: context.site.id)
      page = create_page!(site_id: context.site.id)
      {:ok, _page} = update_as(page, %{title: "Edited"}, editor, context.site.id)

      assert {:error, _refused} = move_account_by_form(editor, context.other.id, master)
      assert account_site(editor) == context.site.id
    end

    test "an account nothing names moves", context do
      master = master!()
      newcomer = create_user!(site_id: context.site.id)

      assert {:ok, %{site_id: other_id}} = move_account(newcomer, context.other.id, master)
      assert other_id == context.other.id
    end

    test "every write that can move a record's site checks the records naming it" do
      guarded? = fn action ->
        Enum.any?(action.changes, fn
          %Ash.Resource.Validation{validation: {SameSiteReference, opts}} -> opts[:moves]
          _other -> false
        end)
      end

      movers =
        for domain <- Application.fetch_env!(:mishka_cms_core, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            action <- Ash.Resource.Info.actions(resource),
            action.type == :update and :site_id in (action.accept || []),
            do: {resource, action}

      assert {User, :master_form_update} in Enum.map(movers, fn {r, a} -> {r, a.name} end)
      assert {Layout, :master_update} in Enum.map(movers, fn {r, a} -> {r, a.name} end)
      assert {Component, :master_update} in Enum.map(movers, fn {r, a} -> {r, a.name} end)

      unguarded =
        for {resource, action} <- [{User, Ash.Resource.Info.action(User, :update)} | movers],
            not guarded?.(action),
            do: {resource, action.name}

      assert unguarded == []
    end
  end

  defp archive!(record, tenant) do
    record
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tenant, authorize?: false)
    |> Ash.destroy!(authorize?: false)
  end

  # EVERY WRITE OF EVERY LINK THE RULE ALREADY HELD for a site user, now for a master too — a master
  # writes on every site, and each record's links stay on that record's own site.
  describe "a master writing a site's record" do
    # A master's write carries no tenant, so the record is read the way a master reads it.
    defp update_with(record, action, attrs, actor, nil) do
      record.__struct__
      |> Ash.get!(record.id, action: :get_any, authorize?: false)
      |> Ash.Changeset.for_update(action, attrs, actor: actor)
      |> Ash.update(actor: actor)
    end

    defp update_with(record, action, attrs, actor, tenant) do
      record
      |> Ash.Changeset.for_update(action, attrs, actor: actor, tenant: tenant)
      |> Ash.update(actor: actor)
    end

    defp layout_draft!(site_id) do
      n = unique()

      LayoutDraft
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "layout-draft-#{n}",
          path: "/layout-draft-#{n}",
          template: "<body>{@inner_content}</body>"
        },
        tenant: site_id,
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
    end

    defp error_page_draft!(site_id) do
      n = unique()

      ErrorPageDraft
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "errors-#{n}",
          path: "/errors-#{n}",
          error_pages: [%{status: 404, template: "<h1>Not Found</h1>"}]
        },
        tenant: site_id,
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
    end

    defp refused?(result, label) do
      match?({:error, _}, result) and
        Exception.message(elem(result, 1)) =~ "#{label} is not one this site can use"
    end

    test "a page's layout", context do
      master = master!()
      theirs = create_layout!(site_id: context.other.id)
      page = create_page!(site_id: context.site.id)

      assert refused?(
               create_as(
                 Page,
                 :master_create,
                 page_attrs(%{site_id: context.site.id, layout_id: theirs.id}),
                 master,
                 nil
               ),
               "layout"
             )

      assert refused?(
               update_with(page, :master_update, %{layout_id: theirs.id}, master, nil),
               "layout"
             )
    end

    test "a page draft's layout and live page", context do
      master = master!()
      layout = create_layout!(site_id: context.other.id)
      source = create_page!(site_id: context.other.id)
      draft = page_draft!(context.site.id)
      n = unique()

      base = %{
        site_id: context.site.id,
        name: "Draft #{n}",
        title: "Draft",
        path: "/draft-#{n}",
        template: "<div></div>"
      }

      assert refused?(
               create_as(
                 PageDraft,
                 :master_create,
                 Map.put(base, :layout_id, layout.id),
                 master,
                 nil
               ),
               "layout"
             )

      assert refused?(
               create_as(
                 PageDraft,
                 :master_create,
                 Map.put(base, :source_page_id, source.id),
                 master,
                 nil
               ),
               "page"
             )

      for {action, actor, tenant} <- [
            {:master_update, master, nil},
            {:update, context.star, context.site.id}
          ] do
        assert refused?(
                 update_with(draft, action, %{layout_id: layout.id}, actor, tenant),
                 "layout"
               )

        assert refused?(
                 update_with(draft, action, %{source_page_id: source.id}, actor, tenant),
                 "page"
               )
      end
    end

    test "a layout draft's live layout", context do
      master = master!()
      theirs = create_layout!(site_id: context.other.id)
      draft = layout_draft!(context.site.id)
      n = unique()

      assert refused?(
               create_as(
                 LayoutDraft,
                 :master_create,
                 %{
                   site_id: context.site.id,
                   source_layout_id: theirs.id,
                   name: "layout-draft-#{n}",
                   path: "/layout-draft-#{n}",
                   template: "<body>{@inner_content}</body>"
                 },
                 master,
                 nil
               ),
               "layout"
             )

      for {action, actor, tenant} <- [
            {:master_update, master, nil},
            {:update, context.star, context.site.id}
          ] do
        assert refused?(
                 update_with(draft, action, %{source_layout_id: theirs.id}, actor, tenant),
                 "layout"
               )
      end
    end

    test "an error page draft's live error page", context do
      master = master!()
      theirs = create_error_page!(site_id: context.other.id)
      draft = error_page_draft!(context.site.id)
      n = unique()

      assert refused?(
               create_as(
                 ErrorPageDraft,
                 :master_create,
                 %{
                   site_id: context.site.id,
                   source_error_page_id: theirs.id,
                   name: "errors-#{n}",
                   path: "/errors-#{n}",
                   error_pages: [%{status: 404, template: "<h1>Not Found</h1>"}]
                 },
                 master,
                 nil
               ),
               "error page"
             )

      for {action, actor, tenant} <- [
            {:master_update, master, nil},
            {:update, context.star, context.site.id}
          ] do
        assert refused?(
                 update_with(draft, action, %{source_error_page_id: theirs.id}, actor, tenant),
                 "error page"
               )
      end
    end

    test "a media file's category", context do
      master = master!()
      theirs = create_media_category!(site_id: context.other.id)
      media = create_media!(site_id: context.site.id)

      file = fn extra ->
        Map.merge(%{name: "photo-#{unique()}", type: :images, size: 10, format: "jpg"}, extra)
      end

      create = fn action, attrs, actor, tenant ->
        Media
        |> Ash.Changeset.for_create(action, attrs,
          actor: actor,
          tenant: tenant,
          private_arguments: %{stored_path: "/uploads/photo-#{unique()}.jpg"}
        )
        |> Ash.create(actor: actor)
      end

      assert refused?(
               create.(
                 :create,
                 file.(%{media_category_id: theirs.id}),
                 context.star,
                 context.site.id
               ),
               "folder"
             )

      assert refused?(
               create.(
                 :master_create,
                 file.(%{site_id: context.site.id, media_category_id: theirs.id}),
                 master,
                 nil
               ),
               "folder"
             )

      assert refused?(
               create_as(
                 Media,
                 :form_upload,
                 %{media_category_id: theirs.id},
                 context.star,
                 context.site.id
               ),
               "folder"
             )

      assert refused?(
               create_as(
                 Media,
                 :master_form_upload,
                 %{site_id: context.site.id, media_category_id: theirs.id},
                 master,
                 nil
               ),
               "folder"
             )

      assert refused?(
               update_with(media, :master_update, %{media_category_id: theirs.id}, master, nil),
               "folder"
             )

      own = create_media_category!(site_id: context.site.id)

      assert {:ok, %{media_category_id: own_id}} =
               update_with(media, :master_update, %{media_category_id: own.id}, master, nil)

      assert own_id == own.id
    end
  end

  # WHAT A FORM OFFERS is what the write accepts: the record's own site's rows and the shared ones,
  # for a master following the site of the record being written.
  describe "a page form's layout picker" do
    alias MishkaCmsCore.Runtime.Layout
    alias MishkaGervaz.Form.Web.DataLoader.RelationLoader.Default, as: RelationLoader

    defp offered(state) do
      field = MishkaGervaz.Resource.Info.Form.field(Page, :layout_id)
      {:ok, options, _more?} = RelationLoader.load_options(field, state)
      options |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> MapSet.new()
    end

    setup context do
      %{
        own: create_layout!(site_id: context.site.id),
        shared: create_layout!(site_id: nil),
        theirs: create_layout!(site_id: context.other.id)
      }
    end

    test "offers a master the page's site's layouts and the shared ones", context do
      master = master!()

      ids =
        offered(%{
          current_user: master,
          master_user?: true,
          field_values: %{site_id: context.site.id}
        })

      assert MapSet.member?(ids, context.own.id)
      assert MapSet.member?(ids, context.shared.id)
      refute MapSet.member?(ids, context.theirs.id)
    end

    test "offers a master only shared layouts until the page has a site", context do
      ids = offered(%{current_user: master!(), master_user?: true, field_values: %{}})

      assert MapSet.member?(ids, context.shared.id)
      refute MapSet.member?(ids, context.own.id)
      refute MapSet.member?(ids, context.theirs.id)
    end

    test "offers a site user its own site's layouts and the shared ones", context do
      state = %{current_user: context.star, master_user?: false, field_values: %{}}
      ids = offered(state)

      assert MapSet.member?(ids, context.own.id)
      assert MapSet.member?(ids, context.shared.id)
      refute MapSet.member?(ids, context.theirs.id)

      # The layout a page already has is named in the picker, a shared one included.
      assert {:ok, [{_name, shared_id}]} =
               MishkaGervaz.Form.Web.DataLoader.RelationLoader.resolve_selected_fallback(
                 [context.shared.id],
                 Layout,
                 :for_tenant_with_globals,
                 context.site.id,
                 state,
                 :name,
                 nil
               )

      assert shared_id == context.shared.id
    end
  end

  describe "a media form's category picker" do
    alias MishkaGervaz.Form.Web.DataLoader.RelationLoader.Default, as: RelationLoader

    defp categories_offered(state) do
      field = MishkaGervaz.Resource.Info.Form.field(Media, :media_category_id)
      {:ok, options, _more?} = RelationLoader.load_options(field, state)
      options |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> MapSet.new()
    end

    setup context do
      %{
        own: create_media_category!(site_id: context.site.id),
        theirs: create_media_category!(site_id: context.other.id)
      }
    end

    test "offers a master the file's site's categories", context do
      ids =
        categories_offered(%{
          current_user: master!(),
          master_user?: true,
          field_values: %{site_id: context.site.id}
        })

      assert MapSet.member?(ids, context.own.id)
      refute MapSet.member?(ids, context.theirs.id)
    end

    test "offers a master none until the file has a site", context do
      ids = categories_offered(%{current_user: master!(), master_user?: true, field_values: %{}})

      refute MapSet.member?(ids, context.own.id)
      refute MapSet.member?(ids, context.theirs.id)
    end
  end

  # `shared?: :master` asks who writes: a record with no site is named only by a master or by the
  # system. A site's user gets the refusal another site's record gets, whatever it holds.
  describe "a shared record that only a master or the system may name" do
    alias MishkaCmsCore.Runtime.Layout
    alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference
    alias Ash.Resource.Validation.Context

    defp check_as(layout, context, shared?) do
      {:ok, opts} =
        SameSiteReference.init(
          field: :layout_id,
          resource: Layout,
          label: "layout",
          shared?: shared?
        )

      Page
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(%{
        site_id: context_site(context),
        layout_id: layout.id
      })
      |> SameSiteReference.validate(opts, context)
    end

    defp context_site(%Context{tenant: tenant}), do: tenant

    test "a master names one", context do
      master = create_user_with_permissions!(["*"])
      shared = create_layout!(site_id: nil)

      assert :ok =
               check_as(
                 shared,
                 %Context{actor: master, tenant: context.site.id, authorize?: true},
                 :master
               )
    end

    test "the system names one", context do
      shared = create_layout!(site_id: nil)

      assert :ok =
               check_as(
                 shared,
                 %Context{actor: nil, tenant: context.site.id, authorize?: false},
                 :master
               )
    end

    test "a site's user holding * does not, even with authorization turned off", context do
      shared = create_layout!(site_id: nil)

      for authorize? <- [true, false] do
        assert {:error, error} =
                 check_as(
                   shared,
                   %Context{actor: context.star, tenant: context.site.id, authorize?: authorize?},
                   :master
                 )

        assert error[:message] == "That layout is not one this site can use."
      end
    end

    test "nor does a caller with no actor that authorization still applies to", context do
      shared = create_layout!(site_id: nil)

      assert {:error, _refused} =
               check_as(
                 shared,
                 %Context{actor: nil, tenant: context.site.id, authorize?: true},
                 :master
               )
    end

    test "a site's user still names its own site's record", context do
      ours = create_layout!(site_id: context.site.id)

      assert :ok =
               check_as(
                 ours,
                 %Context{actor: context.star, tenant: context.site.id, authorize?: true},
                 :master
               )
    end

    test "true and false still ignore who writes", context do
      shared = create_layout!(site_id: nil)
      site_user = %Context{actor: context.star, tenant: context.site.id, authorize?: true}

      assert :ok = check_as(shared, site_user, true)
      assert {:error, _refused} = check_as(shared, site_user, false)
    end

    test "any other value is refused when the validation is set up" do
      assert {:error, _message} =
               SameSiteReference.init(
                 field: :layout_id,
                 resource: Layout,
                 label: "layout",
                 shared?: :sometimes
               )
    end
  end
end
