defmodule MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook do
  @moduledoc """
  A reusable Ash notifier that emits a MishkaInstaller plugin event after every action
  (`create` / `update` / `destroy`, including custom-named actions) on any resource it is added to.

  Add it to a resource's notifier list — and because it lives in `mishka_cms_core` (a dependency of
  every extension), all extensions share the exact same hook mechanism:

      use Ash.Resource,
        ...,
        notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  It fires `"<app>:<resource>:after_<action>"` — e.g. `"blog:comment:after_create"`,
  `"blog:post_rating:after_remove"`, `"document:section:after_update"` — handing the resulting record
  to plugins, plus a read-only `meta: %{actor:, site_id:}`.

  A plugin that listens on one of these names its event with `event_name/2` rather than spelling the
  string, so the name it listens on is the name fired:

      use MishkaInstaller.Event.Hook,
        event: PluginHook.event_name(MishkaBlog.BlogPost, :publish)

  One event is one action. A master user runs the action's `master_*` twin, which fires its own
  event (`"blog:blog_post:after_master_publish"`), so reacting to both takes a plugin on each.

  ## After any save

  A `create` or `update` action — whatever its name, a master's twin included — also fires
  `"<app>:<resource>:after_save"` (`save_event_name/1`), after its own event, with the same record
  and `meta`. A plugin that reacts to the record being written, however it was written, listens
  there once:

      use MishkaInstaller.Event.Hook, event: PluginHook.save_event_name(MishkaBlog.BlogPost)

  Because notifiers run **after the transaction commits**, the action stays **atomic** — adding this
  changes no authorization or atomicity behaviour (no `require_atomic? false`, no 403→404). This is why
  it works uniformly for `destroy` actions too.

  For `before`/reject seams (which a notifier cannot do), use a `before_action` change on the specific
  action instead. See `MishkaInstaller.Event.Hook`.
  """
  @behaviour Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: resource,
        action: action,
        data: record,
        actor: actor,
        changeset: changeset
      }) do
    meta = %{actor: actor, site_id: tenant(changeset)}

    MishkaInstaller.Event.Hook.call(event_name(resource, action.name), record,
      meta: meta,
      return: false
    )

    if action.type in [:create, :update] do
      MishkaInstaller.Event.Hook.call(save_event_name(resource), record,
        meta: meta,
        return: false
      )
    end

    :ok
  end

  # Never require original data: requesting it forces a pre-action load, which makes the action
  # non-atomic (and flips an unauthorized destroy from 403 to 404). The notification already carries
  # the acted-on record in `data`, which is what plugins need.
  @impl true
  def requires_original_data?(_resource, _action), do: false

  @doc """
  The event this notifier fires when `action_name` runs on `resource`:
  `event_name(MishkaBlog.BlogPost, :publish)` is `"blog:blog_post:after_publish"`.
  """
  @spec event_name(module(), atom()) :: String.t()
  def event_name(resource, action_name) do
    segments = Module.split(resource)
    app = segments |> List.first() |> Macro.underscore() |> String.replace_prefix("mishka_", "")
    res = segments |> List.last() |> Macro.underscore()
    "#{app}:#{res}:after_#{action_name}"
  end

  @doc """
  The event fired after any `create` or `update` action on `resource`:
  `save_event_name(MishkaBlog.BlogPost)` is `"blog:blog_post:after_save"`.
  """
  @spec save_event_name(module()) :: String.t()
  def save_event_name(resource), do: event_name(resource, :save)

  defp tenant(%{tenant: tenant}), do: tenant
  defp tenant(_), do: nil
end
