# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Validations.MasterUserCreation do
  @moduledoc """
  Signing up never makes a master.

  A user created with no tenant has no site, which makes them a master. The actions this runs on
  (`:register_with_password` and `:create`) refuse that to everyone, a master included: a new master
  is added by a master from the admin dashboard's Users table, which runs `:master_create` and its
  own master-only checks.

  A creation with a tenant makes a user of that site and passes, which is how a site takes
  registrations. A call made with `authorize?: false` passes too: that is how the installer makes the
  first master, before any master exists to ask.

  Each refusal is announced on `cms_core:user:master_creation_refused` with
  `%{action: action_name, actor_id: id | nil, email: email}`.

  Add it to every action that can create a user with no tenant, other than `:master_create`:

  ```elixir
  validate MishkaCmsCore.Accounts.Validations.MasterUserCreation, before_action?: true
  ```
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  @doc """
  Refuses a creation with no tenant.

  ## Returns
  - `:ok` for a site's user, and with `authorize?: false`
  - `{:error, field: :email, message: String.t()}` otherwise
  """
  def validate(_changeset, _opts, %{authorize?: false}), do: :ok

  def validate(%Ash.Changeset{tenant: nil} = changeset, _opts, context),
    do: refuse(changeset, context.actor)

  def validate(_changeset, _opts, _context), do: :ok

  defp refuse(changeset, actor) do
    MishkaInstaller.Event.Hook.call(
      "cms_core:user:master_creation_refused",
      %{action: changeset.action.name, actor_id: actor && actor.id, email: email(changeset)},
      return: false
    )

    {:error,
     field: :email,
     message:
       dgettext_noop(
         "errors",
         "Master accounts are added by a master from the admin dashboard."
       )}
  end

  defp email(changeset) do
    case Ash.Changeset.get_attribute(changeset, :email) ||
           Ash.Changeset.get_argument(changeset, :email) do
      nil -> nil
      email -> to_string(email)
    end
  end
end
