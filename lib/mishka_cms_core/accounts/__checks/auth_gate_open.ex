defmodule MishkaCmsCore.Accounts.Checks.AuthGateOpen do
  @moduledoc """
  Policy check: passes unless the way in named by `:action` — `:register` or `:reset` — is closed
  for whoever the action is for (`MishkaCmsCore.Accounts.AuthGate`). Put it on the action, above
  the AshAuthentication bypass, with the gate's refusal as the policy's error:

      policy action(:register_with_password) do
        error_message &MishkaCmsCore.Accounts.AuthGate.refused(&1, &2, :register)
        forbid_unless {MishkaCmsCore.Accounts.Checks.AuthGateOpen, action: :register}
        authorize_if always()
      end

  Registering is asked of the address it is for, resetting of the account being reset. Signing in
  is asked after the password instead (`AuthGate.prepare/3`), where the account is known.
  """

  use Ash.Policy.SimpleCheck

  alias MishkaCmsCore.Accounts.AuthGate

  @impl true
  def describe(opts), do: "#{Keyword.fetch!(opts, :action)} is open for whoever this is for"

  @impl true
  def match?(_actor, %{changeset: %Ash.Changeset{} = changeset}, opts),
    do:
      AuthGate.allowed?(Keyword.fetch!(opts, :action), changeset.tenant, AuthGate.who(changeset))

  def match?(_actor, _context, _opts), do: true
end
