# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SocialSignIn do
  @moduledoc """
  What a sign-in with a provider — Google, GitHub, Apple — may do, on each provider's register
  action on `MishkaCmsCore.Accounts.User`, beside AshAuthentication's own rules
  (`AshAuthentication.Strategy.OAuth2.IdentityChange`):

    * **The email has to be verified by the provider**, or nothing happens: an account is found, made
      and confirmed by that email, so one the provider did not vouch for proves nothing.
    * **A site's account**: the provider's identity, else the email, finds it. With none, one is
      made only while the site makes accounts this way (`SignInProvider.register?/1`), takes
      registrations (`AuthGate` `:register`) and is not offline. An account found is held to the
      site's sign-in gate (`AuthGate` `:sign_in`).
    * **A master** — the master site's sign-in page with `?master_user=true`, which leaves the
      request with no tenant: only a master's own identity, else a master's email, signs in. A
      master is never made this way, and the lookups never reach a site's accounts.
    * **An account nobody confirmed** is claimed by the provider's verified email: confirmed, its
      password, authenticator and recovery codes removed, and every session of it signed out
      (`:claim_unconfirmed`), before the sign-in. Whoever made it without confirming the email, with
      a password of their choosing, keeps nothing.

  An account made by a provider has no password; it can set one later (`:set_password`). Every
  account made or found here is confirmed: the provider's verified email is the confirmation.

  Refusals are `MishkaCmsCore.Accounts.SocialSignIn.Refused`, or the gate's own
  `MishkaCmsCore.Accounts.AuthGate.Closed`.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias Ash.Changeset
  alias AshAuthentication.{Info, Strategy.OAuth2, UserIdentity}
  alias MishkaCmsCore.Accounts.{AuthGate, LiveSockets, SignInProvider, User}
  alias MishkaCmsCore.Accounts.SocialSignIn.Refused
  alias MishkaCmsCore.Accounts.UserIdentity, as: Identity

  @impl true
  def change(changeset, _opts, _context) do
    user_info = Changeset.get_argument(changeset, :user_info) || %{}

    with {:ok, strategy} <- Info.strategy_for_action(User, changeset.action.name),
         {:ok, email} <- verified_email(user_info) do
      changeset
      |> site_of(changeset.tenant)
      |> Changeset.before_transaction(&decide(&1, strategy, email, user_info))
    else
      {:error, reason} -> Changeset.add_error(changeset, Refused.exception(reason: reason))
      :error -> Changeset.add_error(changeset, Refused.exception(reason: :unverified_email))
    end
  end

  @doc "What to tell whoever was refused, in their language."
  @spec describe(atom()) :: %{title: String.t(), text: String.t()}
  def describe(:unverified_email),
    do: %{
      title: gettext("That email is not verified"),
      text:
        gettext(
          "The service you signed in with did not confirm your email address. Verify it there, then try again."
        )
    }

  def describe(:no_account),
    do: %{
      title: gettext("No account with that email"),
      text:
        gettext(
          "This site does not make accounts this way. Create one first, or sign in another way."
        )
    }

  def describe(:no_master),
    do: %{
      title: gettext("No master account with that email"),
      text: gettext("Only an existing master account can sign in here this way.")
    }

  @doc """
  The refusal anywhere inside `reason` — an error, an error class, or AshAuthentication's
  `AuthenticationFailed` around one — or `nil`.
  """
  @spec refusal(term()) :: %{reason: atom()} | nil
  def refusal(%Refused{reason: reason}), do: %{reason: reason}
  def refusal(%{caused_by: cause}), do: refusal(cause)
  def refusal(%{errors: errors}) when is_list(errors), do: refusal(errors)
  def refusal(errors) when is_list(errors), do: Enum.find_value(errors, &refusal/1)
  def refusal(_other), do: nil

  defp verified_email(%{"email_verified" => verified} = user_info)
       when verified in [true, "true"] do
    case user_info |> Map.get("email") |> address() do
      nil -> {:error, :unverified_email}
      email -> {:ok, email}
    end
  end

  defp verified_email(_user_info), do: {:error, :unverified_email}

  # A site's account is made on the site the request reached, as `register_with_password` does.
  defp site_of(changeset, nil), do: changeset
  defp site_of(changeset, site_id), do: Changeset.change_attribute(changeset, :site_id, site_id)

  defp decide(%{tenant: nil} = changeset, strategy, email, user_info),
    do: master(changeset, strategy, email, user_info)

  defp decide(%{tenant: site_id} = changeset, strategy, email, user_info) do
    case account(strategy, uid(user_info), email, site_id) do
      nil -> new_account(changeset, email, site_id)
      user -> existing(changeset, user, site_id)
    end
  end

  defp new_account(changeset, email, site_id) do
    cond do
      not SignInProvider.register?(site_id) ->
        refuse(changeset, :no_account)

      MishkaCmsCore.Settings.offline?(site_id) ->
        refuse(changeset, :no_account)

      true ->
        case AuthGate.check([:sign_in, :register], site_id, %{email: email}) do
          :ok -> changeset
          {:error, closed} -> Changeset.add_error(changeset, closed)
        end
    end
  end

  defp existing(changeset, user, site_id) do
    case AuthGate.check([:sign_in], site_id, %{user: user}) do
      :ok -> claim(changeset, user)
      {:error, closed} -> Changeset.add_error(changeset, closed)
    end
  end

  # A MASTER IS FOUND AMONG MASTERS ONLY and is never made: the account the upsert writes is pinned
  # to the master found, and anything else rolls the sign-in back.
  defp master(changeset, strategy, email, user_info) do
    case master_account(strategy, uid(user_info), email) do
      nil ->
        refuse(changeset, :no_master)

      master ->
        changeset
        |> Changeset.force_change_attribute(:email, master.email)
        |> claim(master)
        |> Changeset.after_action(&linked(&1, &2, master, strategy))
    end
  end

  defp linked(changeset, %{id: id} = user, %{id: id}, strategy) do
    Identity
    |> UserIdentity.Actions.upsert(
      %{
        user_id: id,
        user_info: Changeset.get_argument(changeset, :user_info),
        oauth_tokens: Changeset.get_argument(changeset, :oauth_tokens),
        strategy: OAuth2.identity_strategy_name(strategy)
      },
      tenant: nil
    )
    |> case do
      {:ok, _identity} -> {:ok, user}
      {:error, error} -> {:error, error}
    end
  end

  defp linked(_changeset, _user, _master, _strategy),
    do: {:error, Refused.exception(reason: :no_master)}

  defp claim(changeset, %{confirmed_at: nil} = user) do
    user
    |> Changeset.for_update(:claim_unconfirmed, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, _claimed} ->
        LiveSockets.disconnect(user)
        changeset

      {:error, error} ->
        Changeset.add_error(changeset, error)
    end
  end

  defp claim(changeset, _confirmed), do: changeset

  defp refuse(changeset, reason),
    do: Changeset.add_error(changeset, Refused.exception(reason: reason))

  # The account a site's sign-in lands on: the one holding the provider's identity, else the one
  # holding the email.
  defp account(strategy, uid, email, site_id) do
    with nil <- identity_user(strategy, uid, site_id) do
      User
      |> Ash.Query.filter(email == ^email and site_id == ^site_id)
      |> read_one(site_id)
    end
  end

  defp master_account(strategy, uid, email) do
    with nil <- identity_user(strategy, uid, nil) do
      User
      |> Ash.Query.filter(email == ^email and is_nil(site_id))
      |> read_one(nil)
    end
  end

  defp identity_user(_strategy, nil, _site_id), do: nil

  defp identity_user(strategy, uid, site_id) do
    name = OAuth2.identity_strategy_name(strategy)

    Identity
    |> Ash.Query.filter(strategy == ^name and uid == ^uid)
    |> scoped(site_id)
    |> read_one(site_id)
    |> case do
      %{user_id: user_id} ->
        User
        |> Ash.Query.filter(id == ^user_id)
        |> scoped(site_id)
        |> read_one(site_id)

      nil ->
        nil
    end
  end

  defp scoped(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp scoped(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp read_one(query, site_id) do
    query
    |> Ash.Query.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.Query.limit(1)
    |> Ash.read(tenant: site_id, authorize?: false)
    |> case do
      {:ok, [record]} -> record
      _none -> nil
    end
  end

  defp uid(user_info), do: OAuth2.uid_from_user_info(user_info)

  defp address(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      email -> email
    end
  end

  defp address(_none), do: nil
end
