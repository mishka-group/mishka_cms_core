defmodule MishkaCmsCore.Runtime.PageBuilderEvent do
  @moduledoc """
  One recorded change to a document in the visual editor — the durable half of the editor's history.

  The undo stack in `MishkaCmsCore.Runtime.PageBuilder.EditorSession` is still what Ctrl+Z walks: in
  memory, fast, and gone when the session ends. This is what the history sheet reads, what a
  colleague sees, and what says who changed what — including the assistant.

  ## What it anchors to

  `source_type` + `source_id` name the LIVE record, always, for all four editable kinds. `draft_id`
  only says which branch the change happened on, and is `nil` for work done with no draft (the
  editor's published stage). Two consequences fall out of that shape rather than being coded:

    * "show me this draft's history" is a filter, not a second system;
    * publishing deletes the draft row, `ON DELETE SET NULL` clears `draft_id`, and the rows simply
      join the live record's own timeline. Nothing re-anchors them.

  ## What it is not

  Lean and append-only, deliberately unlike its neighbours: no archive, no unarchive, no version
  actions, no JSON:API routes. The house template is built for content a person edits through a form;
  this is a log written by the editor. Every action it does not have is one that cannot be misused.

  The one mutable field is `note` — an annotation ABOUT a row rather than a claim about what happened,
  so editing it labels history instead of rewriting it. `note_author_id` travels with it, because
  otherwise a colleague's note on an assistant's row reads as the assistant's own words.

  ## Attribution

  `author_id` is never accepted from input: it is set from the actor, and it is ALWAYS the human —
  including on an `:ai` row, where the human is whoever's editor ran the prompt. `author_type` says
  who performed the change. Rendering the pair is `MishkaCmsCoreWeb.Templates.HistoryTimeline`'s job,
  and it must branch on `author_type` BEFORE the email-masking ladder, or an assistant's row prints
  the operator's address.

  See `MishkaCmsCore.Runtime.PageBuilderSnapshot` (the document a row restores) and
  `MishkaCmsCore.Runtime.PageBuilder.History` (how rows are written).
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaGervaz.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias MishkaCmsCore.Runtime.Resources.Validations.{AnchorSiteRequired, SameSiteReference}

  require Ash.Query

  @sources [:page, :layout, :error_page, :component]

  @documents %{
    page: MishkaCmsCore.Runtime.Page,
    layout: MishkaCmsCore.Runtime.Layout,
    error_page: MishkaCmsCore.Runtime.ErrorPage,
    component: MishkaCmsCore.Runtime.Component
  }

  @drafts %{}
  @buckets [:content, :style, :publish]
  @author_types [:human, :ai, :system]

  @doc "The four editable kinds a change can be anchored to."
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc "The three buckets the timeline's pills filter on."
  @spec buckets() :: [atom()]
  def buckets, do: @buckets

  postgres do
    table "page_builder_events"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete

      # A dropped payload must leave a READABLE row — that is what makes "keep the label, lose the
      # snapshot" a usable answer to the cap instead of a hole in the timeline.
      reference :snapshot, on_delete: :nilify

      # A DRAFT IS NOT ONE TABLE. `source_type` names all four editable kinds, and three of them keep
      # their drafts in tables of their own — `layout_drafts`, `error_page_drafts` — so a foreign key
      # to `page_drafts` alone refused every row a layout or an error page ever produced on a draft
      # branch, and the flush logged a warning and dropped it. `draft_id` is a plain id now, and
      # `MishkaCmsCore.Runtime.PageBuilder.Drafts.destroy/2` releases it when the draft goes, which is
      # what `on_delete: :nilify` used to do for the one table it could name.
    end

    custom_indexes do
      # The sheet's only read: this anchor, this branch, newest first.
      index [:source_type, :source_id, :draft_id, :inserted_at]
      index [:site_id]
    end

    check_constraints do
      check_constraint :site_id, "page_builder_event_anchor_site_check",
        check: "source_type NOT IN ('page', 'error_page') OR site_id IS NOT NULL",
        message:
          dgettext_noop(
            "errors",
            "a page or error page always belongs to a site, so its history cannot be global"
          )
    end
  end

  mishka_gervaz do
    table do
      identity do
        name :page_builder_events
        route "/admin/dashboard/runtime/builder"
        stream_name :page_builder_events
      end

      source do
        actions do
          read :read
          get :read
        end

        # THE MASKING LADDER MATCHES ON A LOADED AUTHOR. An `%Ash.NotLoaded{}` is truthy and matches
        # none of its clauses, so without this every row — including a master's own — falls through
        # to "System administrator" and the timeline claims nobody is who they are.
        preload do
          always [:author, :note_author, :author_master?, :note_author_master?]
        end
      end

      # One static column carrying the whole row: the template owns the rail, the badge, the note
      # card and the Revert control, and unpacks the record itself.
      columns do
        default_sort inserted_at: :desc

        column :entry do
          static true

          requires [
            :label,
            :kind,
            :op,
            :target,
            :detail,
            :note,
            :author_type,
            :author_id,
            :note_author_id,
            :prompt,
            :backend,
            :snapshot_id,
            :refused,
            :inserted_at
          ]

          label fn -> dgettext("mishka_gervaz", "Change") end
          position :first
        end
      end

      filters do
        filter :kind, :select,
          options: fn ->
            [
              {dgettext("mishka_gervaz", "Content"), "content"},
              {dgettext("mishka_gervaz", "Style"), "style"},
              {dgettext("mishka_gervaz", "Publish"), "publish"}
            ]
          end
      end

      pagination do
        type :load_more
        page_size 12
      end

      presentation do
        features [:filter, :paginate]
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No changes recorded yet"),
                  icon: "hero-clock"

      hooks do
        # WHAT THE EDITOR IS ON, carried in `path_params` exactly as the draft picker beside it does.
        # `draft_id` is part of the scope rather than an extra filter: nil means the live record's own
        # branch, which is the editor's published stage, and matching it loosely would mix a draft's
        # changes into the page's timeline.
        #
        # An unscoped read answers NOTHING rather than everything — a table that fell back to every
        # row would show one site's editing history to another's admin.
        on_load fn
          query, %{path_params: %{source_type: type, source_id: id} = params}
          when not is_nil(type) and not is_nil(id) ->
            query = Ash.Query.filter(query, source_type == ^type and source_id == ^id)

            # A DRAFT IS A BRANCH OFF THE LIVE RECORD, so its timeline is the page's own history with
            # the draft's changes on top — the way a branch reads in any version control. Scoping a
            # draft to only its own rows made the entire history vanish the moment the editor created
            # one, which reads as data loss even though nothing was lost.
            #
            # The live record still shows only its own rows: a draft's unpublished changes must not
            # appear in the page's timeline before anyone has agreed to publish them.
            #
            # `is_nil` rather than `== ^nil`, which Postgres reads as `= NULL` and never matches.
            branch = Map.get(params, :branch_id)

            scoped =
              case branch do
                nil -> Ash.Query.filter(query, is_nil(draft_id))
                branch -> Ash.Query.filter(query, is_nil(draft_id) or draft_id == ^branch)
              end

            # An extension scopes the timeline HERE rather than after the read, because the sheet
            # pages: rows dropped afterwards would leave a page of twenty showing twelve, with no
            # way to ask for the missing eight.
            {:cont,
             MishkaCmsCore.Builder.Events.history_query(scoped, %{
               source_type: type,
               source_id: id,
               branch_id: branch
             })}

          query, _unscoped ->
            {:cont, Ash.Query.filter(query, false)}
        end
      end

      # OFF. The sheet is opened on demand; re-reading it on every write to the site, for everyone,
      # is the noisy behaviour this design exists to avoid. Liveness comes from the editor's own op
      # broadcast, which the builder LiveView already receives and forwards with `send_update`.
      realtime do
        enabled false
      end
    end
  end

  actions do
    default_accept [
      :id,
      :source_type,
      :source_id,
      :draft_id,
      :site_id,
      :label,
      :kind,
      :op,
      :target,
      :detail,
      :note,
      :author_type,
      :prompt,
      :backend,
      :refused,
      :inserted_at
    ]

    # PAGINATED, because the sheet's "Load more" is only offered when the read can answer whether
    # there is more. A default `read` cannot, so a long timeline silently stopped at its first
    # twelve rows with no way to reach the rest.
    #
    # `required?: false` keeps `page: false` working for the callers that want the whole log —
    # retention, and clearing a page's history.
    read :read do
      primary? true

      pagination offset?: true,
                 default_limit: 12,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      description "The log, newest first, a page at a time."
    end

    # CREATE
    create :create do
      primary? true

      # The id is minted in memory when the entry settles, so a flush that times out and retries
      # UPSERTS rather than growing a duplicate row on a flaky connection. No `upsert_identity` —
      # the id IS the primary key, so Ash upserts on that; naming an identity that does not exist
      # fails the write, and this path swallows write errors by design.
      upsert? true

      # A RETRY LANDS ON ITS OWN ROW ONLY. The id arrives with the write, so without this an id of
      # another site's row rewrote that row into the writer's site and document. The row already
      # there must name the same site and the same document, or the write is refused.
      upsert_condition expr(
                         source_type == upsert_conflict(:source_type) and
                           source_id == upsert_conflict(:source_id) and
                           ((is_nil(site_id) and is_nil(upsert_conflict(:site_id))) or
                              site_id == upsert_conflict(:site_id))
                       )

      # THE RESTORE POINT COMES FROM THE CODE THAT STORED IT, never from input: a private argument,
      # passed as `private_arguments: %{snapshot_id: id}` by `PageBuilder.History` and the seeds.
      # Naming `snapshot_id` in input is refused, so no row can be pointed at another site's
      # document and read it back through `:snapshot`.
      argument :snapshot_id, :uuid, public?: false, allow_nil?: true

      validate {AnchorSiteRequired, []}

      change set_attribute(:snapshot_id, arg(:snapshot_id))

      # NEVER FROM INPUT. `author_id` is absent from `default_accept` above, so it cannot be cast —
      # it is written here from the actor, which is the whole attribution story and must not be
      # something a caller can claim. `set_attribute` with the actor template rather than
      # `relate_actor`: that one manages the relationship, which a `writable? false` attribute
      # refuses, and it refuses SILENTLY — every row landed with a null author.
      change set_attribute(:author_id, actor(:id))

      # THE ROW'S OWN SITE, for everything it names: the document and the draft are that site's or
      # shared ones, and the author is that site's account or a master.
      validate {SameSiteReference,
                field: :source_id,
                resource: {:source_type, @documents},
                label: dgettext_noop("errors", "document"),
                shared?: true}

      validate {SameSiteReference,
                field: :draft_id,
                resource: {:source_type, @drafts},
                label: dgettext_noop("errors", "draft"),
                shared?: true}

      # The author is the actor, so an authorized write is judged by the policies first; this
      # holds the writes that skip them.
      validate {SameSiteReference,
                field: :author_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "author"),
                shared?: true,
                read_action: :related},
               before_action?: true

      description "Records one settled change from the visual editor."
    end

    # UPDATE
    update :annotate do
      require_atomic? false
      accept [:note]

      change set_attribute(:note_author_id, actor(:id))
      change set_attribute(:note_edited_at, &DateTime.utc_now/0)

      validate {SameSiteReference,
                field: :note_author_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "note's author"),
                shared?: true,
                read_action: :related},
               before_action?: true

      description "Writes a human's own summary onto a row, without changing what the row records."
    end

    update :adopt_draft do
      require_atomic? false
      accept [:draft_id]

      validate {SameSiteReference,
                field: :draft_id,
                resource: {:source_type, @drafts},
                label: dgettext_noop("errors", "draft"),
                shared?: true}

      description "Attaches a change made before its draft existed to the draft that now holds it."
    end

    # WHAT THE FOREIGN KEY USED TO DO. `draft_id` names a row in one of three draft tables, so no
    # single key could nilify it when that row went — see the `references` block. Publishing and
    # discarding both delete the draft, and its rows must stay and join the live record's timeline
    # rather than sit in a branch nothing can name.
    update :release_draft do
      accept []

      change set_attribute(:draft_id, nil)

      description "Detaches every change from a draft that no longer exists."
    end

    # READ
    read :for_anchor do
      argument :source_type, :atom, allow_nil?: false, constraints: [one_of: @sources]
      argument :source_id, :uuid, allow_nil?: false
      argument :draft_id, :uuid, allow_nil?: true

      # THE SAME BRANCH RULE THE TABLE READS BY, so the two do not disagree about what a branch
      # contains: a draft is the page's history plus its own changes, the live record is its own
      # rows alone. `is_nil` rather than `== ^nil`, which Postgres reads as `= NULL`.
      filter expr(
               source_type == ^arg(:source_type) and source_id == ^arg(:source_id) and
                 if(is_nil(^arg(:draft_id)),
                   do: is_nil(draft_id),
                   else: is_nil(draft_id) or draft_id == ^arg(:draft_id)
                 )
             )

      prepare build(sort: [inserted_at: :desc], load: [:author, :note_author])

      pagination offset?: true,
                 default_limit: 12,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      description "One document's recorded changes, on one branch, newest first."
    end

    read :read_any do
      multitenancy :bypass
      description "Internal reads that span sites — retention, and the activity feed."
    end

    # DESTROY
    destroy :destroy do
      primary? true

      description "Clears a row. Only ever a whole anchor's history at once — see History.clear/3."
    end
  end

  policies do
    # HISTORY IS THE BUILDER'S, per type: writing and reading a document's history needs a name that
    # opens the builder on its `source_type` (`MishkaCmsCore.Runtime.PageBuilder.Section`).
    policy action_type([:create, :read, :update, :destroy]) do
      authorize_if {MishkaCmsCore.Runtime.PageBuilder.BuilderAccess, field: :source_type}
    end

    # WHOSE HISTORY, on top of which permission. A master (`site_id` nil) reaches every site's rows;
    # a site user reaches its own site's alone, whatever it holds and whichever read it asks through
    # — `:read_any` included. A call with no actor reaches nothing; system work passes
    # `authorize?: false`.
    policy always() do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    # NOT `uuid_primary_key` — the id arrives from the editor, minted when the entry settled, so the
    # retry of a failed flush can upsert onto it.
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
      writable? true
      description "Minted in the editor when the entry settled, so a retried flush upserts"
    end

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @sources
      description "Which kind of record this change was made to"
    end

    attribute :source_id, :uuid do
      allow_nil? false
      public? true
      description "The LIVE record, always — never the draft"
    end

    attribute :draft_id, :uuid do
      allow_nil? true
      public? true
      description "Which branch the change happened on; nil is the live record's own"
    end

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints max_length: 160, trim?: true
      description "The headline, in the words the editor used"
    end

    # STORED, not derived. Today the sheet computes this from a list of op names, and that list will
    # drift — a row written last month must keep the bucket it was filed under.
    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @buckets
      description "The bucket the timeline's pills filter on"
    end

    attribute :op, :atom do
      allow_nil? false
      public? true

      description "The raw operation. The BADGE reads this; the bucket is `kind`, and a restore files under publish while reading RESTORE"
    end

    attribute :target, :string do
      allow_nil? true
      public? true
      constraints max_length: 120, trim?: true
      description "The element by the name it has on screen"
    end

    attribute :detail, :string do
      allow_nil? true
      public? true
      constraints max_length: 240, trim?: true
      description "What changed, joined to `target` with a middle dot"
    end

    # Shared by both meanings: a consequence warning the editor raises ("3 nested elements went with
    # it"), and the assistant's own sentence. Both are "the thing worth saying that is not the label".
    attribute :note, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "A 1–3 line summary; the template clamps longer ones behind an expander"
    end

    attribute :note_edited_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When a human last rewrote the note"
    end

    attribute :author_type, :atom do
      allow_nil? false
      public? true
      default :human
      constraints one_of: @author_types
      description "Who performed the change — not whose session it was"
    end

    attribute :prompt, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "The instruction that produced an assistant's change"
    end

    attribute :backend, :string do
      allow_nil? true
      public? true
      constraints max_length: 80, trim?: true
      description "Which assistant made it — impossible to backfill once the model changes"
    end

    attribute :refused, :boolean do
      allow_nil? false
      public? true
      default false

      description "The document was past the size a snapshot is taken of, so this cannot be reverted"
    end

    # NOT a `create_timestamp`. Rows settle in memory and flush in batches, so a generated timestamp
    # would stamp a whole batch with the moment the WRITE landed and lose the order the changes
    # actually happened in. The editor sends the settle time.
    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      writable? true
      default &DateTime.utc_now/0
      description "When the change settled in the editor — not when the row was written"
    end
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      attribute_writable? true
      public? true
    end

    # Nullable and released on delete: publishing removes the draft and its rows stay, joined to the
    # live record's timeline. Deliberately NOT a `belongs_to` — see the `references` block for which
    # four tables a draft can live in and why one key could not name them.

    belongs_to :snapshot, MishkaCmsCore.Runtime.PageBuilderSnapshot do
      allow_nil? true
      attribute_writable? true
      public? true
    end

    # ALWAYS THE HUMAN, including on an `:ai` row — the person whose editor ran the prompt.
    # Writable so the change above can set them; absent from `default_accept`, so nothing outside
    # this resource can. That pairing is what makes "never from input" true without making the
    # attribute unwritable to its own actions.
    belongs_to :author, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      domain MishkaCmsCore.Accounts
      allow_nil? true
      attribute_writable? true
      public? true
    end

    belongs_to :note_author, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      domain MishkaCmsCore.Accounts
      allow_nil? true
      attribute_writable? true
      public? true
    end
  end

  calculations do
    calculate :author_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :author_id} do
      description "Whether the author is a master, for a reader who cannot load a master's account"
    end

    calculate :note_author_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :note_author_id} do
      description "Whether the note's author is a master, for a reader who cannot load a master's account"
    end
  end
end
