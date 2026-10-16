# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageComment do
  @moduledoc """
  A note left on a document in the visual editor — on one element, or on the page as a whole.

  ## Why this exists

  Review notes lived on the editing session: a list on the `EditorSession` struct, in ETS, swept
  after a day idle. `MishkaCmsCore.Runtime.PageBuilder.Comment`'s own moduledoc said so and named
  the next step. A note that does not survive the afternoon is not a review; it is a sticky note on
  a screen someone is about to close.

  The field shape is that struct's, deliberately, so the swap is storage and not a rewrite: the
  node it points at, the label captured beside it, who wrote it, whether it is resolved.

  ## What a comment is attached to

  Two scopes, and the difference is one nullable column:

    * `node_id` set — a note on ONE element. The id is the editor's own `n<8>` handle, which is
      minted by `Tree.parse/1` and therefore changes every time the document is re-parsed. It is a
      soft reference on purpose and can never be a foreign key.
    * `node_id` nil — a note on the whole page.

  `node_label` is captured at write time for exactly that reason. The element can be deleted, or the
  document re-parsed under it, and the note still reads "on the `<h1>`" instead of pointing at
  nothing. `MishkaCmsCore.Runtime.PageBuilder.Review.locate/2` is what turns a stale id back into a
  selection, or into a plain "that element is gone".

  ## Who wrote it

  `author_type` is `:human`, `:ai` or `:system`, and `author_id` is nullable, because the other two
  have no user row. Nothing here implements AI review; what it does is make sure that when
  something does, it is a new value in an existing column rather than a second comment system beside
  this one. `resolved_by_id` is separate from `author_id` for the same reason — the thing that
  resolves a note is often not the thing that raised it.

  ## Scope

  `global? true` with a nullable `site_id`, matching `MishkaCmsCore.Runtime.Snippet`, because the
  builder edits both tenant documents (pages, layouts, error pages) and global ones (components). A
  comment on a global component belongs to no site.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Resources.Changes.NotifyMentions
  alias MishkaCmsCore.Runtime.Resources.Validations.GlobalRowIsMasterOnly
  alias MishkaCmsCore.Runtime.Resources.Validations.ParentBelongsToDocument
  alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference
  alias MishkaCmsCore.Runtime.Resources.Validations.SiteScopedDocument
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  require Ash.Query

  postgres do
    table "page_comments"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete

      # DELETING A QUESTION DELETES ITS ANSWERS. Without this the database refuses to delete a note
      # that has been replied to — the answers still point at it — and the reader is told a note
      # cannot be deleted with no way to find out why. A thread is one thing; it goes as one.
      reference :parent_comment, on_delete: :delete
    end

    custom_indexes do
      index [:site_id]
      index [:section, :document_id]
      index [:status]
      index [:type]
    end

    check_constraints do
      check_constraint :body, "page_comment_body_length_check",
        check: "length(body) >= 1 AND length(body) <= 4000",
        message:
          dgettext_noop("errors", "A note needs something in it, and under 4000 characters.")
    end
  end

  # `status`, `resolved_at` and `resolved_by_id` are absent on purpose: resolving is its own action,
  # not a field anyone types into. A form that could set `status` directly would let a note be filed
  # as already-resolved, which is not a thing anyone means to do.
  @editable_fields [
    :body,
    :type,
    :node_id,
    :node_path,
    :node_label,
    :section,
    :document_id,
    :parent_comment_id
  ]
  @admin_fields @editable_fields ++ [:site_id, :author_id, :author_type]

  # What the Review sheet loads to name who wrote a note, who resolved it and who it mentions.
  @byline [:author, :resolved_by, :author_master?, :resolved_by_master?, :master_mentions]

  # THE VOCABULARY, in one place: the form's options, the composer's select, the stored attribute's
  # constraint and the counter all read this list. Six is enough to sort a review by and few enough to
  # choose from without thinking.
  @types [:bug, :information, :suggestion, :question, :task, :other]
  @type_options [
    {dgettext_noop("mishka_gervaz", "Bug"), "bug"},
    {dgettext_noop("mishka_gervaz", "Information"), "information"},
    {dgettext_noop("mishka_gervaz", "Suggestion"), "suggestion"},
    {dgettext_noop("mishka_gervaz", "Question"), "question"},
    {dgettext_noop("mishka_gervaz", "Task"), "task"},
    {dgettext_noop("mishka_gervaz", "Other"), "other"}
  ]

  @documents %{
    page: MishkaCmsCore.Runtime.Page,
    layout: MishkaCmsCore.Runtime.Layout,
    error_page: MishkaCmsCore.Runtime.ErrorPage,
    component: MishkaCmsCore.Runtime.Component
  }

  @doc "Every comment type, in the order the form offers them."
  @spec types() :: [atom()]
  def types, do: @types

  @doc "Every comment type as a `{label, value}` option, in the order of `types/0`."
  @spec type_options() :: [{String.t(), String.t()}]
  def type_options do
    Enum.map(@type_options, fn {label, value} ->
      {Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label), value}
    end)
  end

  mishka_gervaz do
    table do
      identity do
        name :review_comments
        route "/admin/dashboard/runtime/builder"
        stream_name :review_comments
      end

      source do
        actions do
          read {:for_editor, :for_editor}
          get {:get_any, :read}
        end
      end

      columns do
        column :body do
          label fn -> dgettext("mishka_gervaz", "Note") end
        end

        column :type do
          label fn -> dgettext("mishka_gervaz", "Type") end
        end

        column :status do
          label fn -> dgettext("mishka_gervaz", "Status") end
        end
      end

      # OPEN / ALL IS A REAL FILTER, not a pair of chips that look like one. The template drew them
      # and pushed Gervaz's `filter` event, but with no `filters` section declared the handler
      # reduces over an empty list, produces the same empty map it started with, and returns — a
      # silent no-op. Declaring it is the whole fix.
      #
      # No `options` on purpose: with none, Gervaz derives them from the Ash attribute's
      # `one_of: [:open, :resolved]`, so the filter and the column can never disagree about what a
      # status is. The value travels as a string and `Ash.Query.filter_input/2` casts it back to the
      # atom.
      filters do
        filter :status, :select do
          ui do
            prompt dgettext_noop("mishka_gervaz", "All")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end
      end

      pagination do
        type :load_more
        page_size 50
      end

      hooks do
        on_load fn query, state -> {:cont, __MODULE__.for_editor_arguments(query, state)} end
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.ReviewComments
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Review
        keep_loaded_records true
      end

      url_sync do
        enabled false
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No notes on this page yet"),
                  icon: "hero-chat-bubble-left-right"
    end

    form do
      identity do
        name :review_comment
        route "/admin/dashboard/runtime/builder"
      end

      # A NOTE IS WRITTEN ONCE. It is replied to, resolved, reopened or deleted, each through its own
      # action, and never reopened in this form — so the form has no edit mode to offer.
      source do
        actions do
          create {:master_create, :create}
        end

        access :update, false
      end

      fields do
        field :body, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Note") end
            rows 3
          end
        end

        field :type, :select do
          required true
          options fn -> __MODULE__.type_options() end

          ui do
            label fn -> dgettext("mishka_gervaz", "Type") end
          end
        end
      end

      hooks do
        before_save fn params, state ->
          case __MODULE__.refuse(params) do
            nil -> {:cont, __MODULE__.apply_scope(params, state)}
            message -> {:halt, __MODULE__.tell_editor(message)}
          end
        end
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.ReviewCommentForm
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Review
      end
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @editable_fields

      validate present([:body, :type, :section])
      validate {TenantContext, require_master: false}
      validate {SiteScopedDocument, sections: [:page, :error_page]}

      # THE STAMP. A tenant's note is ALWAYS theirs, whatever it is about — including a note on a
      # global component, which is stored against their own site rather than globally. Their
      # observation is about their site, and one global thread would fill with the same report from
      # every tenant using the component. It is forced rather than accepted so no caller can decide
      # otherwise.
      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      # NEVER FROM INPUT. Who wrote a tenant's note is the actor, the way
      # `MishkaCmsCore.Runtime.PageBuilderEvent` records its author — and who wrote it decides whom
      # its mentions reach, so a caller that could name the author could name a master.
      change set_attribute(:author_id, actor(:id))

      # THE TWO THINGS A PARENT MUST BE, both learned from `MishkaBlog.Comment`: on the same
      # document — a reply that answers a note about another page is not an answer — and not this
      # note itself, which a form can be talked into by a stale id.
      validate {ParentBelongsToDocument, []}

      # THE NOTE'S OWN SITE, for everything it names: the document and the note it answers are that
      # site's or shared ones, and the author is that site's account or a master.
      validate {SameSiteReference,
                field: :document_id,
                resource: {:section, @documents},
                label: dgettext_noop("errors", "document"),
                shared?: true}

      validate {SameSiteReference,
                field: :parent_comment_id,
                resource: __MODULE__,
                label: dgettext_noop("errors", "note"),
                shared?: true}

      # The author is the actor, so an authorized write is judged by the policies first.
      validate {SameSiteReference,
                field: :author_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "author"),
                shared?: true,
                read_action: :related},
               before_action?: true

      # NAMING SOMEBODY IS HOW THEY FIND OUT. Here rather than in the panel because the panel is not
      # the only writer, and after the row exists because the notification links to it.
      change NotifyMentions

      description "Leaves a note on a document (tenant users); always stamped with their own site"
    end

    create :master_create do
      multitenancy :bypass

      validate present([:body, :type, :section])
      validate {TenantContext, require_master: true}

      # A master may leave a global note — but only about something that is itself global. Pages and
      # error pages belong to one site, so a note about one does too, even from a master.
      validate {SiteScopedDocument, sections: [:page, :error_page]}

      # THE TWO THINGS A PARENT MUST BE, both learned from `MishkaBlog.Comment`: on the same
      # document — a reply that answers a note about another page is not an answer — and not this
      # note itself, which a form can be talked into by a stale id.
      validate {ParentBelongsToDocument, []}

      validate {SameSiteReference,
                field: :document_id,
                resource: {:section, @documents},
                label: dgettext_noop("errors", "document"),
                shared?: true}

      validate {SameSiteReference,
                field: :parent_comment_id,
                resource: __MODULE__,
                label: dgettext_noop("errors", "note"),
                shared?: true}

      validate {SameSiteReference,
                field: :author_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "author"),
                shared?: true,
                read_action: :related}

      # NAMING SOMEBODY IS HOW THEY FIND OUT. Here rather than in the panel because the panel is not
      # the only writer, and after the row exists because the notification links to it.
      change NotifyMentions

      description "Leaves a note on a document (master users); a nil site_id is a global component"
    end

    # RESOLVING IS ITS OWN ACTION, not an update that happens to set three columns. Who resolved it
    # and when are recorded together or not at all, and nothing else about the note can change on
    # the way through.
    #
    # WHO RESOLVED IT IS WHOEVER DID: the resolver is set from the actor, never taken from input, the
    # way a note's author is. A resolve made as the system records no one.
    update :resolve do
      require_atomic? false
      accept []

      validate {TenantContext, require_master: false}
      validate GlobalRowIsMasterOnly

      change set_attribute(:status, :resolved)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:resolved_by_id, actor(:id))

      validate {SameSiteReference,
                field: :resolved_by_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "resolver"),
                shared?: true,
                read_action: :related},
               before_action?: true

      description "Marks a note handled, recording who did it"
    end

    update :master_resolve do
      require_atomic? false
      multitenancy :bypass
      accept []

      validate {TenantContext, require_master: true}

      change set_attribute(:status, :resolved)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:resolved_by_id, actor(:id))

      validate {SameSiteReference,
                field: :resolved_by_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "resolver"),
                shared?: true,
                read_action: :related},
               before_action?: true
    end

    # Reopening CLEARS the resolver rather than keeping it. "Resolved by X" on an open note reads as
    # a claim that is no longer true.
    update :reopen do
      require_atomic? false
      accept []

      validate {TenantContext, require_master: false}
      validate GlobalRowIsMasterOnly

      change set_attribute(:status, :open)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_by_id, nil)

      description "Puts a resolved note back on the pile"
    end

    update :master_reopen do
      require_atomic? false
      multitenancy :bypass
      accept []

      validate {TenantContext, require_master: true}

      change set_attribute(:status, :open)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_by_id, nil)
    end

    read :master_read do
      multitenancy :bypass
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {TenantContext, require_master: true}
    end

    read :get_any do
      get? true
      multitenancy :bypass
    end

    read :read_any do
      multitenancy :bypass

      pagination keyset?: true,
                 offset?: true,
                 default_limit: 100,
                 countable: true,
                 required?: false
    end

    # THE THREAD FOR ONE DOCUMENT. Everything the Review sheet shows comes through here, so the
    # scoping is in one place rather than repeated by each caller. `status` is an argument rather
    # than a filter the sheet applies afterwards, because the counter has to be able to ask the
    # database "how many open bugs" without loading the thread.
    read :for_editor do
      multitenancy :bypass

      argument :site_id, :uuid, allow_nil?: true
      argument :section, :atom, allow_nil?: false
      argument :document_id, :uuid, allow_nil?: true
      argument :status, :atom, allow_nil?: true

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      prepare fn query, _context ->
        query
        |> Ash.Query.filter(section == ^Ash.Query.get_argument(query, :section))
        |> scope_to_document(Ash.Query.get_argument(query, :document_id))
        |> scope_to_status(Ash.Query.get_argument(query, :status))
        # TOP-LEVEL NOTES ONLY. Replies are rendered under the note they answer, so returning them
        # here as well would show every one twice — once in its thread and once on its own, out of
        # context. It is also what makes "50 per page" mean fifty THREADS.
        |> Ash.Query.filter(is_nil(parent_comment_id))
        |> Ash.Query.sort(inserted_at: :desc)
      end

      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      validate {TenantContext, require_master: false}
      validate GlobalRowIsMasterOnly
    end

    destroy :master_destroy do
      require_atomic? false
      multitenancy :bypass

      validate {TenantContext, require_master: true}
    end
  end

  policies do
    # A REVIEW NOTE IS LEFT IN ONE BUILDER, so writing, reading, resolving and deleting one needs a
    # name that opens that builder (`MishkaCmsCore.Runtime.PageBuilder.Section`), the same as for a
    # snippet.
    policy action_type([:create, :read, :update, :destroy]) do
      authorize_if {MishkaCmsCore.Runtime.PageBuilder.BuilderAccess, field: :section}
    end

    # WHOSE ROWS A READ SHOWS, held to the actor when it runs, whichever read it is — `:read_any`,
    # `:get_any` and the shared-rows reads included: a master (`site_id` nil) reads any site's rows,
    # a site user its own site's and the shared ones, whatever it holds or passes as a tenant. See
    # `MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals` for the actor a shared-rows read
    # was built with. System reads pass `authorize?: false`.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(is_nil(site_id) or site_id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "page_comment"

    publish :create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :resolve, [[nil, :site_id], "resolved"]
    publish :master_resolve, [[nil, :site_id], "resolved"]
    publish :reopen, [[nil, :site_id], "reopened"]
    publish :master_reopen, [[nil, :site_id], "reopened"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :body, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 4000, trim?: true
      description "What the note says"
    end

    attribute :type, :atom do
      allow_nil? false
      default :information
      public? true
      constraints one_of: @types
      description "What kind of note it is — what the unresolved-bug counter reads"
    end

    attribute :status, :atom do
      allow_nil? false
      default :open
      public? true
      constraints one_of: [:open, :resolved]
      description "Whether it still needs attention"
    end

    attribute :author_type, :atom do
      allow_nil? false
      default :human
      public? true
      constraints one_of: [:human, :ai, :system]

      description "Who left it — `:ai` and `:system` have no user row, which is why author_id is nullable"
    end

    attribute :section, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:page, :layout, :error_page, :component]
      description "Which editor the note was left in"
    end

    attribute :document_id, :uuid do
      allow_nil? true
      public? true
      description "The page/layout/error page/component the note is about"
    end

    # NOT a uuid and NOT a foreign key. This is the editor's own `n<8>` handle, minted fresh by
    # every parse of the document, so it goes stale by design.
    attribute :node_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 40, trim?: true
      description "The element the note is on, or nil for a note on the whole page"
    end

    # THE ANCHOR THAT OUTLIVES A PARSE. `node_id` is minted fresh by every `Tree.parse/1`, so it means
    # nothing outside the session that wrote the note — a colleague with the same page open computes
    # a different id for the same element, and clicking the note's chip told them the element was
    # gone. This is the element's position in the document, which both of them derive from the same
    # shape: `Tree.address/2` writes it, `Tree.at_address/2` reads it back.
    attribute :node_path, :string do
      allow_nil? true
      public? true
      constraints max_length: 200, trim?: true
      description "Where that element sits in the document — the anchor that survives a re-parse"
    end

    attribute :node_label, :string do
      allow_nil? true
      public? true
      constraints max_length: 120, trim?: true

      description "What that element was called when the note was written — kept because the element can go"
    end

    attribute :resolved_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When it was marked handled"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site the document belongs to (nil for a note on a global component)"
    end

    belongs_to :author, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? true
      public? true
      domain MishkaCmsCore.Accounts
      description "The user who wrote it (null for an AI or system note)"
    end

    # THREADING, modelled on `MishkaBlog.Comment` — a nullable self-reference plus the reverse.
    # One level is what the sheet draws: a reply to a reply is a conversation that has outgrown a
    # 420px panel, and the blog does not render its own nesting either.
    belongs_to :parent_comment, MishkaCmsCore.Runtime.PageComment do
      allow_nil? true
      public? true
      description "The note this one answers, or nil for a note that starts a thread"
    end

    has_many :replies, MishkaCmsCore.Runtime.PageComment do
      public? true
      destination_attribute :parent_comment_id
      description "The answers to this note"
    end

    belongs_to :resolved_by, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? true
      public? true
      domain MishkaCmsCore.Accounts
      description "Whoever marked it handled — often not the person who raised it"
    end
  end

  calculations do
    calculate :author_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :author_id} do
      description "Whether the author is a master, for a reader who cannot load a master's account"
    end

    calculate :resolved_by_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :resolved_by_id} do
      description "Whether whoever resolved it is a master"
    end

    calculate :master_mentions,
              {:array, :string},
              fn notes, context ->
                MishkaCmsCore.Runtime.PageBuilder.Mentions.master_mentions(notes, context.actor)
              end do
      description "The handles in the body that name a master, for a site user reading it"
    end
  end

  @doc false
  @spec refuse(map()) :: String.t() | nil
  def refuse(params) do
    fields = Map.get(params, "form", params)

    cond do
      blank?(Map.get(fields, "body")) -> gettext("Write something first.")
      blank?(Map.get(fields, "type")) -> gettext("Pick what kind of note this is.")
      true -> plugin_refusal(fields)
    end
  end

  # A house rule an extension adds — a required label, a banned word, a note only a reviewer may
  # write — answers in the same shape the two rules above do, so it refuses through the same door.
  defp plugin_refusal(fields) do
    case MishkaCmsCore.Builder.Events.before_comment(%{
           body: Map.get(fields, "body"),
           type: Map.get(fields, "type"),
           section: Map.get(fields, "section"),
           node_id: Map.get(fields, "node_id"),
           parent_comment_id: Map.get(fields, "parent_comment_id")
         }) do
      {:error, message} -> message
      :ok -> nil
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value) when is_atom(value) and not is_nil(value), do: false
  defp blank?(_value), do: true

  @doc false
  @spec tell_editor(String.t()) :: :refused
  def tell_editor(message) do
    send(self(), {:review_error, message})
    :refused
  end

  @doc """
  Puts the editor's context onto the note the composer is about to save.

  The author never restates which document they are on, which element is selected, or who they are —
  the editor already knows all three, and asking would be a form with five fields where two will do.
  It rides in on the form's `defaults`, which is also what makes a page-level note simply a note
  with no `node_id`.

  `site_id`, `author_id` and `author_type` are written only for a master. A tenant's `:create` does
  not accept them: it takes `site_id` from the tenant and `author_id` from the actor.
  """
  @spec apply_scope(map(), map()) :: map()
  def apply_scope(%{"form" => fields} = params, state) when is_map(fields),
    do: Map.put(params, "form", scope_fields(fields, state))

  def apply_scope(params, state) when is_map(params), do: scope_fields(params, state)

  defp scope_fields(fields, state) do
    defaults = Map.get(state, :defaults) || %{}

    # `revision` and `editor_site_id` ride on `defaults` too. Gervaz merges every default into the
    # params after this hook, and no action takes either, so neither is saved.
    fields
    |> Map.put("section", to_string(Map.get(defaults, :section) || :page))
    |> Map.put("document_id", Map.get(defaults, :document_id))
    |> Map.put("node_id", Map.get(defaults, :node_id))
    |> Map.put("node_path", Map.get(defaults, :node_path))
    |> Map.put("node_label", Map.get(defaults, :node_label))
    |> Map.put("parent_comment_id", Map.get(defaults, :parent_comment_id))
    |> put_master_fields(defaults, state)
  end

  defp put_master_fields(fields, defaults, %{master_user?: true}) do
    fields
    |> Map.put("author_type", "human")
    |> Map.put("author_id", Map.get(defaults, :author_id))
    |> Map.put("site_id", Map.get(defaults, :editor_site_id))
  end

  defp put_master_fields(fields, _defaults, _state), do: fields

  @doc """
  Puts the editor's own scoping onto a `:for_editor` query, from the table's `path_params`.

  PREFIXED keys, for the reason `MishkaCmsCore.Runtime.Snippet` records: Gervaz turns any path param
  whose name matches an attribute into an equality filter, and `site_id == X` would drop exactly the
  global rows this read exists to include.
  """
  @spec for_editor_arguments(Ash.Query.t(), map()) :: Ash.Query.t()
  def for_editor_arguments(query, state) do
    params = Map.get(state, :path_params) || %{}

    query
    |> Ash.Query.set_argument(:site_id, Map.get(params, :editor_site_id))
    |> Ash.Query.set_argument(:section, Map.get(params, :editor_section) || :page)
    |> Ash.Query.set_argument(:document_id, Map.get(params, :editor_document_id))
    |> Ash.Query.set_argument(:status, Map.get(params, :editor_status))
    # THE BYLINE AND THE RESOLVER ARE RELATIONSHIPS. Without loading them the thread reads
    # "Someone" for every note, and `%Ash.NotLoaded{}` is truthy, so a template checking presence
    # would render the struct rather than fall back.
    |> Ash.Query.load(@byline ++ [replies: @byline])
  end

  # A note always belongs to a document. Without one there is nothing to show, and returning every
  # document's notes would be worse than returning none.
  defp scope_to_document(query, nil), do: Ash.Query.filter(query, is_nil(document_id))

  defp scope_to_document(query, document_id),
    do: Ash.Query.filter(query, document_id == ^document_id)

  defp scope_to_status(query, nil), do: query
  defp scope_to_status(query, status), do: Ash.Query.filter(query, status == ^status)
end
