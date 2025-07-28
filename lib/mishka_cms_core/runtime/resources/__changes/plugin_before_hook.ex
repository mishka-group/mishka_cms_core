defmodule MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook do
  @moduledoc """
  A reusable `before_action` change that lets a plugin **transform or reject** an action before it runs
  (the WordPress `wp_insert_post_data` / `pre_comment_approved`, Joomla `onContentBeforeSave` seam).

  Add it to the actions you want to gate:

      create :create_public do
        change MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook
        ...
      end

  It hands the plugin the **changeset** for `"<app>:<resource>:before_<action>"`; the plugin returns the
  (possibly modified) changeset, or `Ash.Changeset.add_error(changeset, ...)` to reject. With no plugin
  registered, the changeset passes through untouched.

  > A `before_action` makes the action **non-atomic**. That is harmless on `create` actions, but on
  > `update`/`destroy` it flips an *unauthorized* request from 403 to 404 (the non-atomic path loads the
  > record first). So prefer it on creates + admin-only actions; rely on the after-notifier elsewhere.

  See `MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook` (after events) and `MishkaInstaller.Event.Hook`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    event = "#{prefix(changeset.resource)}:before_#{changeset.action.name}"
    meta = %{actor: context.actor, site_id: changeset.tenant}

    Ash.Changeset.before_action(changeset, fn changeset ->
      MishkaInstaller.Event.Hook.call(event, changeset, meta: meta)
    end)
  end

  defp prefix(resource) do
    segments = Module.split(resource)
    app = segments |> List.first() |> Macro.underscore() |> String.replace_prefix("mishka_", "")
    "#{app}:#{segments |> List.last() |> Macro.underscore()}"
  end
end
