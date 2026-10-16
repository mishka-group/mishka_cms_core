# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation do
  @moduledoc """
  Refuses a write that names a record of another site.

  A row that points at a site's record — a bookmark at a post, a follow at a blogger, a comment at
  an issue — may only point at a record of the site the write is made for: the tenant, or the
  actor's own site when there is no tenant. A resource with no multitenancy of its own, such as
  `MishkaBlog.PostBookmark`, has nothing else that says so.

  A site user writes for its own site only. Naming another site as the tenant is refused, the same
  way, whatever record the write names: the tenant is not the site user's to choose. A master (a
  user whose `site_id` is nil) writes for whichever site it names as the tenant, and a visitor with
  no actor for the site it is visiting.

  A record of another site and a record that does not exist are refused with the same error, so the
  answer does not tell a caller which ids exist elsewhere. Each refusal is announced on
  `runtime:tenant:cross_site_refused` with `%{resource: resource, field: field, id: id, tenant:
  tenant, actor_id: actor_id}`.

  A write with neither a tenant nor an actor's site passes only for a master admin: a master who is
  an admin of the surface the write came from (`MishkaCmsCore.Accounts.Helper.master_admin?/2`, with
  `MishkaCmsCore.Accounts.Checks.AccessPermissions.surface/1`). Anyone else is refused the same way —
  a master with no admin permission of that surface, a visitor, an actor with no `site_id`. Nothing
  is checked for a call made with `authorize?: false`.

  ## Usage

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id,
                resource: MishkaDocument.Section,
                message: "Section not found or does not belong to your site."}

  ## Options

  * `:field` - Required. The attribute holding the id of the record.
  * `:resource` - Required. The Ash resource that record belongs to. It must have a `site_id`.
  * `:message` - Optional. The error message. Defaults to "{Resource} not found or does not belong
    to your site (field: {field})".
  * `:optional` - Optional. When true, a `nil` id passes. Defaults to true.

  The record is read with the first of `:read_any`, `:master_read` and `:read` the resource has,
  so a resource that is multitenant needs one of the first two.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def init(opts) do
    case {Keyword.fetch(opts, :field), Keyword.fetch(opts, :resource)} do
      {{:ok, field}, {:ok, resource}} ->
        {:ok,
         [
           field: field,
           resource: resource,
           message: Keyword.get(opts, :message),
           optional: Keyword.get(opts, :optional, true)
         ]}

      {:error, _} ->
        {:error, "field is required"}

      {_, :error} ->
        {:error, "resource is required"}
    end
  end

  @impl true
  def validate(_changeset, _opts, %{authorize?: false}), do: :ok

  @impl true
  def validate(changeset, opts, context) do
    field = opts[:field]
    resource_module = opts[:resource]
    optional? = opts[:optional]

    resource_id = Ash.Changeset.get_attribute(changeset, field)

    # Get tenant from either context.tenant or actor.site_id
    tenant = get_tenant_id(context)

    cond do
      # A site user writes for its own site only, whatever it names
      another_sites_tenant?(context) ->
        answer(false, changeset, opts, %{id: resource_id, tenant: tenant, actor: context.actor})

      # If field is nil and validation is optional, pass
      is_nil(resource_id) and optional? ->
        :ok

      # Without a site to hold the record to, only a master admin may name any site's record
      is_nil(tenant) ->
        context.actor
        |> Helper.master_admin?(AccessPermissions.surface(changeset))
        |> answer(changeset, opts, %{id: resource_id, tenant: nil, actor: context.actor})

      # If field has value and there's a tenant, validate it belongs to tenant
      resource_id && tenant ->
        resource_module
        |> belongs_to_tenant?(resource_id, tenant)
        |> answer(changeset, opts, %{id: resource_id, tenant: tenant, actor: context.actor})

      # Field is required but nil
      true ->
        {:error,
         field: field,
         message: dgettext("errors", "%{field} is required", field: to_string(field))}
    end
  end

  defp another_sites_tenant?(%{tenant: tenant, actor: %{site_id: site_id}})
       when is_binary(tenant) and is_binary(site_id),
       do: tenant != site_id

  defp another_sites_tenant?(_context), do: false

  # Get tenant ID from either context.tenant or actor.site_id
  defp get_tenant_id(context) do
    cond do
      # Standard tenant context (used in tenant actions)
      Map.has_key?(context, :tenant) && context.tenant ->
        context.tenant

      # Actor-based tenant (used when actor has site_id)
      Map.has_key?(context, :actor) && context.actor &&
        Map.has_key?(context.actor, :site_id) && context.actor.site_id ->
        context.actor.site_id

      # No tenant found
      true ->
        nil
    end
  end

  # Fetch the record bypassing multitenancy to compare its site_id with the tenant.
  defp belongs_to_tenant?(resource_module, resource_id, tenant) do
    read_action = get_bypass_read_action(resource_module)

    case Ash.get(resource_module, resource_id, action: read_action, authorize?: false) do
      {:ok, %{site_id: ^tenant}} -> true
      _elsewhere_or_missing -> false
    end
  end

  defp answer(true, _changeset, _opts, _refused), do: :ok

  defp answer(false, changeset, opts, refused) do
    MishkaInstaller.Event.Hook.call("runtime:tenant:cross_site_refused", %{
      resource: changeset.resource,
      field: opts[:field],
      id: refused.id,
      tenant: refused.tenant,
      actor_id: refused.actor && Map.get(refused.actor, :id)
    })

    case opts[:message] do
      message when message in [nil, false] ->
        {:error,
         field: opts[:field],
         message:
           dgettext(
             "errors",
             "%{resource} not found or does not belong to your site (field: %{field})",
             resource: resource_name(opts[:resource]),
             field: to_string(opts[:field])
           )}

      message ->
        {:error, field: opts[:field], message: message}
    end
  end

  # Get a read action that bypasses multitenancy
  # Most resources have :read_any for this purpose
  defp get_bypass_read_action(resource_module) do
    actions = Ash.Resource.Info.actions(resource_module)

    # Look for common bypass actions in order of preference
    cond do
      Enum.find(actions, &(&1.name == :read_any)) -> :read_any
      Enum.find(actions, &(&1.name == :master_read)) -> :master_read
      Enum.find(actions, &(&1.name == :read)) -> :read
      # fallback to default read
      true -> :read
    end
  end

  # Build a user-friendly error message from the resource module name
  defp resource_name(resource_module) do
    resource_module
    |> Module.split()
    |> List.last()
    |> to_string()
  end
end
