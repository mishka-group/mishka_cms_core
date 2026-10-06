defmodule MishkaCmsCore.Runtime.Resources.Checks.SettingPermission do
  @moduledoc """
  Whether the actor holds what writing a setting takes: the `:permission` its definition declares,
  or `admin:dashboard:setting` when it declares none or no definition names the key
  (`MishkaCmsCore.Settings.write_permission/1`). Asked of the row's `key`, within the actor's own
  site as every `MishkaCmsCore.Accounts.Checks.AccessPermissions` check is.

      policy action_type([:create, :update, :destroy]) do
        authorize_if MishkaCmsCore.Runtime.Resources.Checks.SettingPermission
      end
  """
  use Ash.Policy.SimpleCheck

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Settings

  @impl Ash.Policy.Check
  def describe(_opts),
    do:
      "User holds the permission the setting declares, or the setting area when it declares none"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{subject: %Ash.Changeset{} = changeset} = context, _opts) do
    key = Ash.Changeset.get_attribute(changeset, :key)
    AccessPermissions.match?(actor, context, permissions: Settings.write_permission(key))
  end

  def match?(_actor, _context, _opts), do: false
end
