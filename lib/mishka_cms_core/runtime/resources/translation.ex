defmodule MishkaCmsCore.Runtime.Translation do
  @moduledoc """
  A word a runtime template asks for with `t/1`, in one language, for one site.

  A component, a page or a layout written in the builder is a database row compiled at runtime, so
  the build-time Gettext pipeline cannot reach it: `mix gettext.extract` reads files, and a `.po`
  only takes effect in a rebuilt backend. This is the runtime counterpart — a row per
  `{site, key, language}`, cached in ETS by `MishkaCmsCore.Runtime.States.TranslationsState`, read by
  `MishkaCmsCore.Runtime.Translations.translate/2` and edited in the admin with no deploy.

  ## Stored per language, listed per key

  A row is one key in one language, edited with a plain form. `value` is `nil` until somebody writes
  it, and `t/1` renders the key itself until then — the key is the source text, so an untranslated
  word reads as English, never blank.

  The admin list shows one row per key, the way the page list shows one per page: a chip per
  language, translated or missing, and a modal with every language to fill in. Searching or
  filtering by language still lists a word once — see `Translations.one_row_per_key/2`.

  ## Multitenant like `MishkaCmsCore.Runtime.Setting`

  `global? true`: a row with `site_id` nil is a translation every site gets, a row with a `site_id`
  is that site's own and wins over the global one. A site admin reads their own rows and the global
  ones, and writes only their own.

  ## Where rows come from

  `MishkaCmsCore.Runtime.Resources.Changes.RegisterTranslationKeys` registers the keys a template
  asks for whenever a component, page or layout is saved, one row per language the site publishes
  in. `:register` never touches a value, so saving a template again cannot erase a translation.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    extensions: [MishkaGervaz.Resource, GuardedStruct.AshResource]

  import Phoenix.Component, only: [sigil_H: 2]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  require Ash.Query

  postgres do
    table "cms_translations"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # NO INDEX OF ITS OWN. `:unique_translation` is `(site_id, key, language)`, and a btree answers
    # any leading prefix of itself — `site_id`, and `site_id` with `key`, which is every query the
    # sheet and the admin make. A second index would be one more write on every save.
  end

  mishka_gervaz do
    table do
      identity do
        name :translations
        route "/admin/dashboard/runtime/translations"
        stream_name :translations
      end

      source do
        # `:used` IS LOADED HERE, NOT BY THE COLUMN. A column's `requires` copies a field off the row
        # it was handed; it loads nothing. Left out, the calculation arrives as `%Ash.NotLoaded{}` —
        # which is truthy, so every row read "In use" and nothing Remove unused would delete showed.
        preload do
          always [:site, :used, :languages]
        end

        actions do
          read {:master_read, :tenant_read}
          get {:master_get, :tenant_get}
          destroy {:master_destroy, :destroy}
        end
      end

      columns do
        default_sort [{:key, :asc}]

        column :key do
          static true
          requires [:key]
          label fn -> dgettext("mishka_gervaz", "Key") end
          position :first
          sortable true
          sort_field [:key]

          ui do
            width "minmax(200px,1.4fr)"
          end

          render fn record ->
            assigns = %{key: record.key}

            ~H"""
            <span
              class="block truncate font-['Space_Grotesk'] text-[13px] font-bold text-[#4f4bcc]"
              title={@key}
            >
              {@key}
            </span>
            """
          end
        end

        # A CHIP PER LANGUAGE, the page list's colours: filled once translated, dashed while missing.
        # Past two they fold behind Gervaz's `+N`, which opens in place — the `:tags` default.
        column :languages do
          static true
          requires [:id, :languages]
          label fn -> dgettext("mishka_gervaz", "Languages") end

          ui do
            width "minmax(220px,1.6fr)"
          end

          # THE TABLE'S ID IN THE CHIPS' ID: the admin list and its Remove-unused list can draw the
          # same row at once, and two elements sharing an id is one the DOM cannot patch.
          render fn record, state ->
            chips =
              Enum.map(record.languages, fn %{language: language, translated?: done?} ->
                code = String.upcase(language)

                %{
                  label: code,
                  class:
                    "inline-flex items-center rounded-[20px] border px-2 py-[3px] font-['Space_Grotesk'] text-[10px] font-bold " <>
                      if(done?,
                        do: MishkaCmsCore.LanguageAccent.for_language(language).chip,
                        else: "border-dashed border-[#e6c9a3] bg-white text-[#b8741a]"
                      ),
                  title:
                    if(done?,
                      do: dgettext("mishka_gervaz", "%{code} — translated", code: code),
                      else: dgettext("mishka_gervaz", "%{code} — missing", code: code)
                    )
                }
              end)

            {shown, rest} = Enum.split(chips, 2)

            assigns = %{
              tags: %{
                __changed__: %{},
                id: "#{state.static.id}-languages-#{record.id}",
                shown: shown,
                rest: rest,
                more: length(rest),
                badge_class: nil,
                empty: nil
              }
            }

            ~H"""
            {MishkaGervaz.UIAdapters.Tailwind.cell_tags(@tags)}
            """
          end
        end

        # NOT IN THE EDITOR'S SHEET. Scoped to one document's keys, every word listed is one that
        # document asks for — typed a moment ago included, which no saved template holds yet, so
        # the column would call it Unused.
        column :used do
          static true
          requires [:used]
          label fn -> dgettext("mishka_gervaz", "Used") end
          visible fn state -> not Map.has_key?(state.path_params || %{}, :key) end

          ui do
            width "minmax(90px,0.5fr)"
          end

          render fn record ->
            assigns = %{used: record.used}

            ~H"""
            <span
              :if={@used}
              class="rounded-full bg-[#eaf6ee] px-2 py-[2px] text-[11px] font-semibold text-[#177a53]"
            >
              {dgettext("mishka_gervaz", "In use")}
            </span>
            <span
              :if={!@used}
              title={dgettext("mishka_gervaz", "No template asks for this key any more")}
              class="rounded-full bg-[#f2f1ec] px-2 py-[2px] text-[11px] font-semibold text-[#8a877f]"
            >
              {dgettext("mishka_gervaz", "Unused")}
            </span>
            """
          end
        end

        column :site_info do
          static true
          requires [:site_id, :site]
          label fn -> dgettext("mishka_gervaz", "Site") end
          position :last

          ui do
            width "minmax(150px,1.2fr)"
          end

          render fn record ->
            assigns = %{global?: is_nil(record.site_id), name: record.site && record.site.name}

            ~H"""
            <MishkaCmsCore.CoreComponents.site_cell global?={@global?} name={@name} />
            """
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:key, :value]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        # A MASTER'S, AS ON THE OTHER RUNTIME LISTS. A site admin reads their own site and the global
        # rows only, so there is nothing for them to pick. Every row of a word shares its site, so
        # narrowing by site keeps the same row standing for the word.
        filter :site_id, :relation do
          mode :search_multi
          display_field :name
          search_field :name
          min_chars 1
          page_size 15
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            placeholder fn -> dgettext("mishka_gervaz", "Search sites...") end
          end
        end

        # SEARCHABLE, AND MORE THAN ONE AT A TIME. A `:relation` filter serving its own list rather
        # than a resource's — the languages live in each site's settings, not in a table.
        filter :language, :relation do
          mode :search_multi
          min_chars 1
          options fn -> Translations.language_options() end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language") end
            prompt dgettext_noop("mishka_gervaz", "Any language")
            placeholder fn -> dgettext("mishka_gervaz", "Search languages…") end
          end
        end

        # The global rows have no site to pick, so they get a switch of their own.
        filter :global_only, :boolean do
          virtual true
          restricted true

          apply fn query, value, _assigns ->
            if value do
              Ash.Query.filter(query, is_nil(site_id))
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Global Only") end
          end
        end
      end

      row_actions do
        action :edit do
          type :event
          event "edit_translation"

          ui do
            label fn -> dgettext("mishka_gervaz", "Translate") end
            icon "hero-language"
          end
        end

        # A ROW IS A KEY, so Delete is the key in every language — `Translations.delete_key/2`. One
        # language alone is not deleted: a template asking for it would register it again, and
        # emptying its value is what shows the key instead.
        action :delete do
          type :event
          event "delete_translation_key"

          confirm fn _record ->
            dgettext(
              "mishka_gervaz",
              "Delete this word in every language? This cannot be undone."
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end
      end

      pagination do
        type :numbered
        page_size 50
        page_size_options [20, 50, 100]
      end

      realtime do
        prefix "translation"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :page_size, :search]
        prefix "translations"
      end

      empty_state message:
                    dgettext_noop(
                      "mishka_gervaz",
                      "No translations yet — write t(\"…\") in a template and save it."
                    ),
                  icon: "hero-language"

      hooks do
        on_load fn query, state -> {:cont, Translations.one_row_per_key(query, state)} end
        on_realtime fn notification, socket -> Translations.on_realtime(notification, socket) end
      end
    end

    form do
      identity do
        name :translation_form
      end

      source do
        actions do
          create {:master_create, :create}
          update {:master_update, :update}
          read {:master_get, :tenant_get}
        end
      end

      fields do
        # THE KEY AND THE LANGUAGE ARE WHICH ROW THIS IS. Changing either would be writing a different
        # translation over this one, so after create only the value is offered — the update actions
        # accept nothing else.
        field :key do
          required true
          visible fn state -> state.mode == :create end

          ui do
            label fn -> dgettext("mishka_gervaz", "Key") end
            placeholder fn -> dgettext("mishka_gervaz", "The exact text inside t(\"…\")") end
          end
        end

        # THE CHOSEN SITE'S LANGUAGES, NOTHING ELSE — Global's being every site's. A relation with no
        # resource, so its options are read from the form's state each time they load, a change of
        # site included; `published_language/2` still refuses anything else on save.
        field :language, :relation do
          required true
          visible fn state -> state.mode == :create end
          depends_on :site_id
          mode :search
          min_chars 1
          options fn state -> Translations.language_options_for(state) end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language") end
            placeholder "en, fa, ar, …"
            disabled_prompt fn -> dgettext("mishka_gervaz", "Pick a site first") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Only a language listed under Settings → Languages can be saved — the site's own list, or any site's for a global row: a page in any other language answers 404, so its translation would never show."
              )
            end
          end
        end

        field :value, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Translation") end
            placeholder fn -> dgettext("mishka_gervaz", "Leave empty to show the key itself") end
          end
        end

        field :site_id, :relation do
          restricted true
          visible fn state -> state.mode == :create end
          display_field :name
          search_field :name
          mode :search
          min_chars 1
          include_nil fn -> dgettext("mishka_gervaz", "Global (no site)") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            placeholder fn -> dgettext("mishka_gervaz", "Leave empty for every site") end
          end
        end
      end

      groups do
        group :main_fields do
          fields [:site_id, :key, :language, :value]

          ui do
            columns 1
            class ""
          end
        end
      end

      presentation do
        features :all
      end

      # WITHOUT IT A CANCEL NEVER LEAVES THE FORM. Gervaz sends `{:form_cancelled, resource}` to the
      # page only when this hook exists, so both the admin page and the editor's sheet would keep the
      # form open — and reset it to an empty create.
      hooks do
        on_cancel fn state -> state end
      end
    end
  end

  # THE KEY IS NEVER SANITIZED. It is matched byte for byte against the literal inside `t("…")`, and a
  # stored key that differed by one stripped character would never be asked for again.
  #
  # THE VALUE LOSES CONTROL CHARACTERS AND NOTHING ELSE. `no_zero_width` is deliberately absent: its
  # class `\x{200B}-\x{200D}` includes U+200C, the zero-width non-joiner Persian spells with, and it
  # would turn `قیمت‌گذاری` into a different word without a sound.
  guardedstruct do
    auto_wire true

    field :key, :string, derives: "validate(string, not_empty, max_len=500)"

    field :language, :string,
      derives:
        ~S|sanitize(trim, downcase) validate(string, not_empty, max_len=20, regex=^[a-z]{2,3}(-[a-z0-9]{2,8})*$)|

    field :value, :string,
      derives: "sanitize(no_control) validate(optional=[string, max_len=5000])"
  end

  actions do
    defaults [:read]

    # The cache's own read, and nobody else's — see the `:register`/`:read_any` policy below.
    # KEYSET, because the whole table is walked through it — the cache load, and `purge_unused/2`
    # streaming every row in scope. Offset pages can skip or repeat a row that moves while they are
    # read; a keyset cursor cannot.
    read :read_any do
      multitenancy :bypass
      pagination keyset?: true, offset?: true, required?: false
      description "Every translation in the system, for loading the ETS cache."
    end

    read :master_read do
      multitenancy :bypass
      validate {TenantContext, require_master: true}
      pagination offset?: true, countable: true, required?: false
      description "Every translation, every site (master only)."
    end

    read :tenant_read do
      multitenancy :bypass
      validate {TenantContext, require_master: false}
      pagination offset?: true, countable: true, required?: false

      prepare fn query, context ->
        Ash.Query.filter(query, site_id == ^context.tenant or is_nil(site_id))
      end

      description "A site's own translations and the global ones."
    end

    read :master_get do
      get? true
      multitenancy :bypass
      validate {TenantContext, require_master: true}
    end

    read :tenant_get do
      get? true
      multitenancy :bypass
      validate {TenantContext, require_master: false}

      prepare fn query, context ->
        Ash.Query.filter(query, site_id == ^context.tenant or is_nil(site_id))
      end
    end

    # WHAT A SAVED TEMPLATE REGISTERS. Upserting with nothing to overwrite: a key that already has a
    # row keeps it exactly, value included, so saving a template again can never erase a
    # translation somebody wrote.
    create :register do
      multitenancy :bypass
      accept [:key, :language, :site_id]

      upsert? true
      upsert_identity :unique_translation
      upsert_fields []
    end

    create :create do
      accept [:key, :language, :value]

      validate {TenantContext, require_master: false}
      validate &Translations.published_language/2

      change fn changeset, context ->
        Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant)
      end
    end

    create :master_create do
      multitenancy :bypass
      accept [:key, :language, :value, :site_id]

      validate {TenantContext, require_master: true}
      validate &Translations.published_language/2
    end

    update :update do
      accept [:value]
      validate {TenantContext, require_master: false}
    end

    update :master_update do
      multitenancy :bypass
      accept [:value]
      validate {TenantContext, require_master: true}
    end

    destroy :destroy do
      primary? true
      validate {TenantContext, require_master: false}
    end

    destroy :master_destroy do
      multitenancy :bypass
      validate {TenantContext, require_master: true}
    end
  end

  policies do
    # REACHED ONLY WITH `authorize?: false`. The cache loads through `:read_any` and a saved template
    # registers through `:register`; neither is anything an actor should be able to call, so an
    # actor is refused outright rather than trusted to be the system.
    policy action([:read_any, :register]) do
      forbid_if always()
    end

    # TRANSLATIONS ARE CONTENT: anyone under the request's surface reads them — the builder's
    # translation sheet included — and writing them takes the translation section,
    # `admin:<surface>:runtime:translation`.
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if {AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:translation",
                      "admin:api:runtime:translation"
                    ]}

      forbid_unless action_type(:read)
      authorize_if {AccessPermissions, under: :surface}
    end

    # A SITE ADMIN SEES THEIR OWN ROWS AND THE GLOBAL ONES, decided from the ACTOR, row by row. A
    # site admin naming another site's tenant is refused before this (`TenantContext` asks the actor
    # an input is built with, `AccessPermissions` the actor it runs with); this holds the rows
    # themselves to the actor's site, whatever tenant the read carries. As an `expr`, Ash applies this
    # as a filter on the query rather than refusing the whole read — the editor's sheet leans on it,
    # scoping by key alone and letting this decide which sites' rows come back.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(is_nil(site_id) or site_id == ^actor(:site_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    policy action([:master_read, :master_get, :master_create, :master_update, :master_destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "translation"

    publish_all :create, [[nil, :site_id], "updated"]
    publish_all :update, [[nil, :site_id], "updated"]
    publish_all :destroy, [[nil, :site_id], "destroyed"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: false
      description "The text a template passes to t/1 — also what renders while untranslated."
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      constraints min_length: 2, max_length: 20
      description "A language code the site publishes in."
    end

    attribute :value, :string do
      allow_nil? true
      public? true
      constraints max_length: 5000
      description "The translation. nil until written; t/1 renders the key meanwhile."
    end

    create_timestamp :created_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
    end
  end

  calculations do
    # WHETHER ANY TEMPLATE STILL ASKS FOR THIS KEY. Computed for the whole page of rows at once — the
    # keys a site uses are read once per site on the page, not once per row — and never stored, so
    # it cannot drift from what the templates actually say. See `Translations.used_keys/1`.
    # EVERY LANGUAGE OF THE KEY, for the list's chips — one query for the page, not one per row.
    calculate :languages, {:array, :map}, fn records, _context ->
      Translations.language_states(records)
    end

    calculate :used, :boolean, fn records, _context ->
      used =
        records
        |> Enum.map(& &1.site_id)
        |> Enum.uniq()
        |> Map.new(&{&1, Translations.used_keys(&1)})

      Enum.map(records, &MapSet.member?(Map.fetch!(used, &1.site_id), &1.key))
    end
  end

  identities do
    identity :unique_translation, [:key, :language, :site_id], nils_distinct?: false
  end
end
