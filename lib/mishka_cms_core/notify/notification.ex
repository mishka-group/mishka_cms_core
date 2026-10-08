defmodule MishkaCmsCore.Notify.Notification do
  @moduledoc """
  A single, per-recipient, read/unread notification row (`cms_notifications`).

  One row per recipient (fan-out on write), so privacy is a one-line policy
  (`user_id == actor(:id)`) and the feed is a single indexed lookup. Notifications are
  transient personal state — no archival, no PaperTrail versions (like `Accounts.Token`).

  Tenancy: `site_id` is the **recipient's** site (`nil` for master users, who read
  unscoped and are still confined to their own rows by the policy). The site an event
  *concerns* is carried in `metadata` for display, never in `site_id`.

  Two nullable timestamps drive the standard UX with zero extra machinery:

    * `seen_at` — `nil` counts toward the bell badge; cleared when the dropdown opens.
    * `read_at` — `nil` renders bold/unread; cleared per item or via "mark all read".

  `type` is an **open string** validated by format (like a permission name), not an enum —
  so a new extension can deliver an unknown type without a code change. Whether a site
  receives a given type is a per-site boolean Setting (`MishkaCmsCore.Notify.setting_key/1`),
  checked once at delivery — not stored here.

  Delivered exclusively through `MishkaCmsCore.Notify.deliver/3` (system-internal,
  `authorize?: false`). See `MishkaCmsCore.Notify`, `MishkaCmsCore.Notify.Delivery`.
  """

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Notify,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaGervaz.Resource, GuardedStruct.AshResource],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2, link: 1]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  @doc """
  Validate + sanitize notification `attrs` through the GuardedStruct pipeline (strip HTML, trim,
  validate) WITHOUT a DB write — the same pipeline `:deliver` runs on write. Returns
  `{:ok, sanitized_map}` or `{:error, errors}`; producers can call it to check/clean a notification
  before `Notify.deliver/3`. `GuardedStruct.AshResource` omits the `Codegen` transformer (Ash uses
  changesets), so this exposes the pipeline under the usual `builder/1` name.

      Notification.builder(%{type: "blog:x", title: "  <b>Hi</b> "})  #=> {:ok, %{title: "Hi", …}}
  """
  def builder(attrs, error? \\ false),
    do: GuardedStruct.AshResource.Info.validate(__MODULE__, attrs, error?)

  @recipient_fields [
    :type,
    :title,
    :body,
    :icon,
    :severity,
    :link,
    :source,
    :metadata,
    :user_id,
    :actor_id
  ]

  postgres do
    table "cms_notifications"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :user, on_delete: :delete
      reference :actor, on_delete: :nilify
      reference :site, on_delete: :delete
    end

    custom_indexes do
      # The feed query: newest-first per recipient.
      index [:user_id, :inserted_at], name: "cms_notifications_user_feed_index"
      # The bell badge count: only unseen rows (partial index keeps it tiny + fast).
      index [:user_id], where: "seen_at IS NULL", name: "cms_notifications_unseen_index"
    end
  end

  mishka_gervaz do
    table do
      identity do
        name :notifications
        route "/admin/dashboard/notifications"
        stream_name :notifications
      end

      # `:feed` is per-user policy-scoped + paginated and `global? true`, so one action serves master
      # and tenant alike; `:read` backs Ash.get for row actions; `:destroy` removes a row.
      source do
        actions do
          read :feed
          get :read
          destroy :destroy
        end
      end

      columns do
        default_sort [{:inserted_at, :desc}]

        column :icon do
          static true
          requires [:icon, :severity]
          label fn -> "" end

          render fn record ->
            assigns = %{
              icon: record.icon || "hero-bell",
              class: severity_class(record.severity)
            }

            ~H"""
            <div class={["grid size-[38px] place-items-center rounded-[11px]", @class]}>
              <.icon name={@icon} class="size-[18px]" />
            </div>
            """
          end
        end

        column :title do
          static true
          requires [:title, :read_at, :link]
          label fn -> dgettext("mishka_gervaz", "Notification") end

          # Weight is the template's (it knows read/unread); the colour is the same either way.
          render fn record ->
            assigns = %{
              title: Gettext.gettext(MishkaCmsCore.Gettext, record.title),
              link: record.link
            }

            ~H"""
            <.link :if={@link} navigate={@link} class="text-[#1b1a18] hover:underline">
              {@title}
            </.link>
            <span :if={!@link} class="text-[#1b1a18]">{@title}</span>
            """
          end
        end

        column :body do
          label fn -> dgettext("mishka_gervaz", "Message") end
        end

        column :inserted_at do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Received") end

          ui do
            type :datetime
          end
        end
      end

      filters do
        filter :search, :text, fields: [:title, :body]

        filter :severity, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Info"), :info},
              {dgettext("mishka_gervaz", "Success"), :success},
              {dgettext("mishka_gervaz", "Warning"), :warn},
              {dgettext("mishka_gervaz", "Error"), :error}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All severities")
            label fn -> dgettext("mishka_gervaz", "Severity") end
          end
        end

        # A clear Status dropdown, not a bare "Read" checkbox: "Unread" = read? == false,
        # "Read" = read? == true. String option values (HEEx would drop a `value={false}` attr);
        # Gervaz submits the string and `filter_input` casts it to the boolean calc, so the
        # filtering runs entirely through Ash.
        filter :read?, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Unread"), "false"},
              {dgettext("mishka_gervaz", "Read"), "true"}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end
      end

      row_actions do
        action :mark_read do
          type :update
          action :mark_read
          visible fn record, _user -> is_nil(record.read_at) end

          ui do
            label fn -> dgettext("mishka_gervaz", "Mark read") end
            icon "hero-check"

            class "inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#5c5a54] hover:text-[#177a53]"
          end
        end

        # Not in the design — the mock only ever greys "Read" out — but a read row here can be put
        # back, so it keeps the slot the design gives to that label.
        action :mark_unread do
          type :update
          action :mark_unread
          visible fn record, _user -> !is_nil(record.read_at) end

          ui do
            label fn -> dgettext("mishka_gervaz", "Read") end
            icon "hero-check"

            class "inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#b7b4ad] hover:text-[#5c5a54]"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Remove this notification?") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"

            class "inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#c0473d] hover:text-[#a5352c]"
          end
        end
      end

      row do
        selectable true
      end

      bulk_actions do
        action :mark_read, type: :update, action: :mark_read

        action :delete,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Delete selected notifications?")
      end

      pagination do
        type :load_more
        page_size 20
        page_size_options [20, 50, 150]

        ui do
          show_total true
          load_more_label dgettext_noop("mishka_gervaz", "Load more")
          page_info_format dgettext_noop("mishka_gervaz", "Showing {count} notifications")
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "notifs"
      end

      empty_state message: dgettext_noop("mishka_gervaz", "You have no notifications."),
                  icon: "hero-bell"

      presentation do
        template MishkaCmsCoreWeb.Templates.NotificationCard
      end
    end
  end

  # GuardedStruct is the extra pre-DB layer Ash constraints don't give: it SANITIZES the
  # user-derived text (strips HTML tags a producer may have copied from a comment/title and keeps
  # the rest as typed — `MishkaCmsCore.PlainText` — then trims) and adds validation, wired into the
  # write actions via `auto_wire true`. It also gives producers a
  # `builder/1` to validate+sanitize a notification as a struct BEFORE calling `deliver/3`.
  # `enforce` is deliberately omitted — Ash owns `allow_nil?` (see the pitfalls note).
  guardedstruct do
    auto_wire true

    field :type, :string, derives: "sanitize(trim) validate(string, not_empty)"

    field :title, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, max_len=255)"

    field :body, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string)"

    field :icon, :string, derives: "sanitize(trim) validate(string)"
    field :link, :string, derives: "sanitize(trim) validate(string)"
    field :source, :string, derives: "sanitize(trim) validate(string)"
  end

  actions do
    defaults [:read]

    create :deliver do
      description "System-internal create (one row per recipient). Only reached via Notify.deliver/3."
      accept @recipient_fields

      # global? true: stamp the recipient's site from the tenant context (nil for masters).
      change fn changeset, context ->
        if !is_nil(context.tenant) do
          Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant)
        else
          changeset
        end
      end

      # The recipient and whoever caused it are accounts of the row's site, or masters.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :user_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "recipient"),
                shared?: true,
                read_action: :related}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :actor_id,
                resource: MishkaCmsCore.Accounts.User,
                label: dgettext_noop("errors", "actor"),
                shared?: true,
                read_action: :related}
    end

    read :feed do
      description "The recipient's notifications, newest first (policy scopes to their own rows)."
      prepare build(sort: [inserted_at: :desc, id: :desc])

      pagination offset?: true,
                 keyset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :unseen_count do
      description "Count-only read (seen_at) — retained for the seen/glance semantics."
      filter expr(is_nil(seen_at))
    end

    read :unread_count do
      description "Count-only read backing the bell badge — unread rows (read_at is nil)."
      filter expr(is_nil(read_at))
    end

    read :prunable do
      description "Rows the retention sweep may delete: read rows past the read window, or anything past the hard cap."
      argument :read_before, :utc_datetime_usec, allow_nil?: false
      argument :max_before, :utc_datetime_usec, allow_nil?: false

      filter expr(
               (not is_nil(read_at) and inserted_at < ^arg(:read_before)) or
                 inserted_at < ^arg(:max_before)
             )
    end

    update :mark_read do
      accept []
      require_atomic? false
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end

    update :mark_unread do
      accept []
      require_atomic? false
      change set_attribute(:read_at, nil)
    end

    update :mark_seen do
      accept []
      require_atomic? false
      change set_attribute(:seen_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true
      description "Recipient removes their own row."
    end

    destroy :prune do
      description "System retention sweep (actor-less; called authorize?: false from the worker)."
    end
  end

  policies do
    # Delivery is system-internal (only via Notify.deliver, authorize?: false). Bypass so it
    # never AND-combines with the ownership policy below.
    bypass action([:deliver, :prune]) do
      authorize_if always()
    end

    # The privacy boundary: a user may only read/update/destroy their OWN notifications.
    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "notification"

    # Per-user topics — deliberately NOT the site-topic convention, so a user can never
    # receive another user's private rows via a shared topic.
    publish :deliver, [:user_id, "created"]
    publish :mark_read, [:user_id, "updated"]
    publish :mark_unread, [:user_id, "updated"]
    publish :mark_seen, [:user_id, "updated"]
    publish :destroy, [:user_id, "updated"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :type, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z][a-z0-9_]*(:[a-z0-9_.]+)*$/, max_length: 200
      description "Open, format-validated type, e.g. \"blog:comment:created\"."
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :body, :string do
      public? true
    end

    attribute :icon, :string do
      public? true
      description "hero-* icon name; the registry default fills in when nil."
    end

    attribute :severity, :atom do
      public? true
      default :info
      constraints one_of: [:info, :success, :warn, :error]
    end

    attribute :link, :string do
      public? true
      description "Internal path for click-through."
    end

    attribute :source, :string do
      public? true
      description "Producing extension, e.g. \"mishka_blog\"."
    end

    attribute :metadata, :map do
      public? true
      default %{}
      description "Denormalized display snapshot (actor name, counts…) — the feed never joins."
    end

    attribute :seen_at, :utc_datetime_usec do
      public? true
      description "nil = counts toward the bell badge."
    end

    attribute :read_at, :utc_datetime_usec do
      public? true
      description "nil = rendered bold/unread."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    # Creates the `site_id` tenant attribute. It is the RECIPIENT's site (nil for masters);
    # the site an event *concerns* lives in `metadata`, not here.
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? false
      public? true
      description "The recipient. Never cast by end users — set by Notify.deliver fan-out."
    end

    belongs_to :actor, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? true
      public? true
      description "Who caused the notification (optional)."
    end
  end

  calculations do
    # Ash-native read/unread flag so the inbox can filter by it through Ash (never raw SQL).
    calculate :read?, :boolean, expr(not is_nil(read_at)) do
      public? true
      description "true once the recipient has read the notification."
    end
  end

  defp severity_class(:error), do: "bg-[#fbe9e7] text-[#b3433a]"
  defp severity_class(:warn), do: "bg-[#fbf1df] text-[#a5691a]"
  defp severity_class(:success), do: "bg-[#e6f6ee] text-[#177a53]"
  defp severity_class(_), do: "bg-[#eef1fc] text-[#4f4bcc]"
end
