# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Notify do
  @moduledoc """
  The notification center domain — one Ash resource, per-user real-time, pluggable through
  `mishka_installer` events, and the single public API extensions learn.

  Producers call `deliver/3` (or react to the existing `<app>:<resource>:after_<action>`
  firehose with a tiny hook plugin); the audience is resolved and rows are fanned out
  (inline for small audiences, an Oban job for large ones). Consumers are the topbar bell
  (`MishkaCmsCore.Notify.LiveHooks`), the `/admin/dashboard/notifications` page, and optional
  channels (email, …).

  Which notification types a site receives is admin-managed: each type is a per-site boolean Setting
  (`setting_key/1`), registered via the `settings:register` hook and checked once per delivery
  (default on). There is no bespoke type registry — the Settings page is the single control surface.

  See `MishkaCmsCore.Notify.Notification` (data), `MishkaCmsCore.Notify.Delivery` (who + how),
  and `MishkaCmsCore.Settings` (the per-type toggles).
  """

  use Ash.Domain, otp_app: :mishka_cms_core, validate_config_inclusion?: false
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  resources do
    resource MishkaCmsCore.Notify.Notification do
      define :get_notification, action: :read, get_by: :id
    end
  end

  @user_pref_description gettext_noop(
                           "Turns this off for you only — everyone else still gets theirs."
                         )

  @doc """
  Marks every one of `user`'s unread notifications read, in one bulk update. No-op when signed out.
  Backs both the topbar bell's "Mark all read" and the inbox page's.
  """
  @spec mark_all_read(map() | nil) :: :ok
  def mark_all_read(nil), do: :ok

  def mark_all_read(user) do
    MishkaCmsCore.Notify.Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.Query.filter(is_nil(read_at))
    |> Ash.bulk_update(:mark_read, %{}, actor: user, tenant: user.site_id, return_errors?: true)

    :ok
  end

  @doc """
  Deliver a notification — the one call extensions learn. Producers use the plugin-friendly form
  (attrs first, audience as named opts):

      Notify.deliver(
        %{
          type: "blog:comment:created",
          title: "New comment awaiting moderation",
          link: "/admin/dashboard/blog/comments",
          source: "mishka_blog",
          metadata: %{"author" => comment.author_name}
        },
        tenant_permissions: "admin:dashboard:blog:comment",
        master_permissions: "admin:dashboard:blog:comment",
        site_id: comment.site_id,
        actor: comment.author
      )

  Small audiences are written inline; large / unbounded ones are streamed by an Oban job. See
  `MishkaCmsCore.Notify.Delivery` for both call forms, all audience opts, and `attrs`.
  """
  # Two explicit arities (not a defaulted one) so the arity-2 plugin form reaches
  # `Delivery.deliver/2` rather than being routed to `deliver/3` with a defaulted last arg.
  defdelegate deliver(attrs_or_audience, opts_or_attrs), to: MishkaCmsCore.Notify.Delivery
  defdelegate deliver(audience, attrs, opts), to: MishkaCmsCore.Notify.Delivery

  @doc """
  The Settings key that toggles a notification `type` on/off for a site (site-level, admin-managed).

  Extensions register a boolean Setting under this key via `settings:register` — it then appears as a
  normal toggle in the Settings page, and delivery checks it (default on). Colons become dots so the
  key is a clean settings/DOM id:

      Notify.setting_key("blog:post:published")  #=> "notify.blog.post.published"
  """
  def setting_key(type), do: "notify." <> String.replace(to_string(type), ":", ".")

  @doc """
  The per-USER preference key for a notification `type` (a `:user`-scoped Setting under
  Settings → Preferences). A recipient can turn their OWN copy of a type off without affecting the
  site toggle (`setting_key/1`) or anyone else; delivery honours it per recipient (default on).

      Notify.user_setting_key("blog:post:published")  #=> "notify.pref.blog.post.published"
  """
  def user_setting_key(type), do: "notify.pref." <> String.replace(to_string(type), ":", ".")

  @doc """
  The per-USER opt-out Setting definition for a notification `type` — a `:user`-scoped boolean
  (default on) under Settings → Preferences → Notifications. An extension registers this ALONGSIDE
  its own per-site toggle so a recipient can mute the type just for themselves. `description`
  defaults to the shared "only your own copy" wording every opt-out shares.

      Settings.define(...) # the site toggle (its own category)
      Notify.user_pref_definition("blog:post:published", "New posts published")
  """
  def user_pref_definition(type, label, description \\ @user_pref_description) do
    MishkaCmsCore.Settings.define(user_setting_key(type), :boolean,
      default: true,
      scope: :user,
      category: "preferences",
      group: gettext_noop("Notifications"),
      source: :plugin,
      label: label,
      description: description
    )
  end
end
