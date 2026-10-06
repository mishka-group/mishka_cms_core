defmodule MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook do
  @moduledoc """
  A reusable read `Preparation` that lets a plugin **adjust the query** before a read runs — the
  WordPress `pre_get_posts` / `posts_where`, Joomla `onContentSearch` seam.

  Add it to the read actions you want to make pluggable:

      read :published do
        prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
        ...
      end

  It hands the plugin the `Ash.Query` for `"<app>:<resource>:query_<action>"`; the plugin returns a
  modified `Ash.Query` (e.g. `Ash.Query.filter/2`, `Ash.Query.sort/2`). With no plugin registered, the
  query passes through untouched. Reads are not atomic, so this changes no authorization behaviour.

  > Reads run **per request** — keep plugins cheap and add only indexed filters/sorts; never break the
  > resource's base/tenant filters.

  See `MishkaInstaller.Event.Hook`.
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, context) do
    event = "#{prefix(query.resource)}:query_#{query.action.name}"
    meta = %{actor: context.actor, site_id: query.tenant}

    case MishkaInstaller.Event.Hook.call(event, query, meta: meta) do
      %Ash.Query{} = adjusted -> adjusted
      _ -> query
    end
  end

  defp prefix(resource) do
    segments = Module.split(resource)
    app = segments |> List.first() |> Macro.underscore() |> String.replace_prefix("mishka_", "")
    "#{app}:#{segments |> List.last() |> Macro.underscore()}"
  end
end
