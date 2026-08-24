defmodule MishkaCmsCore.Accounts.Changes.RequireCurrentCode do
  @moduledoc """
  Asks the action's `:code` argument to be a current code from an authenticator app before the
  write, and spends it (`MishkaCmsCore.Accounts.SecondFactor.use_code/3`): the account's own with
  `of: :account`, the default, or the admin's running the action with `of: :actor` — who then has to
  have set one up for their own account first. A refusal is
  `MishkaCmsCore.Accounts.SecondFactor.Needed`, or the rate limiter's.

      change MishkaCmsCore.Accounts.Changes.RequireCurrentCode
      change {MishkaCmsCore.Accounts.Changes.RequireCurrentCode, of: :actor}
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Accounts.SecondFactor

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      code = Ash.Changeset.get_argument(changeset, :code)

      case check(opts[:of] || :account, changeset, context.actor, code) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp check(:account, changeset, _actor, code),
    do: SecondFactor.use_code(changeset.data, code, changeset.tenant)

  defp check(:actor, _changeset, actor, code), do: SecondFactor.step_up(actor, code)
end
