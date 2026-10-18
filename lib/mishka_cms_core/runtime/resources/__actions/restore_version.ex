# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Actions.RestoreVersion do
  @moduledoc """
  The body of a versioned resource's `:restore_version_api` (a site's own call) and
  `:master_restore_version` (a master's) generic actions: read the record, refuse what may not be
  restored, check that the version is one of THIS record's, and run the resource's `:restore_version`
  update with the record's own site as the tenant.

  The outer action is authorized by the resource's policies; the reads and the update here run as
  the system, so the checks below are the whole of what stands between a caller and the record.

  ## Options

    * `:resource` and `:version` — the resource and its AshPaperTrail version resource. The version
      resource must have a `:get_any` read, and the resource a `:restore_version` update.
    * `:read` — the read action that finds the record: `:read` for a site's call, `:master_get` for a
      master's, `:get_any` for a resource that may be global.
    * `:tenant_read?` — read in the tenant of `SiteWithGlobals.acting_site/1` (a site's call on a
      resource that is never global).
    * `:global?` — a site's call on a resource that may be global: a global record is not found by a
      caller with no site, and may not be restored by a site (`:global` words the refusal).
    * `:archived` and `:foreign` — the refusals for an archived record and for a version of another
      record, written with `dgettext_noop("errors", …)` where the action is declared.

  A call with no site, or on another site's record, finds nothing.
  """
  use Ash.Resource.Actions.Implementation

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

  @impl true
  def run(input, opts, context) do
    %{id: id, version_id: version_id} = input.arguments
    site = if opts[:tenant_read?] || opts[:global?], do: SiteWithGlobals.acting_site(context)

    case read(opts, id, site) do
      {:ok, record} when not is_nil(record) -> restorable(record, id, version_id, opts, site)
      _missing -> {:error, NotFound.exception(resource: opts[:resource])}
    end
  end

  defp read(opts, id, site) do
    read_opts = [action: opts[:read], authorize?: false]

    read_opts =
      if opts[:tenant_read?], do: Keyword.put(read_opts, :tenant, site), else: read_opts

    Ash.get(opts[:resource], id, read_opts)
  end

  defp restorable(record, id, version_id, opts, site) do
    global? = Keyword.get(opts, :global?, false)

    cond do
      global? and not reachable?(record, site) ->
        {:error, NotFound.exception(resource: opts[:resource])}

      global? and not own?(record, site) ->
        {:error, invalid(:site_id, opts[:global])}

      not is_nil(record.archived_at) ->
        {:error, invalid(:archived_at, opts[:archived])}

      true ->
        restore(record, id, version_id, opts)
    end
  end

  defp restore(record, id, version_id, opts) do
    case Ash.get(opts[:version], version_id, action: :get_any, authorize?: false) do
      {:ok, version} when not is_nil(version) ->
        if version.version_source_id == id do
          record
          |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
            tenant: record.site_id,
            authorize?: false
          )
          |> Ash.update()
        else
          {:error, invalid(:version_id, opts[:foreign])}
        end

      _missing ->
        {:error, NotFound.exception(resource: opts[:version])}
    end
  end

  defp reachable?(_record, nil), do: false
  defp reachable?(%{site_id: nil}, _site), do: true
  defp reachable?(%{site_id: site}, site), do: true
  defp reachable?(_record, _site), do: false

  defp own?(_record, nil), do: false
  defp own?(%{site_id: nil}, _site), do: false
  defp own?(%{site_id: site}, site), do: true
  defp own?(_record, _site), do: false

  defp invalid(field, message),
    do: Invalid.exception(errors: [InvalidAttribute.exception(field: field, message: message)])
end
