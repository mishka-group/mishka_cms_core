defmodule MishkaCmsCore.Accounts.Changes.EnforceMasterEmailSeparation do
  @moduledoc """
  Refuses a master an address a site's account already holds.

  A user created with no site is a master. Such a creation is refused, with the address in the
  error, when any site's account holds that email.

  A site's own registration is not checked against the master accounts. A site signs in, resets and
  registers only its own accounts, so on a site a master's address is one nobody there holds and
  registers as one; refusing it would tell a stranger on that site that a master holds it.

  The check runs as a before-action hook, with `Ash.exists?/2`, so it reads no account.

      change {MishkaCmsCore.Accounts.Changes.EnforceMasterEmailSeparation, []}
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  @doc """
  Adds the check to a creation that makes a master.

  ## Returns
  The changeset, with a before-action hook that adds an error on `:email` when a site's account
  holds the address of a master being created.
  """
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      email =
        Ash.Changeset.get_argument(changeset, :email) ||
          Ash.Changeset.get_attribute(changeset, :email)

      site_id = Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant

      if is_nil(site_id),
        do: check_no_tenant_users_exist(changeset, email),
        else: changeset
    end)
  end

  # Ensures no site-specific users exist with the given email when creating a master user.
  # Returns error if any site user with this email already exists.
  defp check_no_tenant_users_exist(changeset, email) do
    MishkaCmsCore.Accounts.User
    |> Ash.Query.filter(email == ^email and not is_nil(site_id))
    |> Ash.exists?(authorize?: false)
    |> case do
      true ->
        refuse(
          changeset,
          email,
          dgettext_noop("errors", "This email exists and cannot be used as a master account")
        )

      false ->
        changeset
    end
  end

  # THE ADDRESS IS THE WHOLE OF WHAT THIS REFUSAL IS ABOUT, so it goes in the error.
  # `Ash.Error.Changes.InvalidAttribute` renders whatever `:value` holds under the message, and
  # leaving it out did not leave it out — it printed "Value: nil" beneath a message about an email
  # that was not nil, which read as a bug in the reader rather than a collision, and named no
  # account for whoever had to go and find it. A seed run refused by this is the case that showed it.
  defp refuse(changeset, email, message) do
    Ash.Changeset.add_error(changeset, field: :email, value: email, message: message)
  end
end
