# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.PageCommentTest do
  @moduledoc """
  A review note as a row: what it stores, who can see it, and the two things that change it.

  The point of this resource is that a note outlives the editing session that wrote it, so most of
  what is pinned here is durability and scope — the things a list in ETS could never promise.

  `async: false` — global (`site_id` nil) rows are visible to every site.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.PageBuilder.Review
  alias MishkaCmsCore.Runtime.PageComment

  setup do
    site = create_site!()
    %{site: site, page: create_page!(site_id: site.id), other_site: create_site!()}
  end

  defp note!(site, attrs) do
    PageComment
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{body: "a note", type: :information, section: :page}, attrs),
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp scope(site, page),
    do: %{site_id: site.id, section: :page, document_id: page.id}

  describe "the resource's own shape" do
    test "is a tenant-scoped table that also allows global rows" do
      assert AshPostgres.DataLayer.Info.table(PageComment) == "page_comments"
      assert Ash.Resource.Info.multitenancy_strategy(PageComment) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(PageComment) == :site_id

      assert Ash.Resource.Info.multitenancy_global?(PageComment),
             "the builder edits global components too, which belong to no site"
    end

    test "offers the six types the form offers" do
      assert PageComment.types() == [:bug, :information, :suggestion, :question, :task, :other]
    end

    test "the form, the composer and the stored attribute read one list of types" do
      values = Enum.map(PageComment.types(), &to_string/1)

      assert Enum.map(PageComment.type_options(), &elem(&1, 1)) == values

      form_values =
        PageComment
        |> MishkaGervaz.Resource.Info.Form.field(:type)
        |> Map.fetch!(:options)
        |> MishkaGervaz.Helpers.resolve_options()
        |> Enum.map(&to_string(elem(&1, 1)))

      assert form_values == values

      assert Ash.Resource.Info.attribute(PageComment, :type).constraints[:one_of] ==
               PageComment.types()
    end
  end

  # A NOTE IS NEVER EDITED. The review form creates; edit mode is closed for everyone, so nothing can
  # open a composer whose save would do nothing.
  describe "the review form and thread" do
    alias MishkaGervaz.Form.Web.State.Helpers, as: FormState
    alias MishkaGervaz.Resource.Info.Form, as: FormInfo
    alias MishkaGervaz.Resource.Info.Table, as: TableInfo

    test "the form opens for a new note and never for editing one" do
      source = FormInfo.config(PageComment).source

      for master? <- [true, false] do
        assert FormState.mode_allowed?(source, :create, %{master_user?: master?})
        refute FormState.mode_allowed?(source, :update, %{master_user?: master?})
      end
    end

    test "the thread reads one note with a read the resource has, for a master and a site admin",
         %{site: site, page: page} do
      note = note!(site, %{document_id: page.id})

      for master? <- [true, false] do
        action = TableInfo.action_for(PageComment, :get, master?)
        assert %{type: :read} = Ash.Resource.Info.action(PageComment, action)
      end

      assert {:ok, %{id: id}} =
               Ash.get(PageComment, note.id,
                 action: TableInfo.action_for(PageComment, :get, true),
                 authorize?: false
               )

      assert id == note.id
    end
  end

  describe "what a note stores" do
    test "an element note keeps the id AND the label", %{site: site, page: page} do
      comment =
        note!(site, %{
          document_id: page.id,
          node_id: "nabc12345",
          node_label: "h1",
          type: :bug,
          body: "Too long on mobile"
        })

      assert comment.node_id == "nabc12345"
      assert comment.node_label == "h1"
      assert comment.status == :open
      assert comment.author_type == :human
      assert comment.resolved_at == nil
      assert comment.resolved_by_id == nil
    end

    # ONE NULLABLE COLUMN is the whole difference between the two scopes.
    test "a page note simply has no element", %{site: site, page: page} do
      comment = note!(site, %{document_id: page.id})
      assert comment.node_id == nil
    end

    test "refuses a blank body", %{site: site, page: page} do
      assert {:error, _reason} =
               PageComment
               |> Ash.Changeset.for_create(
                 :create,
                 %{body: "   ", type: :bug, section: :page, document_id: page.id},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()
    end

    # Nothing here implements AI review; this pins that it will not need a second table. The system
    # writes such a note through `:master_create` — the tenant `:create` takes no author from input.
    test "an AI or system note has no user behind it", %{site: site, page: page} do
      for author_type <- [:ai, :system] do
        comment =
          PageComment
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              body: "a note",
              type: :information,
              section: :page,
              document_id: page.id,
              site_id: site.id,
              author_type: author_type
            },
            authorize?: false
          )
          |> Ash.create!()

        assert comment.author_type == author_type
        assert comment.author_id == nil
      end
    end
  end

  # WHO WROTE IT IS WHO WROTE IT. A tenant's note takes its author from the actor, as a history row
  # does, and no caller can name somebody else — a master included, whose name decides who a mention
  # reaches.
  describe "the tenant create's author" do
    test "is the actor", %{site: site, page: page} do
      writer = create_user!(site_id: site.id)

      comment =
        PageComment
        |> Ash.Changeset.for_create(
          :create,
          %{body: "mine", type: :information, section: :page, document_id: page.id},
          tenant: site.id,
          actor: writer,
          authorize?: false
        )
        |> Ash.create!()

      assert comment.author_id == writer.id
      assert comment.author_type == :human
    end

    test "is never taken from input", %{site: site, page: page} do
      master = create_user!()
      writer = create_user!(site_id: site.id)

      for planted <- [%{author_id: master.id}, %{author_type: :ai}] do
        assert {:error, _refused} =
                 PageComment
                 |> Ash.Changeset.for_create(
                   :create,
                   Map.merge(
                     %{body: "planted", type: :information, section: :page, document_id: page.id},
                     planted
                   ),
                   tenant: site.id,
                   actor: writer,
                   authorize?: false
                 )
                 |> Ash.create()
      end
    end
  end

  describe "resolving" do
    setup %{site: site, page: page} do
      %{comment: note!(site, %{document_id: page.id, type: :bug}), user: create_user!()}
    end

    test "records who and when, together", %{comment: comment, site: site, user: user} do
      assert {:ok, resolved} =
               comment
               |> Ash.Changeset.for_update(:resolve, %{},
                 tenant: site.id,
                 actor: user,
                 authorize?: false
               )
               |> Ash.update()

      assert resolved.status == :resolved
      assert resolved.resolved_at
      assert resolved.resolved_by_id == user.id
    end

    # WHO RESOLVED IT IS WHOEVER DID, never a name a caller hands in: the resolver comes from the
    # actor, the way a note's author does.
    test "the resolver is never taken from input", %{comment: comment, site: site} do
      resolver = create_user_with_permissions!(["*"], site_id: site.id)
      stranger = create_user!(site_id: site.id)

      assert {:error, error} =
               comment
               |> Ash.Changeset.for_update(:resolve, %{resolved_by_id: stranger.id},
                 tenant: site.id,
                 actor: resolver
               )
               |> Ash.update(actor: resolver)

      assert Exception.message(error) =~ "resolved_by_id"

      assert {:ok, %{resolved_by_id: resolved_by}} =
               comment
               |> Ash.Changeset.for_update(:resolve, %{}, tenant: site.id, actor: resolver)
               |> Ash.update(actor: resolver)

      assert resolved_by == resolver.id
    end

    test "nor on the master's resolve", %{site: site, page: page} do
      master = create_user_with_permissions!(["*"])
      stranger = create_user!(site_id: site.id)
      comment = note!(site, %{document_id: page.id, type: :bug})

      assert {:error, error} =
               comment
               |> Ash.Changeset.for_update(:master_resolve, %{resolved_by_id: stranger.id},
                 actor: master
               )
               |> Ash.update(actor: master)

      assert Exception.message(error) =~ "resolved_by_id"
    end

    # "Resolved by X" on an open note is a claim that is no longer true.
    test "reopening clears the resolver", %{comment: comment, site: site, user: user} do
      {:ok, resolved} =
        comment
        |> Ash.Changeset.for_update(:resolve, %{},
          tenant: site.id,
          actor: user,
          authorize?: false
        )
        |> Ash.update()

      assert {:ok, reopened} =
               resolved
               |> Ash.Changeset.for_update(:reopen, %{}, tenant: site.id, authorize?: false)
               |> Ash.update()

      assert reopened.status == :open
      assert reopened.resolved_at == nil
      assert reopened.resolved_by_id == nil
    end

    # Resolving must not become a way to edit the note.
    test "changes nothing else about the note", %{comment: comment, site: site, user: user} do
      {:ok, resolved} =
        comment
        |> Ash.Changeset.for_update(:resolve, %{},
          tenant: site.id,
          actor: user,
          authorize?: false
        )
        |> Ash.update()

      assert resolved.body == comment.body
      assert resolved.type == comment.type
      assert resolved.node_id == comment.node_id
    end
  end

  describe "the editor's read" do
    test "returns this document's notes and nobody else's", %{
      site: site,
      page: page,
      other_site: other
    } do
      elsewhere = create_page!(site_id: site.id)
      other_page = create_page!(site_id: other.id)

      note!(site, %{document_id: page.id, body: "mine"})
      note!(site, %{document_id: elsewhere.id, body: "another page"})
      note!(other, %{document_id: other_page.id, body: "another site"})

      bodies = site |> scope(page) |> Review.list() |> Enum.map(& &1.body)

      assert bodies == ["mine"]
    end

    test "narrows to open notes when asked", %{site: site, page: page} do
      open = note!(site, %{document_id: page.id, body: "still open"})
      done = note!(site, %{document_id: page.id, body: "handled"})

      {:ok, _resolved} =
        done
        |> Ash.Changeset.for_update(:resolve, %{}, tenant: site.id, authorize?: false)
        |> Ash.update()

      assert site |> scope(page) |> Review.list(status: :open) |> Enum.map(& &1.id) == [open.id]
      assert site |> scope(page) |> Review.list() |> length() == 2
    end

    test "is newest first", %{site: site, page: page} do
      _first = note!(site, %{document_id: page.id, body: "one"})
      _second = note!(site, %{document_id: page.id, body: "two"})

      assert site |> scope(page) |> Review.list() |> Enum.map(& &1.body) == ["two", "one"]
    end
  end

  # THREADING, in `MishkaBlog.Comment`'s shape: a nullable self-reference and its reverse. What the
  # editor needs from it is that an answer stays under its question — in the read, and in the count.
  describe "replies" do
    test "a reply is stored under the note it answers", %{site: site, page: page} do
      question = note!(site, %{document_id: page.id, body: "final?", type: :question})

      reply =
        note!(site, %{document_id: page.id, body: "yes", parent_comment_id: question.id})

      assert reply.parent_comment_id == question.id

      assert [threaded] = site |> scope(page) |> Review.list()
      assert threaded.id == question.id
      assert Enum.map(threaded.replies, & &1.id) == [reply.id]
    end

    test "a reply is not a thread of its own", %{site: site, page: page} do
      question = note!(site, %{document_id: page.id, body: "final?", type: :question})
      note!(site, %{document_id: page.id, body: "yes", parent_comment_id: question.id})

      assert site |> scope(page) |> Review.list() |> Enum.map(& &1.body) == ["final?"]
    end

    # The counter reads the same rows the thread does, so a reply typed `:bug` by a caller that is
    # not the composer must not double-count the bug it is answering.
    test "a reply does not add to the bug count", %{site: site, page: page} do
      scope = scope(site, page)
      bug = note!(site, %{document_id: page.id, body: "broken", type: :bug})
      assert Review.open_bugs(scope) == 1

      note!(site, %{document_id: page.id, body: "on it", type: :bug, parent_comment_id: bug.id})

      assert Review.open_bugs(scope) == 1
    end

    test "the note being answered has to be on this document", %{site: site, page: page} do
      elsewhere = create_page!(site_id: site.id)
      there = note!(site, %{document_id: elsewhere.id, body: "another page"})

      assert {:error, %Ash.Error.Invalid{} = error} =
               PageComment
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   body: "answering the wrong question",
                   type: :information,
                   section: :page,
                   document_id: page.id,
                   parent_comment_id: there.id
                 },
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()

      assert Exception.message(error) =~ "different document"
    end

    test "a note that has been deleted cannot be answered", %{site: site, page: page} do
      gone = note!(site, %{document_id: page.id, body: "was here"})

      :ok =
        gone
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy()

      assert {:error, %Ash.Error.Invalid{} = error} =
               PageComment
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   body: "too late",
                   type: :information,
                   section: :page,
                   document_id: page.id,
                   parent_comment_id: gone.id
                 },
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()

      assert Exception.message(error) =~ "no longer here"
    end
  end

  describe "the unresolved-bug counter" do
    # DERIVED, not remembered: each of the four things that can change it is exercised, because a
    # hard-coded counter passes any test that only ever creates.
    test "counts open bugs and nothing else", %{site: site, page: page} do
      scope = scope(site, page)
      assert Review.open_bugs(scope) == 0

      note!(site, %{document_id: page.id, type: :information})
      assert Review.open_bugs(scope) == 0, "only bugs count"

      bug = note!(site, %{document_id: page.id, type: :bug})
      assert Review.open_bugs(scope) == 1

      {:ok, resolved} =
        bug
        |> Ash.Changeset.for_update(:resolve, %{}, tenant: site.id, authorize?: false)
        |> Ash.update()

      assert Review.open_bugs(scope) == 0

      {:ok, reopened} =
        resolved
        |> Ash.Changeset.for_update(:reopen, %{}, tenant: site.id, authorize?: false)
        |> Ash.update()

      assert Review.open_bugs(scope) == 1

      :ok =
        reopened
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy()

      assert Review.open_bugs(scope) == 0
    end
  end

  # WHO A NOTE BELONGS TO, and who may close it. The builder edits documents of both kinds — pages
  # and error pages belong to exactly one site, components and layouts can be shared by every site —
  # and a note has to inherit that, not decide for itself.
  describe "a note about a page always belongs to a site" do
    test "a master cannot leave a global note on a page", %{page: page} do
      assert {:error, error} =
               PageComment
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{body: "global?", type: :bug, section: :page, document_id: page.id},
                 authorize?: false
               )
               |> Ash.create()

      assert Exception.message(error) =~ "belongs to one site"
    end

    # …and the one they DO leave lands on that page's site, so its tenant sees it and nobody else's
    # does. That was already true because the builder hands a master the record's own site; this is
    # the same thing as a rule.
    test "a master's note on a page is visible to that site's tenant only", %{
      site: site,
      page: page,
      other_site: other
    } do
      {:ok, _comment} =
        PageComment
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            body: "from the master",
            type: :bug,
            section: :page,
            document_id: page.id,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create()

      assert site |> scope(page) |> Review.list() |> Enum.map(& &1.body) == ["from the master"]

      assert Review.list(%{site_id: other.id, section: :page, document_id: page.id}) == []
    end

    test "an error page is the same — it belongs to one site too", %{page: page} do
      assert {:error, _error} =
               PageComment
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{body: "x", type: :bug, section: :error_page, document_id: page.id},
                 authorize?: false
               )
               |> Ash.create()
    end
  end

  describe "a note about something shared" do
    setup do
      %{component_id: create_component!(site_id: nil).id, user: create_user!()}
    end

    defp global_note!(component_id, attrs \\ %{}) do
      PageComment
      |> Ash.Changeset.for_create(
        :master_create,
        Map.merge(
          %{body: "shared trouble", type: :bug, section: :component, document_id: component_id},
          attrs
        ),
        authorize?: false
      )
      |> Ash.create!()
    end

    test "a master may leave one, and it has no site", %{component_id: component_id} do
      assert global_note!(component_id).site_id == nil
    end

    # (a) — the tenant CAN write. A shared component is broken on their site first, and silencing
    # them means the bug reaches a master by email instead.
    test "a tenant may leave one too, stamped with their own site", %{
      site: site,
      component_id: component_id
    } do
      comment =
        PageComment
        |> Ash.Changeset.for_create(
          :create,
          # `site_id` is not even an accepted input on the tenant action — the stamp is forced, so
          # there is no way for a caller to ask for a global note.
          %{body: "broken here", type: :bug, section: :component, document_id: component_id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      assert comment.site_id == site.id,
             "their observation is about their site; a global thread would fill with the same " <>
               "report from every tenant using the component"
    end

    test "a tenant reads the shared thread plus their own, and no other tenant's", %{
      site: site,
      other_site: other,
      component_id: component_id
    } do
      global_note!(component_id, %{body: "everyone sees this"})

      for {tenant, body} <- [{site, "mine"}, {other, "theirs"}] do
        PageComment
        |> Ash.Changeset.for_create(
          :create,
          %{body: body, type: :information, section: :component, document_id: component_id},
          tenant: tenant.id,
          authorize?: false
        )
        |> Ash.create!()
      end

      bodies =
        %{site_id: site.id, section: :component, document_id: component_id}
        |> Review.list()
        |> Enum.map(& &1.body)
        |> Enum.sort()

      assert bodies == ["everyone sees this", "mine"]
    end

    # …but closing it is not theirs to do. Answering on behalf of every other site, about a
    # component they cannot even edit, is not a thing a tenant should be able to do by accident.
    test "a tenant cannot resolve, reopen or delete it", %{site: site, component_id: component_id} do
      comment = global_note!(component_id)

      assert {:error, resolve_error} =
               comment
               |> Ash.Changeset.for_update(:resolve, %{}, tenant: site.id, authorize?: false)
               |> Ash.update()

      assert Exception.message(resolve_error) =~ "Only a master"

      assert {:error, _reopen} =
               comment
               |> Ash.Changeset.for_update(:reopen, %{}, tenant: site.id, authorize?: false)
               |> Ash.update()

      assert {:error, _destroy} =
               comment
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
               |> Ash.destroy()
    end

    test "a master can", %{component_id: component_id, user: user} do
      comment = global_note!(component_id)

      assert {:ok, resolved} =
               comment
               |> Ash.Changeset.for_update(:master_resolve, %{},
                 actor: user,
                 authorize?: false
               )
               |> Ash.update()

      assert resolved.status == :resolved
      assert resolved.resolved_by_id == user.id
    end

    # The guard is about the ROW, not about the document. A tenant's own note on that same shared
    # component has a site, so they close it themselves.
    test "a tenant closes their OWN note on a shared component", %{
      site: site,
      component_id: component_id
    } do
      comment =
        PageComment
        |> Ash.Changeset.for_create(
          :create,
          %{body: "mine to close", type: :bug, section: :component, document_id: component_id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      assert {:ok, resolved} =
               comment
               |> Ash.Changeset.for_update(:resolve, %{}, tenant: site.id, authorize?: false)
               |> Ash.update()

      assert resolved.status == :resolved
    end
  end

  # `fetch/2` reads through `:get_any`, which bypasses multitenancy — so every note handler in the
  # builder, which takes its id straight from `phx-value-id`, was reaching every site's notes by id
  # alone. The list has always been scoped; this is the by-id read catching up.
  describe "fetching one note by id" do
    setup %{site: site, page: page, other_site: other} do
      other_page = create_page!(site_id: other.id, name: "theirs", path: "/theirs")

      %{
        mine: note!(site, %{document_id: page.id, body: "ours"}),
        theirs: note!(other, %{document_id: other_page.id, body: "theirs"}),
        tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
        master: create_user_with_permissions!(["*"])
      }
    end

    test "a tenant gets their own site's note", %{mine: mine, tenant: tenant} do
      assert %{id: id} = Review.fetch(mine.id, %{actor: tenant})
      assert id == mine.id
    end

    test "a tenant gets nothing for another site's note", %{theirs: theirs, tenant: tenant} do
      refute Review.fetch(theirs.id, %{actor: tenant})
    end

    test "a master gets either", %{mine: mine, theirs: theirs, master: master} do
      assert Review.fetch(mine.id, %{actor: master})
      assert Review.fetch(theirs.id, %{actor: master})
    end

    # Fail safe: a scope carrying no actor cannot say whose note this is, so it is nobody's.
    test "nobody with no actor gets anything", %{mine: mine} do
      refute Review.fetch(mine.id, %{})
      refute Review.fetch(mine.id, %{actor: nil})
    end
  end

  describe "finding the element a note is about" do
    alias MishkaCmsCore.Runtime.PageBuilder.Tree

    test "answers with the node when it is still there" do
      {:ok, tree} = Tree.parse(~s(<section><h1>Hi</h1></section>))
      [root] = tree.roots

      assert Review.locate(%{node_id: root}, tree) == {:ok, root}
    end

    test "says so when the element has gone" do
      {:ok, tree} = Tree.parse(~s(<section></section>))

      assert Review.locate(%{node_id: "nzzzzzzzz"}, tree) == :gone
    end

    # A page note and a deleted element are different situations and deserve different words.
    test "tells a page note apart from a missing one" do
      {:ok, tree} = Tree.parse(~s(<section></section>))

      assert Review.locate(%{node_id: nil}, tree) == :page
      assert Review.locate(nil, tree) == :gone
    end
  end
end
