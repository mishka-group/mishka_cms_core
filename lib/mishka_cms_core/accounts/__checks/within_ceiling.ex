defmodule MishkaCmsCore.Accounts.Checks.WithinCeiling do
  @moduledoc """
  True when what an action changes holds nothing beyond what the actor holds — the grant ceiling
  (`MishkaCmsCore.Accounts.Validations.GrantWithinActorScope`) asked of the account or the row an
  action changes, by the same covering rule (`MishkaCmsCore.Accounts.Checks.AccessPermissions.beyond/2`).

    * An account (`MishkaCmsCore.Accounts.User`): every permission it holds, when the action deletes
      it or changes its email, its password, its authenticator or its site — what signing in as it
      takes, and where it belongs. A generic action names the account by its `:id` argument, and deletes it when it is
      given nothing else. Changing only what the account holds is a grant, held to the grant ceiling
      instead; anything else asks nothing.
    * A catalogue row (`MishkaCmsCore.Accounts.Permission`): the name a destroy removes, and both
      names of a rename, which every holder of the row loses and gains. A create names what nobody
      holds yet, and an update that keeps the name changes no name.
    * A grant row (`MishkaCmsCore.Accounts.UserPermission`) written directly: the permission it
      grants. Removing one grants nothing, as `remove_permission` does not.

  False for no actor. It only ever narrows a gate: put it beside the checks that authorize, since a
  policy passing on it alone would authorize whatever no other policy asks about.

      policy action(:tenant_update) do
        forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions, permissions: ["admin:dashboard:user", "admin:api:user"]}
        forbid_unless MishkaCmsCore.Accounts.Checks.WithinCeiling
        authorize_if expr(site_id == ^actor(:site_id))
      end
  """
  use Ash.Policy.SimpleCheck

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.{Helper, Permission, User, UserPermission}

  @sign_in_attributes [:email, :hashed_password, :totp_secret, :site_id]
  @sign_in_arguments [:email, :password, :site_id]

  @impl Ash.Policy.Check
  def describe(_opts), do: "What the action changes holds nothing beyond what the actor holds"

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{subject: subject}, _opts),
    do: AccessPermissions.beyond(actor, changed(subject)) == []

  def match?(_actor, _context, _opts), do: false

  defp changed(%Ash.Changeset{resource: User, action_type: :destroy, data: %{id: id}}),
    do: Helper.permission_names(id)

  defp changed(%Ash.Changeset{resource: User, action_type: :update, data: %{id: id}} = changeset) do
    if Enum.any?(@sign_in_attributes, &Ash.Changeset.changing_attribute?(changeset, &1)),
      do: Helper.permission_names(id),
      else: []
  end

  defp changed(%Ash.ActionInput{resource: User, arguments: arguments}) do
    case Map.pop(arguments, :id) do
      {id, rest} when is_binary(id) and map_size(rest) == 0 ->
        Helper.permission_names(id)

      {id, rest} when is_binary(id) ->
        if Enum.any?(@sign_in_arguments, &Map.has_key?(rest, &1)),
          do: Helper.permission_names(id),
          else: []

      _no_account ->
        []
    end
  end

  defp changed(%Ash.Changeset{resource: Permission, action_type: :update} = changeset) do
    case {changeset.data.name, Ash.Changeset.get_attribute(changeset, :name)} do
      {same, same} -> []
      {old, new} -> [old, new]
    end
  end

  defp changed(%Ash.Changeset{resource: Permission, action_type: :destroy, data: %{name: name}}),
    do: [name]

  defp changed(%Ash.Changeset{resource: UserPermission, action_type: :create} = changeset) do
    case Ash.Changeset.get_attribute(changeset, :permission_id) do
      id when is_binary(id) -> Helper.names_of([id])
      _none -> []
    end
  end

  defp changed(_subject), do: []
end
