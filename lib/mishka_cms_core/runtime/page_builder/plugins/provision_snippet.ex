# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ProvisionSnippet do
  @moduledoc """
  Saves the snippet an extension ships into the editor's Studio list when a site is set up, on
  `runtime:provision:snippets` (`MishkaCmsCore.Runtime.ExtensionProvision`, which describes the
  payload as `t:MishkaCmsCore.Runtime.ExtensionProvision.snippet_payload/0`).

  NOTHING IS EVER UPDATED, as in the rest of a provision: a site that already holds the snippet keeps
  its row, edited or not, and the name is not reported.

  A REFUSED WRITE COMES BACK AS `error`, never as a raise. A plugin that raises is skipped and the
  event answers the payload it was given, so a raise here would read as "nothing to install" and the
  admin would never hear that their snippet was refused. The run raises with the reason instead.

  It writes for whoever runs the provision, as the pages beside it are written: nobody (the seeds,
  the install wizard) writes as the system, a master through the master action with the site named,
  and a site admin through their own site's action under its tenant.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:provision:snippets", initial: %{priority: 50}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Snippet

  # A payload an earlier plugin already failed is handed on as it is: the first refusal is the one
  # the admin is told about.
  @impl true
  def call(%{error: nil, snippet: %{name: name, source: source}, site_id: site_id} = payload) do
    actor = Map.get(payload, :actor)

    case saved?(name, site_id, actor) do
      {:ok, true} ->
        {:reply, payload}

      {:ok, false} ->
        case create(%{name: name, source: source, site_id: site_id}, actor) do
          {:ok, _snippet} -> {:reply, %{payload | installed: payload.installed ++ [name]}}
          {:error, reason} -> {:reply, %{payload | error: reason}}
        end

      {:error, reason} ->
        {:reply, %{payload | error: reason}}
    end
  rescue
    error -> {:reply, %{payload | error: error}}
  end

  def call(payload), do: {:reply, payload}

  # SECTION `:page`, and only that one. A live component runs on a page and nowhere else — see
  # `MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement` — so offering one in the layout
  # or error-page editor would offer markup those editors are forbidden to save. And `:shared`, so
  # every page of the site offers it, not only the document it came out of: it came out of none.
  defp create(attrs, actor) do
    attrs = Map.merge(attrs, %{section: :page, scope: :shared})

    Snippet
    |> changeset(attrs, actor)
    |> Ash.create()
  end

  # THE SAME THREE ANSWERS `ExtensionProvision` GIVES A PAGE, for the resource beside it.
  defp changeset(resource, attrs, nil),
    do: Ash.Changeset.for_create(resource, :master_create, attrs, authorize?: false)

  defp changeset(resource, attrs, %{site_id: nil} = actor),
    do: Ash.Changeset.for_create(resource, :master_create, attrs, actor: actor)

  defp changeset(resource, %{site_id: site_id} = attrs, actor) do
    Ash.Changeset.for_create(resource, :create, Map.delete(attrs, :site_id),
      actor: actor,
      tenant: site_id
    )
  end

  # THE ROW THE CREATE WOULD WRITE, AND NOTHING WIDER. `Snippet`'s `unique_name_per_scope` is
  # `[:name, :site_id, :section, :document_id]` with `nils_distinct? false`, so `document_id` is part
  # of what makes the name taken: a snippet an author saved out of one page's editor under this same
  # name holds a different key entirely. Reading without it, a site that has such a row is reported
  # as already having this one and never gets it.
  #
  # A PAGE OF ONE, so the read works whether the action paginates by keyset, by offset, or not at all.
  defp saved?(name, site_id, actor) do
    Snippet
    |> Ash.Query.for_read(:read_any, %{}, reading(actor))
    |> Ash.Query.filter(
      name == ^name and section == :page and site_id == ^site_id and is_nil(document_id)
    )
    |> Ash.Query.select([:id])
    |> Ash.read(reading(actor) ++ [page: [limit: 1]])
    |> case do
      {:ok, %{results: found}} -> {:ok, found != []}
      {:ok, found} when is_list(found) -> {:ok, found != []}
      {:error, reason} -> {:error, reason}
    end
  end

  # The read action does not change with the actor while the write action does — see
  # `MishkaCmsCore.Runtime.PageProvision`'s own `reading/1`.
  defp reading(nil), do: [authorize?: false]
  defp reading(actor), do: [actor: actor]
end
