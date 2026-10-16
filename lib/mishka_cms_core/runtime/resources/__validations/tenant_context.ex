# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.TenantContext do
  @moduledoc """
  Holds an action to the kind of caller it was written for: a master, or a site.

  A MASTER is a user whose `site_id` is nil (`MishkaCmsCore.Accounts.Helper.master_user?/1`).
  Nothing else makes one: not a missing actor, not an actor with no `site_id`, not a permission
  (`*` included), not the absence of a tenant.

  ## Options

  - `:require_master` - Required boolean.
    - `true`: the action is a master's. The actor must be a master and the tenant must be nil.
    - `false`: the action is a site's. A tenant must be given. A site user may give only its own
      site as the tenant; a master may give any site; a visitor with no actor acts on the site it
      is visiting.

  A call made with `authorize?: false` is a system call (the installer, seeds, workers, internal
  reads) and is not checked.

  The check reads the actor the changeset, query or action input was BUILT with. Build it with the
  actor that runs it: one built with no actor is refused a master action, whoever runs it later.
  Who may run an action is still the resource's policies' question; this only keeps each action to
  its own kind of caller. The policies ask the actor the action RUNS with, and
  `MishkaCmsCore.Accounts.Checks.AccessPermissions` gives a site user none of its permissions under
  another site's tenant or for a master's action (`requires_master?/2`), so an input built with
  another actor, or with none, still keeps a site user to its own site wherever a policy authorizes
  through that check.

  ## Usage

      alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

      create :master_create do
        validate {TenantContext, require_master: true}
      end

      create :create do
        validate {TenantContext, require_master: false}
      end

      action :master_update, :struct do
        validate {TenantContext, require_master: true}
      end

  ## Error messages

  - A master action given a tenant: "Tenant context must be nil for this action. Use the tenant
    action instead."
  - A master action run by anyone but a master: "This action requires a master user, an account
    that belongs to no site. Site users use the tenant action instead." For a site user it is an
    invalid-input error; for nobody (no actor, or one that is not a user) it is a forbidden error,
    as a policy refusal is.
  - A tenant action given no tenant: Ash's own `Ash.Error.Invalid.TenantRequired`, the error Ash
    gives any query or change that needs a tenant and has none. The JSON:API shows both as `400
    tenant_required`: "Tenant context is required for this action. Use the master action instead."
  - A tenant action run by a site user for another site: "A site user can act only on their own
    site.", a forbidden error.
  """
  alias MishkaCmsCore.Accounts.Helper

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  @doc """
  Initializes the validation with provided options.

  ## Parameters
  - `opts` - Keyword list containing:
    - `:require_master` - Boolean indicating if master context is required

  ## Returns
  - `{:ok, opts}` with validated options
  """
  def init(opts) do
    require_master = Keyword.get(opts, :require_master)

    if is_nil(require_master) do
      raise ArgumentError, "TenantContext validation requires :require_master option (true/false)"
    end

    if !is_boolean(require_master) do
      raise ArgumentError,
            ":require_master option must be a boolean, got: #{inspect(require_master)}"
    end

    {:ok, opts}
  end

  @impl true
  @doc """
  Validates tenant context based on the action requirements.

  ## Parameters
  - `subject` - The Ash changeset or action input being validated
  - `opts` - Validation options containing :require_master flag
  - `context` - Context containing tenant and authorization information

  ## Returns
  - `:ok` if validation passes
  - `{:error, message: String.t()}` if validation fails
  """
  def validate(_subject, _opts, %{authorize?: false}), do: :ok

  def validate(subject, opts, context) do
    case check_tenant_context(opts, context.tenant, context.actor) do
      :ok -> :ok
      :no_tenant -> {:error, no_tenant(subject)}
      {:error, message} -> {:error, message: message}
      {:forbidden, message} -> {:error, forbidden(message, subject)}
    end
  end

  @impl true
  def atomic(_changeset, _opts, %{authorize?: false}), do: :ok

  def atomic(changeset, opts, context) do
    case check_tenant_context(opts, context.tenant, context.actor) do
      :ok -> :ok
      :no_tenant -> {:error, no_tenant(changeset)}
      {:error, message} -> {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
      {:forbidden, message} -> {:error, forbidden(message, changeset)}
    end
  end

  defp no_tenant(%{resource: resource}),
    do: Ash.Error.Invalid.TenantRequired.exception(resource: resource)

  # REFUSED AS A POLICY REFUSES: a forbidden error, `403` over JSON:API, for nobody asking for a
  # master action and for a site user reaching another site — the answer a policy gave both before
  # this check caught them first. A site user asking for a master action is a caller at the wrong
  # action and keeps the invalid one.
  #
  # The error names the resource and the action it refused, as Ash's own policy errors do: its
  # message, and a policy breakdown shown or logged, are written from them.
  defp forbidden(message, %{resource: resource, action: action}),
    do:
      Ash.Error.Forbidden.Policy.exception(
        custom_message: message,
        resource: resource,
        action: action
      )

  defp check_tenant_context(opts, tenant, actor) do
    if Keyword.fetch!(opts, :require_master),
      do: master_context(tenant, actor),
      else: site_context(tenant, actor)
  end

  @not_master dgettext_noop(
                "errors",
                "This action requires a master user, an account that belongs to no site. Site users use the tenant action instead."
              )

  defp master_context(nil, actor) do
    cond do
      Helper.master_user?(actor) -> :ok
      site_user?(actor) -> {:error, @not_master}
      true -> {:forbidden, @not_master}
    end
  end

  defp master_context(_tenant, _actor),
    do:
      {:error,
       dgettext_noop(
         "errors",
         "Tenant context must be nil for this action. Use the tenant action instead."
       )}

  defp site_context(nil, _actor), do: :no_tenant

  defp site_context(tenant, %{site_id: site_id}) when is_binary(site_id) and site_id != tenant,
    do: {:forbidden, dgettext_noop("errors", "A site user can act only on their own site.")}

  defp site_context(_tenant, _actor), do: :ok

  defp site_user?(%{site_id: site_id}), do: is_binary(site_id)
  defp site_user?(_actor), do: false

  @doc """
  Whether `action` of `resource` is a master's: it declares this validation with
  `require_master: true`. Takes the action or its name; `nil` is no action.
  """
  @spec requires_master?(Ash.Resource.t(), atom() | struct() | nil) :: boolean()
  def requires_master?(resource, name) when is_atom(name) and not is_nil(name),
    do: requires_master?(resource, Ash.Resource.Info.action(resource, name))

  def requires_master?(_resource, %{} = action) do
    action
    |> Map.get(:changes, [])
    |> Enum.concat(Map.get(action, :preparations, []))
    |> Enum.any?(&master_requirement?/1)
  end

  def requires_master?(_resource, _action), do: false

  defp master_requirement?(%Ash.Resource.Validation{module: __MODULE__, opts: opts}),
    do: Keyword.get(opts, :require_master) == true

  defp master_requirement?(_change), do: false

  @impl true
  def has_validate?(), do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset, Ash.ActionInput, Ash.Query]
end
