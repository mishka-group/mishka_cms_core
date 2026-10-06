defmodule MishkaCmsCore.Accounts.Checks.ChangesPermissions do
  @moduledoc """
  True when an account action would change which permissions the account holds, through its
  `permission_ids` argument.

    * A create changes them when `permission_ids` names any permission.
    * An update or a generic action (its `:id` argument names the account) changes them when
      `permission_ids` is given and differs from what the account holds now. An argument left out,
      or the account's own permissions sent back unchanged — as the account form does — changes
      nothing.

  A policy condition, so a gate asked only of a grant sits beside the one every edit asks:

      policy [action([:tenant_create, :tenant_update]), MishkaCmsCore.Accounts.Checks.ChangesPermissions] do
        authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, permissions: ["admin:dashboard:permission", "admin:api:permission"]}
      end
  """
  use Ash.Policy.SimpleCheck

  alias MishkaCmsCore.Accounts.Helper

  @impl Ash.Policy.Check
  def describe(_opts), do: "The action changes which permissions the account holds"

  @impl Ash.Policy.SimpleCheck
  def match?(_actor, %{subject: subject}, _opts), do: changes?(subject)
  def match?(_actor, _context, _opts), do: false

  defp changes?(%Ash.Changeset{action_type: :create} = changeset),
    do: requested(Ash.Changeset.get_argument(changeset, :permission_ids)) not in [nil, []]

  defp changes?(%Ash.Changeset{action_type: :update, data: %{id: id}} = changeset),
    do: differs?(Ash.Changeset.get_argument(changeset, :permission_ids), id)

  defp changes?(%Ash.ActionInput{} = input),
    do:
      differs?(
        Ash.ActionInput.get_argument(input, :permission_ids),
        Ash.ActionInput.get_argument(input, :id)
      )

  defp changes?(_subject), do: false

  defp differs?(ids, user_id) do
    case requested(ids) do
      nil -> false
      wanted -> MapSet.new(wanted) != Helper.permission_ids(user_id)
    end
  end

  defp requested(ids) when is_list(ids), do: Enum.map(ids, &to_string/1)
  defp requested(_none), do: nil
end
