# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Notify.Producers.PermissionsChanged do
  @moduledoc """
  A plain mishka_installer plugin: when a user's permissions are replaced
  (`cms_core:user:after_assign_permissions`), notify that site's holders of the permission area
  (`admin:dashboard:permission`) AND every master holding it — a security-relevant change they
  should see. Registered in MishkaCmsCore.Application.

  Excludes both the admin who made the change (the notifier's `meta.actor`) and the affected user, so
  neither is told about a change they already know about. The pattern any extension follows: `use
  MishkaInstaller.Event.Hook` on the event `PluginHook.event_name/2` names, react in `call/2`, hand
  off to `MishkaCmsCore.Notify.deliver/3`, return `{:reply, record}`.
  """

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.event_name(MishkaCmsCore.Accounts.User, :assign_permissions),
    initial: %{priority: 40}

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Notify

  @impl true
  def call(user, meta) do
    actor = actor(meta)
    managers = "admin:dashboard:permission"

    Notify.deliver(
      %{
        type: "cms_core:user:permissions_changed",
        title: gettext_noop("User permissions updated"),
        body: gettext("%{email}'s permissions were changed.", email: user.email),
        icon: "hero-shield-check",
        link: "/admin/dashboard/account/users",
        source: "cms_core",
        metadata: %{"email" => to_string(user.email)}
      },
      tenant_permissions: managers,
      master_permissions: managers,
      site_id: user.site_id,
      actor: actor,
      except: Enum.reject([actor && actor.id, user.id], &is_nil/1)
    )

    {:reply, user}
  end

  defp actor(%{actor: %{} = actor}), do: actor
  defp actor(_), do: nil
end
