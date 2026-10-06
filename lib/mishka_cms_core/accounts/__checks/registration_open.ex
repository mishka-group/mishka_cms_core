defmodule MishkaCmsCore.Accounts.Checks.RegistrationOpen do
  @moduledoc """
  Policy check: passes unless the action would create a new account on a site that is offline.

  Put it on the sign-up action, above the bypasses so that it is the first word:

      policy action(:register_with_password) do
        forbid_unless {MishkaCmsCore.Accounts.Checks.RegistrationOpen, []}
        authorize_if always()
      end

  Signing in is untouched. A site that is down still has to let its admin back in, so an account that
  already exists may authenticate by any means.

  ## Which site

  The changeset's tenant, which `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` sets from the request's
  host. With no tenant the global switch alone decides, so a master who has taken every site offline
  also closes registration for anything that reaches this without one.

  Who may create an account with no tenant — a master — is asked by
  `MishkaCmsCore.Accounts.Validations.MasterUserCreation`, on the action itself.

  See `MishkaCmsCore.Settings.offline?/1`.
  """

  use Ash.Policy.SimpleCheck

  alias MishkaCmsCore.Settings

  @impl true
  def describe(_opts), do: "the site is taking registrations"

  @impl true
  def match?(_actor, %{changeset: %Ash.Changeset{tenant: tenant}}, _opts),
    do: not Settings.offline?(tenant)

  def match?(_actor, _context, _opts), do: true
end
