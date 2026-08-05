defmodule MishkaCmsCore.Runtime.Snippet do
  @moduledoc """
  A named piece of markup an author saved out of the visual editor to reuse somewhere else.

  A snippet is the editor's own clipboard made durable: `source` is the same HEEx the canvas
  serialises, so inserting one is the same operation as inserting a palette example — parse, place,
  done. Nothing about it is kit-specific, which is why it lives here rather than under the UI-kit
  handler.

  Two things scope it:

    * `scope` — `:page` keeps it beside the document it was saved from (`document_id`), `:shared`
      offers it anywhere on the site. The Studio's chips are exactly these two plus "all".
    * `section` — which editor it came from (`page`, `layout`, `error_page`, `component`). A layout's
      header markup is rarely what an error page wants, and offering it there is noise.

  Multitenancy is `global? true`, matching `MishkaCmsCore.Runtime.Layout`: a row with a `nil`
  `site_id` is a snippet every site can insert, which only a master user can create.

  Blocks, byte size and the swatch tint are NOT stored — they are read off `source` by
  `MishkaCmsCore.Runtime.PageBuilder.Snippets`, so they cannot drift from the markup they describe.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  alias MishkaCmsCore.Runtime.Resources.Validations.{SameSiteReference, TenantContext}

  require Ash.Query

  postgres do
    table "builder_snippets"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    custom_indexes do
      index [:site_id]
      index [:section]
      index [:document_id]
    end

    check_constraints do
      check_constraint :name, "snippet_name_length_check",
        check: "length(name) >= 2 AND length(name) <= 120",
        message: dgettext_noop("errors", "Name must be between 2 and 120 characters.")

      check_constraint :source, "snippet_source_length_check",
        check: "length(source) >= 1",
        message: dgettext_noop("errors", "A snippet needs some markup to save.")
    end
  end

  @editable_fields [:name, :source, :section, :scope, :document_id]

  @documents %{
    page: MishkaCmsCore.Runtime.Page,
    layout: MishkaCmsCore.Runtime.Layout,
    error_page: MishkaCmsCore.Runtime.ErrorPage,
    component: MishkaCmsCore.Runtime.Component
  }
  @admin_fields @editable_fields ++ [:site_id]

  mishka_gervaz do
    table do
      identity do
        name :studio_snippets
        route "/admin/dashboard/runtime/builder"
        stream_name :studio_snippets
      end

      # `:for_editor` and nothing else. It is the only read that answers "this site's plus the
      # global ones, for THIS editor, beside THIS document" — see
      # `MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals` and `scope_to_document/2`
      # below. `:read` enforces multitenancy and would hide every global row; `:read_any` bypasses
      # it with no scoping at all.
      source do
        actions do
          read :for_editor
          get {:get_any, :read}
        end
      end

      pagination do
        type :load_more
        page_size 30

        # The design shows no total, and a total is a second query.
        ui do
          show_total false
        end
      end

      columns do
        column :name do
          label fn -> dgettext("mishka_gervaz", "Name") end
        end
      end

      # The Studio's chips. "This page" and "Shared" are the stored `scope`; "All" is this filter
      # unset, which is why the All chip pushes an empty value rather than a third option.
      filters do
        filter :scope, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "This page"), "page"},
              {dgettext("mishka_gervaz", "Shared"), "shared"}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Scope") end
          end
        end
      end

      # A snippet changes when someone in THIS editor saves or deletes one, and that path already
      # reloads the table by bumping its revision. Subscribing would hand the broadcast to
      # `BuilderLive`, whose catch-all `handle_info/2` drops it.
      realtime do
        enabled false
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No snippets saved yet"),
                  icon: "hero-square-2-stack"

      hooks do
        # `:for_editor` takes three Ash arguments and Gervaz has no DSL for them —
        # `PaginationHandler.load_page/5` calls `Ash.Query.for_read(action, %{})` with an empty map.
        # An argument set on the query BEFORE that call survives it, so this hook is the channel.
        on_load fn query, state ->
          {:cont, for_editor_arguments(query, state)}
        end
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.StudioSnippets
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        # Saving or deleting reloads this table at whatever depth the reader had reached. Without
        # this the reload re-reads only page N — `reset_stream?(:load_more, N)` is false past the
        # first page — so a deleted row stayed on screen and a new one, which sorts first, never
        # appeared until the sheet was closed and reopened.
        keep_loaded_records true
      end
    end

    # The Studio's "Save as snippet" box. `name` is the only value the author types; everything else
    # the snippet needs — the markup, which editor it came from, which document, who it is for — is
    # settled by `apply_visibility/2` at submit time.
    form do
      identity do
        name :studio_snippet
        route "/admin/dashboard/runtime/builder"
      end

      source do
        actions do
          create {:master_create, :create}
          read {:get_any, :read}
        end
      end

      fields do
        field :name, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end
      end

      events do
        submit MishkaCmsCoreWeb.Forms.SnippetSubmit
      end

      hooks do
        # Two failures are the author's rather than the database's, and both have had their own
        # wording in this panel since it shipped: a snippet with no name is unfindable, and markup
        # that does not parse cannot be inserted. Halting here keeps those sentences, and keeps a
        # row that could never be used out of the table.
        before_save fn params, state ->
          case refuse(params) do
            nil -> {:cont, apply_visibility(params, state)}
            message -> {:halt, tell_editor(message)}
          end
        end
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.SnippetForm
      end
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @editable_fields

      validate present([:name, :source, :section])
      validate {TenantContext, require_master: false}

      # The document it was saved from is the snippet's own site's or a shared one.
      validate {SameSiteReference,
                field: :document_id,
                resource: {:section, @documents},
                label: dgettext_noop("errors", "document"),
                shared?: true}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "Saves a snippet for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      multitenancy :bypass

      validate present([:name, :source, :section])
      validate {TenantContext, require_master: true}

      # A snippet every site can insert names only a shared document.
      validate {SameSiteReference,
                field: :document_id,
                resource: {:section, @documents},
                label: dgettext_noop("errors", "document"),
                shared?: true}

      description "Saves a snippet for master users - a nil site_id makes it available to every site"
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name]

      validate {TenantContext, require_master: false}

      description "Renames a snippet (tenant users)"
    end

    update :master_update do
      require_atomic? false
      multitenancy :bypass
      accept [:name]

      validate {TenantContext, require_master: true}

      description "Renames a snippet (master users)"
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

    # NOT a TODO — the same reasoning recorded on the other runtime resources applies: this action is
    # not routed through JSON:API, no relationship reaches it from an includable resource, and its
    # in-app callers already resolved the site. The missing `require_master` is defence-in-depth.
    read :read_any do
      multitenancy :bypass

      pagination keyset?: true,
                 offset?: true,
                 default_limit: 100,
                 countable: true,
                 required?: false
    end

    # What the Studio's snippet list actually reads: this site's snippets plus the global ones,
    # narrowed to the editor asking and to the document it has open. A `:page` snippet belongs beside
    # the document it came out of; offering it on every other page is how a snippet list becomes
    # unusable after a month.
    read :for_editor do
      multitenancy :bypass

      argument :site_id, :uuid, allow_nil?: true
      argument :section, :atom, allow_nil?: false
      argument :document_id, :uuid, allow_nil?: true

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      prepare fn query, _context ->
        section = Ash.Query.get_argument(query, :section)
        document_id = Ash.Query.get_argument(query, :document_id)

        query
        |> Ash.Query.filter(section == ^section)
        |> scope_to_document(document_id)
        |> Ash.Query.sort(inserted_at: :desc)
      end

      pagination offset?: true, default_limit: 100, max_page_size: 200, countable: true
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      validate {TenantContext, require_master: false}
    end

    destroy :master_destroy do
      require_atomic? false
      multitenancy :bypass

      validate {TenantContext, require_master: true}
    end
  end

  policies do
    # A SNIPPET BELONGS TO THE BUILDER IT WAS SAVED FROM, so saving, listing, renaming and deleting
    # one needs a name that opens that builder (`MishkaCmsCore.Runtime.PageBuilder.Section`).
    # Someone who cannot open the editor has no business writing markup into it.
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
    prefix "snippet"

    publish :create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :master_update, [[nil, :site_id], "updated"]
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

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 2, max_length: 120, trim?: true
      description "What the author called it in the Studio"
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: false
      description "The HEEx the editor serialised — inserted verbatim"
    end

    attribute :section, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:page, :layout, :error_page, :component]
      description "Which editor this was saved from, and which one offers it back"
    end

    attribute :scope, :atom do
      default :shared
      public? true
      constraints one_of: [:page, :shared]
      description "`:page` keeps it beside its own document; `:shared` offers it site-wide"
    end

    attribute :document_id, :uuid do
      allow_nil? true
      public? true

      description "The page/layout/error page it was saved from — set for `:page` scope, and kept for provenance otherwise"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site this snippet belongs to (nil for a snippet every site can insert)"
    end
  end

  identities do
    identity :unique_name_per_scope, [:name, :site_id, :section, :document_id] do
      description "One name per document per editor, so saving twice renames rather than duplicates"
      message dgettext_noop("errors", "A snippet with that name is already saved here.")
      all_tenants? true
      nils_distinct? false
    end
  end

  @doc false
  @spec refuse(map()) :: String.t() | nil
  def refuse(params) do
    fields = Map.get(params, "form", params)

    cond do
      blank?(Map.get(fields, "name")) ->
        gettext("Give the snippet a name first.")

      blank?(Map.get(fields, "source")) ->
        gettext("There is nothing on the canvas to save.")

      !parses?(Map.get(fields, "source")) ->
        gettext("That markup does not parse, so it could not be saved.")

      true ->
        nil
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp parses?(source) do
    case MishkaCmsCore.Runtime.PageBuilder.Tree.parse(String.trim(source)) do
      {:ok, %{roots: [_first | _rest]}} -> true
      _other -> false
    end
  end

  # The form has no error slot — every snippet failure in this panel has always been a flash — and a
  # LiveComponent runs inside its parent, so `self()` is the LiveView that owns it.
  defp tell_editor(message) do
    send(self(), {:snippet_error, message})
    :refused
  end

  @doc """
  Turns the save box's `visibility` choice into the attributes the create action actually stores.

  The radio posts one of `"page"`, `"shared"` or `"global"` because "All sites" is a `site_id`
  decision while the other two are `scope` decisions — one control, two columns. The editor's own
  context (which section, which document, which site) rides in on the form's `defaults`, so the
  author never has to restate what the editor already knows.

  `site_id` is written only for a master. A tenant's `:create` action does not accept it — it forces
  the value from the tenant — and Ash rejects an input an action does not accept, so sending it
  would turn every tenant save into an error.
  """
  @spec apply_visibility(map(), map()) :: map()
  def apply_visibility(%{"form" => fields} = params, state) when is_map(fields),
    do: Map.put(params, "form", visibility_fields(fields, state))

  def apply_visibility(params, state) when is_map(params), do: visibility_fields(params, state)

  defp visibility_fields(fields, state) do
    defaults = Map.get(state, :defaults) || %{}
    visibility = Map.get(fields, "visibility")

    fields
    |> Map.drop(["visibility"])
    |> Map.put("scope", scope_for(visibility))
    |> Map.put("section", to_string(Map.get(defaults, :section) || :page))
    |> Map.put("document_id", Map.get(defaults, :editor_document_id))
    |> put_site_id(visibility, defaults, state)
  end

  defp scope_for("page"), do: "page"
  defp scope_for(_visibility), do: "shared"

  defp put_site_id(fields, visibility, defaults, %{master_user?: true}) do
    site_id = master_site_id(visibility, defaults)

    fields
    |> Map.put("site_id", site_id)
    |> document_of_site(site_id, Map.get(defaults, :editor_site_id))
  end

  defp put_site_id(fields, _visibility, _defaults, _state), do: fields

  # A snippet for every site keeps no site's document: saved from a site's page it is shared
  # markup, not that page's.
  defp document_of_site(fields, nil, editor_site_id) when not is_nil(editor_site_id),
    do: Map.put(fields, "document_id", nil)

  defp document_of_site(fields, _site_id, _editor_site_id), do: fields

  defp master_site_id("global", _defaults), do: nil
  defp master_site_id(_visibility, defaults), do: Map.get(defaults, :editor_site_id)

  @doc """
  Puts the editor's own scoping onto a `:for_editor` query, from the table's `path_params`.

  The keys are PREFIXED — `:editor_site_id`, not `:site_id`. Gervaz turns any path param whose name
  matches an attribute into an equality filter, and `site_id == X` would drop exactly the global
  rows (`site_id` nil) this read exists to include.
  """
  @spec for_editor_arguments(Ash.Query.t(), map()) :: Ash.Query.t()
  def for_editor_arguments(query, state) do
    params = Map.get(state, :path_params) || %{}

    query
    |> Ash.Query.set_argument(:site_id, Map.get(params, :editor_site_id))
    |> Ash.Query.set_argument(:section, Map.get(params, :editor_section) || :page)
    |> Ash.Query.set_argument(:document_id, Map.get(params, :editor_document_id))
  end

  # Without a document there is nothing for a `:page` snippet to sit beside, so only the shared ones
  # can be offered.
  defp scope_to_document(query, nil), do: Ash.Query.filter(query, scope == :shared)

  defp scope_to_document(query, document_id),
    do: Ash.Query.filter(query, scope == :shared or document_id == ^document_id)
end
