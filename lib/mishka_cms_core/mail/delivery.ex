defmodule MishkaCmsCore.Mail.Delivery do
  @moduledoc """
  One email the CMS sent, or tried to (`cms_mail_deliveries`): who it was for, what it was for,
  which provider took it and how that went. Never the body: a password-reset or magic-link email
  carries a sign-in token.

  Written by `MishkaCmsCore.Mail` alone (`authorize?: false`): a row is made `:queued` when an
  email is handed over, and `:mark` moves it to `:sent` or `:failed` as the provider answers, or
  records `:not_configured` when the site has no provider. A site's rows older than
  `mailer.history_days` go when it next sends (`MishkaCmsCore.Mail.prune/1`).

  Read by whoever may change the site's settings (`admin:dashboard:setting`): a site's admins see
  their own site's rows, a master (`site_id` nil) every site's and the installation's own. The
  settings page's Email tab lists them.
  """

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Mail,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaGervaz.Resource],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]

  @statuses [:queued, :sent, :failed, :not_configured]

  postgres do
    table "cms_mail_deliveries"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    custom_indexes do
      index [:site_id, :inserted_at], name: "cms_mail_deliveries_site_feed_index"
      index [:inserted_at], name: "cms_mail_deliveries_inserted_at_index"
    end
  end

  mishka_gervaz do
    table do
      identity do
        name :mail_deliveries
        route "/admin/dashboard/settings?tab=email"
        stream_name :mail_deliveries
      end

      source do
        actions do
          read :history
          get :read
        end

        preload do
          always [:site]
        end
      end

      columns do
        default_sort [{:inserted_at, :desc}]

        column :recipient do
          label fn -> dgettext("mishka_gervaz", "To") end
        end

        column :subject do
          label fn -> dgettext("mishka_gervaz", "Subject") end
        end

        column :purpose do
          static true
          requires [:purpose]
          label fn -> dgettext("mishka_gervaz", "Kind") end

          render fn record ->
            assigns = %{purpose: MishkaCmsCore.Mail.purpose_label(record.purpose)}

            ~H"""
            <span class="text-[12.5px] text-[#5c5a54]">{@purpose}</span>
            """
          end
        end

        column :status do
          static true
          requires [:status, :provider, :error]
          label fn -> dgettext("mishka_gervaz", "Status") end

          render fn record ->
            assigns = %{
              label: MishkaCmsCore.Mail.status_label(record.status),
              class: status_class(record.status),
              provider: record.provider,
              error: record.error
            }

            ~H"""
            <span class={["rounded-md px-1.5 py-0.5 text-[11px] font-bold", @class]}>
              {@label}
            </span>
            <span :if={@provider} class="ms-1.5 text-[11.5px] text-[#8a877f]">{@provider}</span>
            <p :if={@error} class="mt-1 max-w-[340px] text-[11.5px] leading-snug text-[#c0473d]">
              {@error}
            </p>
            """
          end
        end

        column :site do
          static true
          requires [:site_id, :site]
          label fn -> dgettext("mishka_gervaz", "Site") end
          visible fn state -> state.master_user? == true end

          render fn record ->
            assigns = %{
              site:
                case Map.get(record, :site) do
                  %{name: name} -> name
                  _installation -> dgettext("mishka_gervaz", "Installation")
                end
            }

            ~H"""
            <span class="text-[12.5px] text-[#5c5a54]">{@site}</span>
            """
          end
        end

        column :inserted_at do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Sent") end

          ui do
            type :datetime
          end
        end
      end

      filters do
        filter :search, :text, fields: [:recipient, :subject]

        filter :status, :select do
          options fn ->
            Enum.map(@statuses, &{MishkaCmsCore.Mail.status_label(&1), &1})
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end
      end

      pagination do
        type :load_more
        page_size 20
        page_size_options [20, 50, 100]

        ui do
          show_total true
          load_more_label dgettext_noop("mishka_gervaz", "Load more")
          page_info_format dgettext_noop("mishka_gervaz", "Showing {count} emails")
        end
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No email has been sent yet."),
                  icon: "hero-envelope"
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "System-internal: an email handed to `MishkaCmsCore.Mail.deliver/2`."
      accept [:site_id, :purpose, :recipient, :subject, :provider, :status, :error]
    end

    update :mark do
      description "System-internal: what the provider answered."
      accept [:status, :provider, :message_id, :error, :attempts]
      require_atomic? false
    end

    read :history do
      description "The emails a reader may see, newest first (the read policy picks the sites)."
      prepare build(sort: [inserted_at: :desc, id: :desc])

      pagination offset?: true,
                 keyset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :prunable do
      description "Rows older than the retention window."
      argument :before, :utc_datetime_usec, allow_nil?: false
      filter expr(inserted_at < ^arg(:before))
    end

    destroy :prune do
      description "System retention sweep (called `authorize?: false` from the worker)."
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:setting"]}
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :purpose, :string do
      allow_nil? false
      public? true

      description "What the email was for: `password_reset`, `magic_link`, `confirmation`, `test`…"
    end

    attribute :recipient, :string do
      allow_nil? false
      public? true
    end

    attribute :subject, :string do
      public? true
    end

    attribute :provider, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :queued
      public? true
      constraints one_of: @statuses
    end

    attribute :message_id, :string do
      public? true
      description "The provider's id for the message."
    end

    attribute :error, :string do
      public? true
      description "The provider's reason, cut short. Never a key."
    end

    attribute :attempts, :integer do
      default 0
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    # The `site_id` tenant attribute: the site the email was sent for, nil for the installation's own.
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      attribute_writable? true
      allow_nil? true
      public? true
    end
  end

  defp status_class(:sent), do: "bg-[#e6f6ee] text-[#177a53]"
  defp status_class(:queued), do: "bg-[#f2f1fc] text-[#4f4bcc]"
  defp status_class(:not_configured), do: "bg-[#fbf1df] text-[#a5691a]"
  defp status_class(_failed), do: "bg-[#fdf3f1] text-[#c0473d]"
end
