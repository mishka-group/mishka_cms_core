# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.PageBuilderEventTest do
  @moduledoc """
  The editing log itself: what it accepts, who it says made each change, and which rows a given
  branch answers with.

  Three of these pin bugs that were silent rather than loud, which is why they are worth a test each:

    * a change written with an actor but no author, because `relate_actor` cannot manage a
      relationship whose attribute is not writable, and failed without saying so;
    * a page's own timeline reading back empty, because a pinned `nil` reaches Postgres as
      `draft_id = NULL` and that is never true of any row;
    * a draft's timeline hiding the page's history, which looks exactly like losing it.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{PageBuilderEvent, PageBuilderSnapshot}

  require Ash.Query

  @moduletag :unit

  setup do
    site = create_site!()
    page = create_page!(site_id: site.id)
    author = create_user!(site_id: site.id)

    %{site: site, page: page, author: author}
  end

  defp record(context, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          # The row carries the id of the editor's own entry, so a gesture that settles over several
          # flushes upserts one row rather than accumulating near-duplicates.
          id: Ecto.UUID.generate(),
          source_type: :page,
          source_id: context.page.id,
          site_id: context.site.id,
          label: "Set gap (base)",
          kind: :style,
          op: :set_style
        },
        overrides
      )

    PageBuilderEvent
    |> Ash.Changeset.for_create(:create, attrs,
      tenant: context.site.id,
      actor: context[:actor] || context.author,
      authorize?: false
    )
    |> Ash.create(actor: context[:actor] || context.author, authorize?: false)
  end

  defp anchored(context, branch_id) do
    PageBuilderEvent
    |> Ash.Query.for_read(
      :for_anchor,
      %{source_type: :page, source_id: context.page.id, draft_id: branch_id},
      authorize?: false
    )
    |> Ash.read!(authorize?: false, page: false)
  end

  describe "who made the change" do
    test "the author comes from the actor, never from input", context do
      assert {:ok, row} = record(context)

      assert row.author_id == context.author.id
    end

    test "an author cannot be supplied as input at all", context do
      stranger = create_user!(site_id: context.site.id)

      assert {:error, error} = record(context, %{author_id: stranger.id})

      # Refused rather than quietly overwritten: a form that could name the author is a form that
      # could name someone else's, and the action does not accept the field in the first place.
      assert Exception.message(error) =~ "author_id"
    end

    test "a change with no actor is the platform's own", context do
      assert {:ok, row} =
               PageBuilderEvent
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   id: Ecto.UUID.generate(),
                   source_type: :page,
                   source_id: context.page.id,
                   site_id: context.site.id,
                   label: "Published contact",
                   kind: :publish,
                   op: :publish,
                   author_type: :system
                 },
                 tenant: context.site.id,
                 authorize?: false
               )
               |> Ash.create(authorize?: false)

      assert row.author_id == nil
      assert row.author_type == :system
    end

    test "the assistant's rows still record the person who asked", context do
      assert {:ok, row} =
               record(context, %{
                 author_type: :ai,
                 note: "Added a row of three customer quotes below the hero.",
                 prompt: "add some social proof",
                 backend: "claude-opus-5"
               })

      assert row.author_type == :ai
      assert row.author_id == context.author.id
      assert row.prompt == "add some social proof"
    end
  end

  describe "annotating" do
    test "a note stamps who wrote it and when", context do
      reader = create_user!(site_id: context.site.id)
      {:ok, row} = record(context, %{author_type: :ai, note: "Made the header sticky."})

      assert {:ok, annotated} =
               row
               |> Ash.Changeset.for_update(:annotate, %{note: "Covers the hero on a phone."},
                 actor: reader,
                 authorize?: false
               )
               |> Ash.update(actor: reader, authorize?: false)

      assert annotated.note == "Covers the hero on a phone."
      assert annotated.note_author_id == reader.id
      assert %DateTime{} = annotated.note_edited_at
    end

    test "annotating changes the note and nothing the row records", context do
      {:ok, row} = record(context, %{detail: "gap: 20px · base"})

      {:ok, annotated} =
        row
        |> Ash.Changeset.for_update(:annotate, %{note: "Deliberate."},
          actor: context.author,
          authorize?: false
        )
        |> Ash.update(actor: context.author, authorize?: false)

      assert annotated.label == row.label
      assert annotated.op == row.op
      assert annotated.detail == "gap: 20px · base"
      assert annotated.author_id == row.author_id
    end
  end

  describe "the anchor" do
    test "a page's change must name the site it belongs to", context do
      assert {:error, error} = record(context, %{site_id: nil})

      assert Exception.message(error) =~ "site"
    end

    test "the timestamp is given, not stamped on write", context do
      then = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert {:ok, row} = record(context, %{inserted_at: then})

      assert DateTime.compare(row.inserted_at, then) == :eq
    end
  end

  describe "which branch a timeline answers with" do
    setup context do
      {:ok, live} = record(context, %{label: "On the page itself"})
      %{live: live}
    end

    test "the live record answers with its own rows", context do
      assert [row] = anchored(context, nil)
      assert row.id == context.live.id
    end

    test "a nil branch is `is_nil`, not `= NULL`", context do
      # The bug this pins returned zero rows rather than an error, so a count is the whole assertion.
      refute anchored(context, nil) == []
    end

    test "a draft answers with the page's history and its own on top", context do
      draft = draft_for(context.page)
      {:ok, drafted} = record(context, %{label: "Only on the draft"})

      {:ok, _} =
        drafted
        |> Ash.Changeset.for_update(:adopt_draft, %{draft_id: draft.id}, authorize?: false)
        |> Ash.update(authorize?: false)

      ids = anchored(context, draft.id) |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(ids, context.live.id),
             "the page's own history is missing from its draft"

      assert MapSet.member?(ids, drafted.id)
    end

    test "a draft's changes stay out of the page's timeline", context do
      draft = draft_for(context.page)
      {:ok, drafted} = record(context, %{label: "Only on the draft"})

      {:ok, _} =
        drafted
        |> Ash.Changeset.for_update(:adopt_draft, %{draft_id: draft.id}, authorize?: false)
        |> Ash.update(authorize?: false)

      ids = anchored(context, nil) |> Enum.map(& &1.id)

      refute drafted.id in ids
    end

    test "another page's changes never appear", context do
      other = create_page!(site_id: context.site.id)

      {:ok, _elsewhere} =
        record(%{context | page: other}, %{source_id: other.id, label: "Somewhere else"})

      assert [row] = anchored(context, nil)
      assert row.id == context.live.id
    end
  end

  describe "reading a long timeline" do
    test "the primary read pages, so the sheet can offer more", context do
      for index <- 1..15 do
        {:ok, _} = record(context, %{label: "Change #{index}"})
      end

      page =
        PageBuilderEvent
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.filter(source_id == ^context.page.id)
        |> Ash.read!(authorize?: false, page: [limit: 12, count: true])

      assert length(page.results) == 12
      assert page.count == 15
      assert page.more?
    end

    test "and still answers with everything when asked for everything", context do
      for index <- 1..15 do
        {:ok, _} = record(context, %{label: "Change #{index}"})
      end

      rows =
        PageBuilderEvent
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.filter(source_id == ^context.page.id)
        |> Ash.read!(authorize?: false, page: false)

      assert length(rows) == 15
    end

    test "newest first", context do
      {:ok, _older} =
        record(context, %{
          label: "Older",
          inserted_at: DateTime.add(DateTime.utc_now(), -600, :second)
        })

      {:ok, _newer} = record(context, %{label: "Newer"})

      assert ["Newer", "Older"] = anchored(context, nil) |> Enum.map(& &1.label)
    end
  end

  # A MASTER IS A USER WHOSE `site_id` IS NIL, and nothing else is one: not "*", not a missing actor.
  # A site user acts on its own site's history alone, whichever read it asks through.
  describe "whose history an actor reaches" do
    setup context do
      other = create_site!()
      other_page = create_page!(site_id: other.id)
      other_author = create_user!(site_id: other.id)

      {:ok, mine} = record(context)

      {:ok, theirs} =
        record(Map.merge(context, %{site: other, page: other_page, actor: other_author}))

      %{other: other, other_page: other_page, mine: mine, theirs: theirs}
    end

    defp ids_read_by(actor, action) do
      PageBuilderEvent
      |> Ash.Query.for_read(action, %{}, actor: actor)
      |> Ash.read!(actor: actor)
      |> MapSet.new(& &1.id)
    end

    test "a site user holding every permission reads only its own site's rows, even through :read_any",
         context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      ids = ids_read_by(star, :read_any)

      assert MapSet.member?(ids, context.mine.id)
      refute MapSet.member?(ids, context.theirs.id)
    end

    test "a master reads every site's rows", context do
      master = create_user_with_permissions!(["*"])

      ids = ids_read_by(master, :read_any)

      assert MapSet.member?(ids, context.mine.id)
      assert MapSet.member?(ids, context.theirs.id)
    end

    # A READ IS FILTERED TO THE BUILDERS THE READER MAY OPEN, and nobody opens none.
    test "no user reads nothing", context do
      assert {:ok, []} =
               PageBuilderEvent
               |> Ash.Query.for_read(:read_any, %{}, actor: nil)
               |> Ash.read(actor: nil)

      assert context.mine.id in ids_read_by(
               create_user_with_permissions!(["admin:dashboard:runtime:page"],
                 site_id: context.site.id
               ),
               :read_any
             )
    end

    test "a site user cannot write a row into another site's history", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               PageBuilderEvent
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   id: Ecto.UUID.generate(),
                   source_type: :page,
                   source_id: context.other_page.id,
                   site_id: context.other.id,
                   label: "Planted",
                   kind: :content,
                   op: :set_text
                 },
                 tenant: context.other.id,
                 actor: star
               )
               |> Ash.create(actor: star)
    end

    test "nor clear a row of another site", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      assert {:error, _refused} = Ash.destroy(context.theirs, actor: star)

      assert PageBuilderEvent
             |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
             |> Ash.Query.filter(id == ^context.theirs.id)
             |> Ash.exists?(authorize?: false)
    end

    test "a site user cannot take another site's row over by writing its id", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      assert {:error, _refused} =
               write_as(star, context.site.id, %{
                 id: context.theirs.id,
                 source_id: context.page.id,
                 site_id: context.site.id,
                 label: "Taken over"
               })

      kept = row_by_id(context.theirs.id)
      assert kept.site_id == context.other.id
      assert kept.source_id == context.other_page.id
      assert kept.label == context.theirs.label
    end

    test "nor move one of its own rows onto another document", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)
      sibling = create_page!(site_id: context.site.id)

      assert {:error, _refused} =
               write_as(star, context.site.id, %{
                 id: context.mine.id,
                 source_id: sibling.id,
                 site_id: context.site.id
               })

      assert row_by_id(context.mine.id).source_id == context.page.id
    end

    test "a retried write of the same row still lands on it", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      assert {:ok, row} =
               write_as(star, context.site.id, %{
                 id: context.mine.id,
                 source_id: context.page.id,
                 site_id: context.site.id,
                 label: "Settled"
               })

      assert row.id == context.mine.id
      assert row_by_id(context.mine.id).label == "Settled"
    end

    test "a master's retried write of a shared layout's row still lands on it", _context do
      master = create_user_with_permissions!(["*"])
      layout = create_layout!(site_id: nil)
      attrs = %{id: Ecto.UUID.generate(), source_type: :layout, source_id: layout.id}

      assert {:ok, _first} = write_as(master, nil, Map.put(attrs, :label, "First"))
      assert {:ok, _again} = write_as(master, nil, Map.put(attrs, :label, "Settled"))

      assert %{site_id: nil, label: "Settled"} = row_by_id(attrs.id)
    end

    test "a row names no restore point from input", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      {:ok, payload, size} =
        PageBuilderSnapshot.compress(
          ~s(<div id="root"><h1>SECRET-OF-SITE-B</h1></div>),
          PageBuilderSnapshot.max_bytes(:human)
        )

      theirs =
        PageBuilderSnapshot
        |> Ash.Changeset.for_create(:create, %{payload: payload, byte_size: size},
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

      assert {:error, error} =
               write_as(star, context.site.id, %{
                 source_id: context.page.id,
                 site_id: context.site.id,
                 snapshot_id: theirs.id
               })

      assert Exception.message(error) =~ "snapshot_id"
    end
  end

  defp write_as(actor, tenant, attrs) do
    PageBuilderEvent
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          source_type: :page,
          label: "Edit",
          kind: :content,
          op: :set_text
        },
        attrs
      ),
      tenant: tenant,
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp row_by_id(id) do
    PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp draft_for(page) do
    MishkaCmsCore.Runtime.PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{
        source_page_id: page.id,
        name: "Draft under test",
        title: "Draft under test",
        path: "/draft-under-test",
        template: "<div></div>"
      },
      tenant: page.site_id,
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
