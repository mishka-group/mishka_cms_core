defmodule MishkaCmsCore.Runtime.Media do
  @moduledoc """
  Manages media files (images, videos, documents) in the MishkaCMS runtime system with full versioning support.

  This resource represents media files that can be uploaded and managed within the CMS.
  Each media file belongs to a specific site and can be categorized. The resource supports
  various media types including images, videos, and documents with metadata tracking
  such as dimensions, file format, size, and featured status.

  Media files feature full version control through PaperTrail integration, tracking all changes
  with snapshot-based history and the ability to restore previous versions. The resource
  implements soft deletion via archival and provides comprehensive metadata management
  including dimensions, file type, format, and categorization.

  Database-level constraints ensure data integrity with name validation, size checks,
  and prevention of modifications to archived media. Multi-tenant isolation ensures
  media files are properly segregated between sites. The resource provides extensive API actions
  for external integrations and maintains complete audit trails of all modifications including
  actor tracking and action recording.

  The admin table's preview cell paints a type glyph behind the thumbnail and names the admin
  bundle's `MediaThumb` hook, which hides an image whose file has gone so the glyph is what you see.
  The `onerror=` attribute that used to do it is refused by an enforced Content-Security-Policy,
  which has no nonce or hash for an event handler. See `MishkaGervaz.Table.Templates.MediaGallery`.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshSlug,
      AshPaperTrail.Resource,
      AshJsonApi.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  @type_badge %{
    colors: %{
      "videos" => "bg-[#f1edfb] text-[#7a5bd0]",
      "images" => "bg-[#eaf1fb] text-[#3a6cb5]",
      "documents" => "bg-[#eaf6ee] text-[#177a53]"
    },
    labels: %{
      "videos" => dgettext_noop("mishka_gervaz", "Video"),
      "images" => dgettext_noop("mishka_gervaz", "Image"),
      "documents" => dgettext_noop("mishka_gervaz", "Document")
    },
    default_color: "bg-[#f2f1ec] text-[#8a877f]"
  }

  @admin_fields [
    :name,
    :type,
    :size,
    :format,
    :featured,
    :dimensions,
    :relative_path,
    :description,
    :site_id,
    :media_category_id
  ]

  # WHERE THE FILE LIVES IS THE SERVER'S TO SAY. `relative_path` is written by an upload, into the
  # site's own folder, and every storage function below moves, reads or deletes the file it names —
  # so an edit may not repoint it, at another site's file or out of the folder with `..`. An edit
  # also never moves a row to another site. A create takes it from the server alone too, as the
  # private argument `stored_path` (see `:create`).
  @editable_fields @admin_fields -- [:site_id, :relative_path]

  postgres do
    table "media"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:type]
      index [:format]
      index [:featured]
    end

    check_constraints do
      check_constraint :name, "name_length_check",
        check: "length(name) >= 1 AND length(name) <= 255",
        message: dgettext_noop("errors", "Name must be between 1 and 255 characters.")

      check_constraint :size, "size_positive_check",
        check: "size > 0",
        message: dgettext_noop("errors", "Size must be greater than 0.")

      check_constraint :name, "no_empty_name",
        check: "name != ''",
        message: dgettext_noop("errors", "Name cannot be empty.")
    end

    custom_statements do
      statement :prevent_archived_media_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_media_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived media'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_media_updates();"
      end

      statement :prevent_archived_media_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_media_updates_trigger
          BEFORE UPDATE ON media
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_media_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_media_updates_trigger ON media;"
      end
    end
  end

  archive do
    exclude_read_actions [
      :archived,
      :get_archived,
      :master_get_archived,
      :master_get,
      :master_archived
    ]

    exclude_destroy_actions [:permanent_destroy, :master_permanent_destroy]
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :snapshot
    store_action_name? true
    store_action_inputs? true
    ignore_attributes [:inserted_at, :updated_at, :archived_at]
    ignore_actions [:unarchive, :master_unarchive, :permanent_destroy, :master_permanent_destroy]
    attributes_as_attributes [:site_id]
    create_version_on_destroy? true
    only_when_changed? true
    relationship_opts public?: true

    belongs_to_actor :user, MishkaCmsCore.Accounts.User, domain: MishkaCmsCore.Accounts

    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.MediaPaperTrailMixin, :postgres, []}
  end

  json_api do
    type "media"
  end

  mishka_gervaz do
    table do
      identity do
        name :media
        route "/admin/media"
        stream_name :media
      end

      source do
        preload do
          tenant [:media_category]
          master master_media_category: :media_category
        end
      end

      presentation do
        template MishkaGervaz.Table.Templates.MediaGallery

        switchable_templates [
          MishkaGervaz.Table.Templates.MediaGallery,
          MishkaGervaz.Table.Templates.Table
        ]

        template_options columns: 3
      end

      columns do
        column :relative_path do
          static true
          requires [:relative_path, :site_id, :archived_at, :type, :format]
          sortable false
          label fn -> dgettext("mishka_gervaz", "Image") end
          visible fn state -> state.template.name() == :media_gallery end

          render fn record ->
            relative_path = record[:relative_path]
            archived_at = record[:archived_at]
            is_image = record[:type] == :images

            cond do
              is_nil(archived_at) ->
                relative_path

              archived_at && is_image ->
                MishkaCmsCore.Runtime.Media.get_archived_image_data_uri(
                  relative_path,
                  record[:site_id],
                  record[:format]
                ) || relative_path

              true ->
                nil
            end
          end

          ui do
            type :image
          end
        end

        column :gallery_name do
          static true
          requires [:name, :format]
          sortable false
          visible fn state -> state.template.name() == :media_gallery end

          render fn record ->
            "#{record[:name]}.#{record[:format]}"
          end
        end

        column :gallery_size do
          static true
          requires [:size]
          sortable false
          visible fn state -> state.template.name() == :media_gallery end

          render fn record ->
            MishkaGervaz.Helpers.format_filesize(record[:size])
          end
        end

        column :thumbnail do
          static true
          requires [:id, :relative_path, :site_id, :format, :type, :archived_at, :updated_at]
          position :first
          sortable false
          label fn -> dgettext("mishka_gervaz", "Preview") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "70px"
          end

          render fn record ->
            is_image = record[:type] == :images
            format = record[:format]
            archived_at = record[:archived_at]
            relative_path = record[:relative_path]
            updated_at = record[:updated_at]

            cache_buster = if updated_at, do: "?v=#{DateTime.to_unix(updated_at)}", else: ""

            path =
              cond do
                is_nil(archived_at) ->
                  relative_path <> cache_buster

                archived_at && is_image ->
                  MishkaCmsCore.Runtime.Media.get_archived_image_data_uri(
                    relative_path,
                    record[:site_id],
                    format
                  ) || relative_path

                true ->
                  relative_path
              end

            icon_class =
              case format do
                f when f in ~w(mp4 webm mov) -> "hero-video-camera"
                f when f in ~w(mp3 wav ogg) -> "hero-musical-note"
                "pdf" -> "hero-document-text"
                f when f in ~w(xls xlsx csv) -> "hero-table-cells"
                f when f in ~w(zip rar 7z) -> "hero-archive-box"
                _ -> "hero-document"
              end

            assigns = %{id: record[:id], path: path, is_image: is_image, icon_class: icon_class}

            ~H"""
            <div
              id={"media-thumb-#{@id}"}
              phx-hook="MediaThumb"
              class="relative grid size-11 place-items-center overflow-hidden rounded-[10px] bg-[#faf9f6] ring-1 ring-[#f0efea]"
            >
              <span class={[if(@is_image, do: "hero-photo", else: @icon_class), "size-5 text-[#c3c0b8]"]}></span>
              <img
                :if={@is_image}
                src={@path}
                alt=""
                class="absolute inset-0 size-11 rounded-[10px] object-cover"
              />
            </div>
            """
          end
        end

        column :name do
          static true
          requires [:id, :name, :featured]
          sortable true
          sort_field [:name]
          label fn -> dgettext("mishka_gervaz", "Name") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(170px,1.5fr)"
          end

          render fn record ->
            short_id = String.slice(record.id, 0, 8) <> "…" <> String.slice(record.id, -4, 4)

            assigns = %{
              name: record.name,
              id: record.id,
              short_id: short_id,
              featured: record.featured
            }

            ~H"""
            <div class="flex min-w-0 items-center gap-[9px]">
              <svg
                :if={@featured}
                width="15"
                height="15"
                viewBox="0 0 24 24"
                fill="#e6b422"
                stroke="#e6b422"
                stroke-width="1.4"
                stroke-linejoin="round"
                class="shrink-0"
              >
                <path d="M12 3l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9 6.8 19.2l1-5.8L3.5 9.2l5.9-.9z" />
              </svg>
              <div class="min-w-0">
                <div class="truncate text-[13px] font-semibold text-[#17161a]">{@name}</div>
                <div class="mt-[2px] flex items-center gap-[5px]">
                  <span class="font-['Space_Grotesk'] text-[10.5px] font-medium text-[#a8a5a0]">{@short_id}</span>
                  <.copy_button
                    id={"media-id-copy-#{@id}"}
                    value={@id}
                    label={dgettext("mishka_gervaz", "Copy media ID")}
                  />
                </div>
              </div>
            </div>
            """
          end
        end

        column :type do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Type") end
          visible fn state -> state.template.name() == :table end

          ui do
            type :badge
            extra @type_badge
            width "110px"
          end
        end

        column :format do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Format") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "90px"
          end

          render fn value ->
            assigns = %{format: value}

            ~H"""
            <span class="inline-flex items-center rounded-[6px] bg-[#f4f3ee] px-[8px] py-[3px] font-['Space_Grotesk'] text-[10px] font-bold uppercase tracking-[0.03em] text-[#6d6a63]">
              {@format}
            </span>
            """
          end
        end

        column :size do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Size") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "90px"
          end

          format fn size ->
            MishkaGervaz.Helpers.format_filesize(size)
          end
        end

        column :category_info do
          static true
          requires [:media_category_id, :media_category]
          label fn -> dgettext("mishka_gervaz", "Category") end

          ui do
            width "minmax(140px,1.4fr)"
          end

          render fn record ->
            assigns = %{category: record.media_category}

            ~H"""
            <span
              :if={@category}
              class="inline-flex max-w-[150px] items-center gap-[6px] truncate rounded-[7px] bg-[#f4f3ef] px-[9px] py-[4px] text-[11px] font-semibold text-[#6d6a63]"
            >
              <span class="size-[6px] shrink-0 rounded-[2px] bg-[#a8a5a0]"></span>
              <span class="truncate">{@category.name}</span>
            </span>
            <span :if={!@category} class="text-[11px] font-medium italic text-[#a8a5a0]">
              {dgettext("mishka_gervaz", "Uncategorized")}
            </span>
            """
          end
        end

        column :inserted_at,
          sortable: true,
          visible: false,
          label: fn -> dgettext("mishka_gervaz", "Created") end
      end

      filters do
        filter :search, :text do
          fields [:name, :description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

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

        filter :type, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Images"), :images},
              {dgettext("mishka_gervaz", "Videos"), :videos},
              {dgettext("mishka_gervaz", "Documents"), :documents}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Type") end
            prompt dgettext_noop("mishka_gervaz", "All types")
          end
        end

        filter :featured, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured Only") end
          end
        end

        filter :media_category_id, :relation do
          display_field &if &2.master_user?, do: "#{&1.name} - #{&1.site.name}", else: &1.name
          search_field :name
          mode :search
          min_chars 1
          page_size 15
          depends_on :site_id

          preload do
            always [:site]
          end

          load fn query, state ->
            site_id =
              if state.master_user? do
                case Map.get(state.filter_values, :site_id) do
                  ids when is_list(ids) and ids != [] -> ids
                  id when is_binary(id) and id != "" -> id
                  _ -> nil
                end
              else
                Map.get(state.current_user || %{}, :site_id)
              end

            case site_id do
              nil ->
                query

              ids when is_list(ids) ->
                Ash.Query.filter(query, site_id in ^ids)

              id when is_binary(id) ->
                Ash.Query.filter(query, site_id == ^id)
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Category") end
            placeholder fn -> dgettext("mishka_gervaz", "Search categories...") end
            disabled_prompt fn -> dgettext("mishka_gervaz", "Select Site first") end
          end
        end
      end

      row_actions do
        # THE EDITOR'S OWN ACTION. The builder's Assets sheet mounts this same gallery; the only
        # thing it needs that the Media page does not is "put this file in the attribute I came
        # from". It is hidden everywhere else, because an action that cannot do anything reads as
        # one that is broken.
        #
        # `editor_pick_node` is prefixed deliberately: Gervaz turns any path param whose name
        # matches a resource attribute into an equality filter, and this one must filter nothing.
        # (`site_id` rides in the same map for the opposite reason — there the filter IS the point.)
        action :use_in_editor do
          type :event
          event "use_media"
          visible fn _record, state -> is_binary(state.path_params[:editor_pick_node]) end

          ui do
            label fn -> dgettext("mishka_gervaz", "Use") end
            icon "hero-arrow-down-on-square"
          end
        end

        action :preview do
          type :event
          event "preview"

          ui do
            label fn -> dgettext("mishka_gervaz", "Preview") end
            icon "hero-eye"
          end
        end

        action :edit do
          type :edit
          visible :active

          js fn _record ->
            Phoenix.LiveView.JS.focus(to: "#media-upload-card")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
          end
        end

        action :toggle_featured do
          type :update
          action {:master_toggle_featured, :toggle_featured}
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Toggle Featured") end
            icon "hero-star"
          end
        end

        action :delete do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this media?")
          end

          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Archive") end
            icon "hero-archive-box"
          end
        end

        action :restore do
          type :unarchive
          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
          end
        end

        action :permanent_delete do
          type :permanent_destroy

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Are you sure? This will permanently delete the file!"
                  )

          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete Permanently") end
            icon "hero-trash"
          end
        end
      end

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected media files?"),
          visible: :active

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected media files?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected files? This cannot be undone."
            ),
          visible: :archived

        action :toggle_featured do
          handler {:master_toggle_featured, :toggle_featured}
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Toggle Featured") end
            icon "hero-star"
          end
        end
      end

      row do
        class do
          apply fn record ->
            if record.featured, do: "bg-[#fdf9ec]", else: nil
          end
        end
      end

      realtime do
        prefix "media"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No media files found"),
                  icon: "hero-photo"

      # A GLOBAL DOCUMENT IS RENDERED BY EVERY SITE, so the visual editor offers it only files of sites
      # that are up: a file of an inactive or offline site would not load for anyone else. The editor
      # asks with `editor_open_only` in `path_params`, which matches no attribute and filters nothing
      # on its own.
      hooks do
        on_load fn query, state ->
          if state.path_params[:editor_open_only] do
            open = MishkaCmsCore.Runtime.SiteAvailability.open_site_ids()
            {:cont, Ash.Query.filter(query, site_id in ^open)}
          else
            {:cont, query}
          end
        end
      end
    end

    form do
      identity do
        name :media_form
      end

      source do
        actions do
          create {:master_form_upload, :form_upload}
        end

        preload do
          tenant [:media_category]
          master master_media_category: :media_category
        end
      end

      fields do
        field :site_id, :relation do
          show_on :create
          restricted true
          required true
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            placeholder fn -> dgettext("mishka_gervaz", "Select site...") end
          end
        end

        field :media_category_id, :relation do
          display_field :name
          search_field :name
          mode :search
          depends_on :site_id

          load fn query, state ->
            site_id =
              case state do
                %{field_values: %{site_id: sid}} when is_binary(sid) and sid != "" ->
                  sid

                %{form: %{source: %{source: %{data: %{site_id: sid}}}}} when is_binary(sid) ->
                  sid

                %{current_user: %{site_id: sid}} when is_binary(sid) ->
                  sid

                _ ->
                  nil
              end

            # A category belongs to one site, so a file with no site yet is offered none.
            if site_id do
              Ash.Query.filter(query, site_id == ^site_id)
            else
              Ash.Query.filter(query, false)
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Category") end
            placeholder fn -> dgettext("mishka_gervaz", "Search categories...") end
          end
        end

        field :description, :textarea do
          show_on :update

          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            rows 3
            span 2
          end
        end

        field :featured, :checkbox do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured") end
          end
        end

        field :name, :text do
          show_on :update
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :type, :select do
          show_on :update

          options fn ->
            [
              {dgettext("mishka_gervaz", "Images"), :images},
              {dgettext("mishka_gervaz", "Videos"), :videos},
              {dgettext("mishka_gervaz", "Documents"), :documents}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Type") end
          end
        end

        field :size, :number do
          show_on :update
          readonly true

          ui do
            label fn -> dgettext("mishka_gervaz", "Size (bytes)") end
          end
        end

        field :format, :text do
          show_on :update
          readonly true

          ui do
            label fn -> dgettext("mishka_gervaz", "Format") end
          end
        end

        # Shown, never sent: the update actions do not accept it, and a new file is how it changes.
        field :relative_path, :text do
          show_on :update
          readonly true

          ui do
            label fn -> dgettext("mishka_gervaz", "Path") end
          end
        end
      end

      groups do
        group :upload_fields do
          fields [:site_id, :media_category_id, :featured, :name]

          ui do
            columns 3
            class ""
          end
        end

        group :edit_fields do
          fields [:description, :type, :size, :format, :relative_path]

          ui do
            columns 2
            class ""
          end
        end
      end

      uploads do
        upload :media_files do
          accept ~w(.jpg .jpeg .png .gif .webp .svg .mp4 .webm .mov .pdf .doc .docx .xls .xlsx .ppt .pptx .txt .csv)
          max_entries 1
          max_file_size 50_000_000
          style :dropzone

          existing fn record ->
            if record.relative_path do
              cache_buster =
                if record.updated_at, do: "?v=#{DateTime.to_unix(record.updated_at)}", else: ""

              [
                %{
                  filename: record.name,
                  id: record.id,
                  url: record.relative_path <> cache_buster,
                  type: record.type,
                  size: record.size,
                  format: record.format
                }
              ]
            else
              []
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Files") end
          end
        end
      end

      presentation do
        features :all
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :type, :atom, derives: "validate(atom, enum=Atom[images::videos::documents])"

    field :size, :integer, derives: "validate(integer, min_len=1)"

    field :format, :string,
      derives: ~S|sanitize(trim, downcase) validate(string, regex=^[a-z0-9]+$)|

    field :featured, :boolean, derives: "validate(boolean)"
    field :dimensions, :map, derives: "validate(optional=[map])"

    field :relative_path, :string, derives: "sanitize(trim) validate(string, not_empty)"

    field :description, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=1000])"
  end

  field_policies do
    field_policy [:version_count, :latest_version, :recent_versions] do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    # THE PATH COMES FROM WHOEVER STORED THE FILE, never from the request: `stored_path` is private,
    # so JSON:API and a form cannot set it and only server code passes it, as
    # `private_arguments: %{stored_path: path}` — `:upload`, `:master_upload`, the seeds and the
    # test generator. A caller naming `relative_path` is refused with `NoSuchInput`, so no row can
    # be made to name another site's file, or its own site's file under a second spelling.
    create :create do
      primary? true
      accept @admin_fields -- [:site_id, :relative_path]

      argument :stored_path, :string, public?: false, allow_nil?: false

      validate present([:name, :type, :size, :format])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :media_category_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "media category")}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change set_attribute(:relative_path, arg(:stored_path))
      change slugify(:name, into: :name)

      description "Creates media for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      accept @admin_fields -- [:relative_path]

      argument :stored_path, :string, public?: false, allow_nil?: false

      validate present([:name, :type, :size, :format, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :media_category_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "media category")}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change set_attribute(:relative_path, arg(:stored_path))
      change slugify(:name, into: :name)

      description "Creates media for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    action :upload, :struct do
      description "Uploads a file and creates media record for tenant users"
      constraints instance_of: MishkaCmsCore.Runtime.Media

      argument :file, Ash.Type.File, allow_nil?: false
      argument :original_filename, :string, allow_nil?: false
      argument :description, :string, allow_nil?: true
      argument :featured, :boolean, allow_nil?: true, default: false
      argument :media_category_id, :uuid, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        category_id = input.arguments[:media_category_id]

        with {:ok, file_info} <- validate_and_process_file(input.arguments),
             {:ok, saved_path} <- save_file_to_storage(file_info, context.tenant, category_id) do
          attrs = %{
            name: file_info.name,
            type: file_info.type,
            size: file_info.size,
            format: file_info.format,
            description: input.arguments[:description],
            featured: input.arguments[:featured] || false,
            media_category_id: category_id
          }

          MishkaCmsCore.Runtime.Media
          |> Ash.Changeset.for_create(:create, attrs,
            actor: context.actor,
            tenant: context.tenant,
            private_arguments: %{stored_path: saved_path}
          )
          |> Ash.create()
          |> keep_file_if_created(saved_path, context.tenant)
        end
      end
    end

    action :master_upload, :struct do
      description "Uploads a file and creates media record for master users - requires site_id"
      constraints instance_of: MishkaCmsCore.Runtime.Media

      argument :file, Ash.Type.File, allow_nil?: false
      argument :original_filename, :string, allow_nil?: false
      argument :site_id, :uuid, allow_nil?: false
      argument :description, :string, allow_nil?: true
      argument :featured, :boolean, allow_nil?: true, default: false
      argument :media_category_id, :uuid, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, context ->
        site_id = input.arguments.site_id
        category_id = input.arguments[:media_category_id]

        with {:ok, file_info} <- validate_and_process_file(input.arguments),
             {:ok, saved_path} <- save_file_to_storage(file_info, site_id, category_id) do
          attrs = %{
            name: file_info.name,
            type: file_info.type,
            size: file_info.size,
            format: file_info.format,
            site_id: site_id,
            description: input.arguments[:description],
            featured: input.arguments[:featured] || false,
            media_category_id: category_id
          }

          MishkaCmsCore.Runtime.Media
          |> Ash.Changeset.for_create(:master_create, attrs,
            actor: context.actor,
            private_arguments: %{stored_path: saved_path}
          )
          |> Ash.create()
          |> keep_file_if_created(saved_path, site_id)
        end
      end
    end

    create :form_upload do
      description "Creates media from file upload via form for tenant users"
      accept [:description, :featured, :media_category_id]

      argument :media_files, {:array, :map}, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :media_category_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "media category")}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change {MishkaCmsCore.Runtime.Resources.Changes.ProcessFileUpload, []}
      change slugify(:name, into: :name)
    end

    create :master_form_upload do
      description "Creates media from file upload via form for master users - bypasses multi-tenancy"
      multitenancy :bypass
      accept [:description, :featured, :media_category_id, :site_id]

      argument :media_files, {:array, :map}, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :media_category_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "media category")}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.ProcessFileUpload, []}
      change slugify(:name, into: :name)
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept @editable_fields

      argument :media_files, {:array, :map}, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :media_category_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "media category")}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived media. Please unarchive it first.")
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.ProcessFileUpload, []}
      change slugify(:name, into: :name)

      description "Updates media for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates media for master users - requires nil tenant context, prevents site_id changes"
      accept @editable_fields
      multitenancy :bypass
      require_atomic? false

      argument :media_files, {:array, :map}, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :media_category_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "media category")}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived media. Please unarchive it first.")
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.ProcessFileUpload, []}
      change slugify(:name, into: :name)

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end
    end

    read :archived do
      description "Lists archived media within current tenant context"
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived media system-wide, bypassing tenant filtering"
    end

    read :get_archived do
      description "Retrieves single archived media for recovery or inspection (tenant users)"
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived media for recovery or inspection (master users)"
    end

    # EVERY SITE'S FILES, a switched-off site's included: a master manages an inactive site from the
    # dashboard like any other. The one place that must not offer them is the visual editor choosing a
    # file for a GLOBAL document, which every site renders — there the Media table's `on_load` keeps
    # only the sites that are up (`SiteAvailability.open_site_ids/0`).
    read :master_read do
      description "Reads media across every site, a switched-off site's included, for a master"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single media by ID, bypassing tenant filtering (master users)"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_type do
      description "Filters media by type (images, videos, documents)"
      argument :type, :atom, allow_nil?: false
      filter expr(type == ^arg(:type))
    end

    read :by_category do
      description "Lists all media in a specific category"
      argument :media_category_id, :uuid, allow_nil?: false
      filter expr(media_category_id == ^arg(:media_category_id))
    end

    # NOT a TODO — verified reachable-by-nobody, recorded so the next reader need not re-derive it.
    # The action itself is unguarded (`multitenancy :bypass`, no `require_master`), but: it is not a
    # JSON:API route; of the relationships using it as `read_action`, only the includable one goes
    # through a resource whose OWN policies run on the relationship load, and an anonymous
    # `?include=` there answers 403; and the in-app callers select it by pattern-matching
    # `%User{site_id: nil}`. The missing guard is defence-in-depth, not an open door.
    #
    # If this action is ever routed, or another `master_*` relationship is added to `includes`, that
    # reasoning stops holding and it needs
    # `validate {..., TenantContext, require_master: true}` first.
    read :read_any do
      description "Reads media bypassing tenant filtering (internal use)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :get_any do
      description "Retrieves single media by ID, bypassing tenant filtering (internal use)"
      get? true
      multitenancy :bypass
    end

    destroy :destroy do
      description "Soft deletes media by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Media is already archived.")}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          MishkaCmsCore.Runtime.Media.archive_file(record.relative_path, record.site_id)
          {:ok, record}
        end)
      end
    end

    destroy :master_destroy do
      description "Soft deletes media by archiving (master users) - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Media is already archived.")}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          MishkaCmsCore.Runtime.Media.archive_file(record.relative_path, record.site_id)
          {:ok, record}
        end)
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      atomic_upgrade_with :archived

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          MishkaCmsCore.Runtime.Media.unarchive_file(record.relative_path, record.site_id)
          {:ok, record}
        end)
      end

      description "Restores archived media to active status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived media to active status (master users) - requires nil tenant context"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Media is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          MishkaCmsCore.Runtime.Media.unarchive_file(record.relative_path, record.site_id)
          {:ok, record}
        end)
      end

      atomic_upgrade_with :master_archived
    end

    update :toggle_featured do
      description "Toggles the featured status of media (tenant users)"
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change fn changeset, _context ->
        current_featured = changeset.data.featured || false
        Ash.Changeset.change_attribute(changeset, :featured, !current_featured)
      end
    end

    update :master_toggle_featured do
      description "Toggles the featured status of media (master users)"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:featured, !changeset.data.featured)
        |> Ash.Changeset.set_tenant(changeset.data.site_id)
      end
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          %{relative_path: relative_path, site_id: site_id} = changeset.data
          MishkaCmsCore.Runtime.Media.delete_file_from_storage(relative_path, site_id)
          changeset
        end)
      end

      description "Permanently removes media and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes media and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          %{relative_path: relative_path, site_id: site_id} = changeset.data
          MishkaCmsCore.Runtime.Media.delete_file_from_storage(relative_path, site_id)
          changeset
        end)
      end
    end

    read :get_with_versions do
      get? true
      description "Gets a single media with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.Media.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :master_get_with_versions do
      get? true
      multitenancy :bypass
      description "Gets a single media with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.Media.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a media with pagination (tenant users)"

      argument :media_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        # WHOSE SITE THIS READ READS comes from the actor, not from the tenant alone. No site,
        # no versions.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.reading_site(context)

        media_id = Ash.Query.get_argument(query, :media_id)

        case Ash.get(MishkaCmsCore.Runtime.Media, media_id,
               tenant: acting_site,
               authorize?: false
             ) do
          {:ok, _media} ->
            query
            |> Ash.Query.filter(id == ^media_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaCmsCore.Runtime.Media.Version
                |> Ash.Query.for_read(:read_any)
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Media)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a media with pagination (master users)"

      argument :media_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        media_id = Ash.Query.get_argument(query, :media_id)

        query
        |> Ash.Query.filter(id == ^media_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaCmsCore.Runtime.Media.Version
            |> Ash.Query.for_read(:read_any)
        )
      end
    end

    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the media to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived media. Please unarchive it first."
                )
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.Media.Version}

      # A version written before the rule may name another site's category; restoring it does not.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :media_category_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "media category")}
    end

    action :restore_version_api, :struct do
      description "Restores media content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaCmsCore.Runtime.Media

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        media_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaCmsCore.Runtime.Media, media_id,
          action: :read,
          tenant: acting_site,
          authorize?: false
        )
        |> case do
          {:ok, media} when not is_nil(media) ->
            if !is_nil(media.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived media. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = media.site_id

              Ash.get(MishkaCmsCore.Runtime.Media.Version, version_id,
                action: :get_any,
                authorize?: false
              )
              |> case do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != media_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop("errors", "Version does not belong to this media.")
                         )
                       ]
                     )}
                  else
                    media
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.Media.Version
                   )}
              end
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Media)}
        end
      end
    end

    action :master_restore_version, :struct do
      description "Restores media content from a specific version in history (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Media

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        media_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaCmsCore.Runtime.Media, media_id,
          action: :master_get,
          authorize?: false
        )
        |> case do
          {:ok, media} when not is_nil(media) ->
            if !is_nil(media.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived media. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = media.site_id

              Ash.get(MishkaCmsCore.Runtime.Media.Version, version_id,
                action: :get_any,
                authorize?: false
              )
              |> case do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != media_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop("errors", "Version does not belong to this media.")
                         )
                       ]
                     )}
                  else
                    media
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.Media.Version
                   )}
              end
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Media)}
        end
      end
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaCmsCore.Runtime.Media

      argument :media_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        media_id = input.arguments.media_id
        version_id = input.arguments.version_id

        with {:ok, media} when not is_nil(media) <-
               Ash.get(MishkaCmsCore.Runtime.Media, media_id,
                 tenant: acting_site,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Media.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == media_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.Media
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_media =
            Enum.reduce(restored_attrs, media, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)

                value =
                  cond do
                    key_atom == :type and is_binary(value) -> String.to_atom(value)
                    true -> value
                  end

                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_media}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this media.")
                 )
               ]
             )}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Media)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Media)}
        end
      end
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Media

      argument :media_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        media_id = input.arguments.media_id
        version_id = input.arguments.version_id

        with {:ok, media} when not is_nil(media) <-
               Ash.get(MishkaCmsCore.Runtime.Media, media_id,
                 action: :master_get,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Media.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == media_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.Media
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_media =
            Enum.reduce(restored_attrs, media, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)

                value =
                  cond do
                    key_atom == :type and is_binary(value) -> String.to_atom(value)
                    true -> value
                  end

                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_media}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this media.")
                 )
               ]
             )}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Media)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Media)}
        end
      end
    end
  end

  policies do
    # PREVIEWING A VERSION IS READING IT, though it is a generic action.
    bypass action([:preview_version, :master_preview_version]) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # MEDIA IS CONTENT: anyone under the request's surface reads the library, and writing it takes
    # the media section, `admin:<surface>:runtime:media`.
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)
      authorize_if accessing_from(MishkaCmsCore.Runtime.MediaCategory, :media)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:runtime:media", "admin:api:runtime:media"]}

      forbid_unless action_type(:read)
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # A RESTORE WRITES THE RECORD, so it is held to the actor at the moment it runs: a master
    # (`site_id` nil) restores any site's record, a site user only its own site's, whatever it holds
    # and whichever tenant it passed. The API and master wrappers restore as the system.
    policy action(:restore_version) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    # WHOSE ROWS A READ SHOWS, held to the actor when it runs, whichever read it is — `:read_any`
    # and `:get_any` included: a master (`site_id` nil) reads any site's rows, a site user its own
    # site's, whatever it holds or passes as a tenant. System reads pass `authorize?: false`.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "media"

    publish :create, [[nil, :site_id], "created"]
    publish :form_upload, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :restore_version, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :toggle_featured, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    publish :master_create, [[nil, :site_id], "created"]
    publish :master_form_upload, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_toggle_featured, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Name of the file"
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:images, :videos, :documents]
      description "Type of media (images, videos, documents)"
    end

    attribute :size, :integer do
      allow_nil? false
      public? true
      constraints min: 1
      description "Size of the media file in bytes"
    end

    attribute :format, :string do
      allow_nil? false
      public? true
      constraints trim?: true
      description "Format of the file (e.g., png, pdf, mp4)"
    end

    attribute :featured, :boolean do
      default false
      public? true
      description "Whether the media is featured"
    end

    attribute :dimensions, :map do
      allow_nil? true
      public? true
      default %{}

      constraints fields: [
                    width: [
                      type: :integer,
                      allow_nil?: true
                    ],
                    height: [
                      type: :integer,
                      allow_nil?: true
                    ],
                    unit: [
                      type: :string,
                      allow_nil?: true
                    ]
                  ]

      description "Dimensions of the media (width, height, unit)"
    end

    attribute :relative_path, :string do
      allow_nil? false
      public? true
      constraints trim?: true
      description "Relative path to the media file"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 1000, trim?: true
      description "Optional description of the media"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this media belongs to"
    end

    belongs_to :media_category, MishkaCmsCore.Runtime.MediaCategory do
      allow_nil? true
      public? true
      description "The category this media belongs to (optional, tenant users)"
    end

    belongs_to :master_media_category, MishkaCmsCore.Runtime.MediaCategory do
      public? true
      source_attribute :media_category_id
      define_attribute? false
      read_action :read_any
      description "The category this media belongs to (master admin access, bypass tenant)"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.Media.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  calculations do
    calculate :version_preview,
              :map,
              {MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview,
               version: MishkaCmsCore.Runtime.Media.Version} do
      public? true
      argument :version_id, :uuid, allow_nil?: false

      description "Retrieves content from one of this record's own versions for preview before restoration"
    end

    calculate :version_count, :integer do
      public? true
      description "Counts total number of versions in media history"

      calculation fn records, _context ->
        Enum.map(records, fn media ->
          case MishkaCmsCore.Runtime.Media.Version
               |> Ash.Query.for_read(:read_any)
               |> Ash.Query.filter(version_source_id == ^media.id)
               |> Ash.count(authorize?: false) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaCmsCore.Runtime.Media.Version
      description "Returns the most recent version for the media"

      calculation fn records, _context ->
        media_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Media.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^media_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn media ->
          Map.get(versions_map, media.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaCmsCore.Runtime.Media.Version]

      description "Returns the 10 most recent versions for the media in descending order by insertion date"

      calculation fn records, _context ->
        media_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Media.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^media_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn media ->
          Map.get(versions_map, media.id, [])
        end)
      end
    end

    calculate :archived_data_url, :string do
      public? true

      description "Returns base64 data URL for archived media files (reads from uploads_archived directory)"

      calculation fn records, _context ->
        Enum.map(records, fn
          %{archived_at: nil} ->
            nil

          media ->
            MishkaCmsCore.Runtime.Media.get_archived_image_data_uri(
              media.relative_path,
              media.site_id,
              media.format
            )
        end)
      end
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Ensures media names are unique within each site for clear identification"
      message dgettext_noop("errors", "Media name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_path_per_site, [:relative_path, :site_id] do
      description "Prevents path conflicts by ensuring unique paths per site"
      message dgettext_noop("errors", "Media path must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end
  end

  @allowed_extensions %{
    images: ~w(.jpg .jpeg .png .gif .webp .svg),
    videos: ~w(.mp4 .webm .mov),
    documents: ~w(.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .csv)
  }

  @max_file_size 50_000_000

  def validate_and_process_file(%{file: file, original_filename: filename}) do
    ext = Path.extname(filename) |> String.downcase()

    with :ok <- validate_extension(ext),
         {:ok, path} <- get_file_path(file),
         {:ok, size} <- get_file_size(path),
         :ok <- validate_file_size(size) do
      {:ok,
       %{
         name: upload_name(filename),
         format: String.trim_leading(ext, "."),
         type: get_media_type(ext),
         size: size,
         extension: ext,
         source_path: path
       }}
    end
  end

  defp validate_extension(ext) do
    all_extensions =
      @allowed_extensions
      |> Map.values()
      |> List.flatten()

    if ext in all_extensions do
      :ok
    else
      {:error,
       Ash.Error.Invalid.exception(
         errors: [
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :file,
             message:
               dgettext_noop(
                 "errors",
                 "File type %{extension} is not allowed. Allowed: %{allowed}."
               ),
             vars: [extension: ext, allowed: Enum.join(all_extensions, ", ")]
           )
         ]
       )}
    end
  end

  defp validate_file_size(size) when size > @max_file_size do
    max_mb = div(@max_file_size, 1_000_000)

    {:error,
     Ash.Error.Invalid.exception(
       errors: [
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :file,
           message: dgettext_noop("errors", "File size exceeds the maximum of %{max} MB."),
           vars: [max: max_mb]
         )
       ]
     )}
  end

  defp validate_file_size(_size), do: :ok

  defp get_file_path(file) do
    case Ash.Type.File.path(file) do
      {:ok, path} -> {:ok, path}
      {:error, :not_supported} -> {:error, dgettext_noop("errors", "File source not supported")}
    end
  end

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, size}

      {:error, reason} ->
        {:error,
         file_error(dgettext_noop("errors", "Cannot read file: %{reason}"),
           reason: inspect(reason)
         )}
    end
  end

  defp get_media_type(ext) do
    cond do
      ext in @allowed_extensions.images -> :images
      ext in @allowed_extensions.videos -> :videos
      ext in @allowed_extensions.documents -> :documents
      true -> :documents
    end
  end

  @doc """
  The `name` an upload of `filename` carries into the create: its basename without the extension,
  stripped of everything but word characters, spaces and dashes, spaces turned to dashes, downcased
  and cut to 200 characters. The action's own `slugify(:name, into: :name)` runs after this and has
  the last word on what the row holds.

  Public because that name is the row's own key — `unique_name_per_site` — so anything asking whether
  a file is already in a site's library has to ask under the name an upload of it would produce.
  `MishkaCmsCore.Dev.SeedMedia` is the caller: working the rule out a second time over there would
  be a second answer that could disagree with this one.
  """
  @spec upload_name(String.t()) :: String.t()
  def upload_name(filename) when is_binary(filename) do
    filename
    |> Path.basename(filename |> Path.extname() |> String.downcase())
    |> sanitize_filename()
  end

  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.downcase()
    |> String.slice(0, 200)
  end

  # EVERY MEDIA FILE LIVES IN ITS SITE'S OWN FOLDER, `uploads/<site_id>/media/`, and moves to
  # `uploads_archived/<site_id>/media/` while its row is archived. `relative_path` is the file's URL,
  # `/uploads/<site_id>/media/<category>/<file>`, which the endpoint serves while the site is up.
  # `:media_static_dir` points the folder both sit in elsewhere, as tests do.
  defp static_dir, do: Application.get_env(:mishka_cms_core, :media_static_dir, "priv/static")

  defp media_folder(tree, site_id), do: Path.join([static_dir(), tree, site_id, "media"])

  @doc """
  Where the media file `relative_path` of the site `site_id` is on disk: `:active` under `uploads/`,
  `:archived` under `uploads_archived/`, and `:relative`, its URL with any `.` and `..` worked out.

  `:error` unless it is a file inside that site's own media folder, `/uploads/<site_id>/media/`: a
  path naming another site, another folder of the same site, or climbing out with `..` or through a
  symbolic link is refused, and so is one naming a folder — live or archived — rather than a file,
  which a move or a rename would carry off whole, with every other row's file in it. Every function
  here that writes, reads, moves or deletes a media file asks this first, with the row's own
  `site_id`, and touches nothing when it is refused.
  """
  @spec storage_paths(term(), term()) ::
          {:ok, %{relative: String.t(), active: Path.t(), archived: Path.t()}} | :error
  def storage_paths("/uploads/" <> relative, site_id) when is_binary(site_id) do
    own = media_folder("uploads", site_id)

    with {:ok, ^site_id} <- Ecto.UUID.cast(site_id),
         [^site_id, "media" | [_ | _] = inner] <- Path.split(relative),
         {:ok, clean} when clean != "" <- Path.safe_relative(Path.join(inner), own),
         active = Path.join(own, clean),
         archived = Path.join(media_folder("uploads_archived", site_id), clean),
         false <- File.dir?(active) or File.dir?(archived) do
      {:ok,
       %{
         relative: Path.join(["/uploads", site_id, "media", clean]),
         active: active,
         archived: archived
       }}
    else
      _outside -> :error
    end
  end

  def storage_paths(_relative_path, _site_id), do: :error

  # THE ONE GATE IN FRONT OF THE DISK. A refused path is announced on `cms_core:media:path_refused`
  # as `%{op:, relative_path:, site_id:}` — `op` one of `:save`, `:replace`, `:archive`,
  # `:unarchive`, `:delete`, `:read`, or `:source` for an upload's own file (`staged_upload/2`) —
  # for a plugin to log or alert on; the file it names is left where it is.
  defp own_file(op, relative_path, site_id) do
    case storage_paths(relative_path, site_id) do
      {:ok, paths} -> {:ok, paths}
      :error -> refuse_path(op, relative_path, site_id)
    end
  end

  defp refuse_path(op, path, site_id) do
    MishkaInstaller.Event.Hook.call(
      "cms_core:media:path_refused",
      %{op: op, relative_path: path, site_id: site_id},
      return: false
    )

    :error
  end

  @doc """
  The file a form's upload entry names in its `path`, when it is one a form's upload was staged as.

  MishkaGervaz consumes each upload of a submitted form into `System.tmp_dir!()` as
  `gervaz_<n>_<client name>` and hands the action that path in `media_files`
  (`MishkaGervaz.Form.Web.Events.SubmitHandler`). But `media_files` is a map a request can carry
  too — as a form field, or as a JSON:API attribute — and the file it names is copied into the
  site's folder and then deleted. So only a regular file straight inside that folder and named that
  way is taken, `..` worked out first; a symbolic link, a folder, and every other path answer
  `:error`, are announced on `cms_core:media:path_refused` as op `:source` with the row's
  `site_id`, and are left untouched.
  """
  @spec staged_upload(term(), term()) :: {:ok, Path.t()} | :error
  def staged_upload(path, site_id) when is_binary(path) do
    staged = Path.expand(path)

    with true <- Path.dirname(staged) == Path.expand(System.tmp_dir!()),
         "gervaz_" <> _ <- Path.basename(staged),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(staged) do
      {:ok, staged}
    else
      _not_staged -> refuse_path(:source, path, site_id)
    end
  end

  def staged_upload(path, site_id), do: refuse_path(:source, path, site_id)

  # An upload's file is stored before its row is written, so a refused row takes its file with it.
  defp keep_file_if_created({:ok, _media} = created, _relative_path, _site_id), do: created

  defp keep_file_if_created({:error, _refused} = refused, relative_path, site_id) do
    delete_file_from_storage(relative_path, site_id)
    refused
  end

  def save_file_to_storage(%{source_path: source_path, extension: ext}, site_id, category_id) do
    category_dir = category_id || "uncategorized"
    path = "/uploads/#{site_id}/media/#{category_dir}/#{Ash.UUID.generate()}#{ext}"

    with {:ok, %{relative: relative_path, active: dest_path}} <- own_file(:save, path, site_id),
         :ok <- File.mkdir_p(Path.dirname(dest_path)),
         :ok <- File.cp(source_path, dest_path) do
      File.rm(source_path)
      {:ok, relative_path}
    else
      :error ->
        {:error,
         file_error(
           dgettext_noop("errors", "Failed to save file: not a folder of its site's own")
         )}

      {:error, reason} ->
        {:error,
         file_error(dgettext_noop("errors", "Failed to save file: %{reason}"),
           reason: inspect(reason)
         )}
    end
  end

  @doc """
  Puts the upload `file_info` in place of the file `existing_relative_path` names, at the same path,
  or beside it under the new extension when the format changed.

  `{:error, :not_own_file}` when that path is not a file of the site `site_id`'s own folder — see
  `storage_paths/2` — and nothing is written: the caller stores the upload as a new file instead.
  """
  def replace_file_in_storage(file_info, existing_relative_path, site_id) do
    with {:ok, old} <- own_file(:replace, existing_relative_path, site_id),
         {:ok, new} <- own_file(:replace, replaced_path(old.relative, file_info), site_id) do
      replace_file(file_info.source_path, old, new)
    else
      :error -> {:error, :not_own_file}
    end
  end

  defp replaced_path(relative_path, %{extension: new_ext}) do
    old_ext = Path.extname(relative_path)

    if String.downcase(old_ext) == String.downcase(new_ext),
      do: relative_path,
      else: String.replace_suffix(relative_path, old_ext, new_ext)
  end

  defp replace_file(source_path, old, new) do
    same_format? = old.active == new.active
    backup_path = old.active <> ".replacing"

    with :ok <- backup_old_file(old.active, backup_path),
         :ok <- File.cp(source_path, new.active) do
      File.rm(backup_path)
      File.rm(source_path)
      if !same_format?, do: File.rm(old.active)
      {:ok, new.relative}
    else
      {:error, reason} ->
        restore_backup(old.active, backup_path)
        if !same_format?, do: File.rm(new.active)

        {:error,
         file_error(dgettext_noop("errors", "Failed to replace file: %{reason}"),
           reason: inspect(reason)
         )}
    end
  end

  defp file_error(message, bindings \\ []) do
    message = Gettext.dgettext(MishkaCmsCore.Gettext, "errors", message, bindings)

    Ash.Error.Invalid.exception(
      errors: [Ash.Error.Changes.InvalidAttribute.exception(field: :file, message: message)]
    )
  end

  defp backup_old_file(full_path, backup_path) do
    if File.exists?(full_path) do
      File.rename(full_path, backup_path)
    else
      :ok
    end
  end

  defp restore_backup(full_path, backup_path) do
    if File.exists?(backup_path) do
      File.rm(full_path)
      File.rename(backup_path, full_path)
    end
  end

  @doc """
  Removes a media file for good, live or archived — a file of the site `site_id`'s own folder only
  (see `storage_paths/2`). Any other path answers `{:error, :not_own_file}` and is left alone.
  """
  def delete_file_from_storage(relative_path, site_id) do
    case own_file(:delete, relative_path, site_id) do
      {:ok, %{active: active, archived: archived}} ->
        cond do
          File.exists?(active) ->
            remove_file(active, media_folder("uploads", site_id))

          File.exists?(archived) ->
            remove_file(archived, media_folder("uploads_archived", site_id))

          true ->
            :ok
        end

      :error ->
        {:error, :not_own_file}
    end
  end

  @doc """
  Moves an archived row's file into `uploads_archived/`, where the endpoint does not serve it — a file
  of the site `site_id`'s own folder only (see `storage_paths/2`). Any other path answers
  `{:error, :not_own_file}` and is left alone.
  """
  def archive_file(relative_path, site_id) do
    case own_file(:archive, relative_path, site_id) do
      {:ok, %{active: active, archived: archived}} ->
        move_file(active, archived, media_folder("uploads", site_id))

      :error ->
        {:error, :not_own_file}
    end
  end

  @doc "Moves a restored row's file back to `uploads/`; the counterpart of `archive_file/2`."
  def unarchive_file(relative_path, site_id) do
    case own_file(:unarchive, relative_path, site_id) do
      {:ok, %{active: active, archived: archived}} ->
        move_file(archived, active, media_folder("uploads_archived", site_id))

      :error ->
        {:error, :not_own_file}
    end
  end

  @doc """
  An archived file as a `data:` URL, the only way the admin can still show it: `uploads_archived/`
  is not served. `nil` when the file is not there, or is not a file of the site `site_id`'s own
  folder (see `storage_paths/2`).
  """
  def get_archived_image_data_uri(relative_path, site_id, format) do
    with {:ok, %{archived: archived}} <- own_file(:read, relative_path, site_id),
         {:ok, binary} <- File.read(archived) do
      "data:#{get_content_type(format)};base64,#{Base.encode64(binary)}"
    else
      _unreadable -> nil
    end
  end

  defp remove_file(path, folder) do
    File.rm(path)
    cleanup_empty_dirs(Path.dirname(path), folder)
    :ok
  end

  defp move_file(source, dest, source_folder) do
    with true <- File.exists?(source),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- rename_or_copy(source, dest) do
      cleanup_empty_dirs(Path.dirname(source), source_folder)
      :ok
    else
      false -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A rename cannot cross disks, so two trees on different ones take a copy and a delete.
  defp rename_or_copy(source, dest) do
    case File.rename(source, dest) do
      :ok -> :ok
      {:error, _reason} -> with :ok <- File.cp(source, dest), do: File.rm(source)
    end
  end

  # Up from a file removed or moved away, each folder it leaves empty goes too — up to, never
  # including, the site's own media folder.
  defp cleanup_empty_dirs(dir, folder) do
    if String.starts_with?(dir, folder <> "/") and File.ls(dir) == {:ok, []} do
      File.rmdir(dir)
      cleanup_empty_dirs(Path.dirname(dir), folder)
    end
  end

  def get_content_type(format) do
    case String.downcase(format) do
      "jpg" -> "image/jpeg"
      "jpeg" -> "image/jpeg"
      "png" -> "image/png"
      "gif" -> "image/gif"
      "webp" -> "image/webp"
      "svg" -> "image/svg+xml"
      "mp4" -> "video/mp4"
      "webm" -> "video/webm"
      "mov" -> "video/quicktime"
      "pdf" -> "application/pdf"
      "doc" -> "application/msword"
      "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      "xls" -> "application/vnd.ms-excel"
      "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      "ppt" -> "application/vnd.ms-powerpoint"
      "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      "txt" -> "text/plain"
      "csv" -> "text/csv"
      _ -> "application/octet-stream"
    end
  end
end
