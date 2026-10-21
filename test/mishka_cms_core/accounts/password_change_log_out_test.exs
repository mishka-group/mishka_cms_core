# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.PasswordChangeLogOutTest do
  @moduledoc """
  A new password signs every other session of the account out once the write has committed, and
  keeps the device that made it signed in with a new token
  (`MishkaCmsCore.Accounts.Changes.LogOutEverywhereOnPasswordChange`); a password reset still
  succeeds, and a link sent before the change dies with the rest.

  AshAuthentication's own `apply_on_password_change?` revokes the tokens inside the write. The reset
  token is stored like a session's, so it goes with them, and the reset's own single-use revocation
  then fails with "token has already been revoked" (ash_authentication 5.0.0-rc.15). That option
  stays off; these tests hold both halves: the reset works, and every session is signed out.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias AshAuthentication.{Info, Jwt, Strategy}
  alias AshAuthentication.TokenResource.Actions, as: Tokens
  alias MishkaCmsCore.Accounts.{Token, User}

  @password "Password123!"
  @new_password "NewPassword456!"

  setup do
    site = create_site!(active: true)
    %{site: site, user: register!("owner@example.com", site.id)}
  end

  test "the library's own log-out on a password change stays off" do
    refute Info.strategy!(User, :log_out_everywhere).apply_on_password_change?,
           "with it on, every password reset fails: the reset token is revoked inside the write"
  end

  describe "a password reset" do
    test "succeeds, and signs every session of the account out", %{user: user} do
      session = signed_in!(user, @password)
      other = signed_in!(user, @password)

      assert {:ok, %User{} = reset} = reset(user, reset_token!(user), @new_password)

      assert revoked?(session)
      assert revoked?(other)
      # The device that reset it stays signed in: the token the reset hands back is a live one.
      assert live?(reset.__metadata__.token, user)
      assert {:ok, %User{}} = sign_in(user, @new_password)
      assert {:error, _refused} = sign_in(user, @password)
    end

    test "spends its link: the same one resets nothing again", %{user: user} do
      link = reset_token!(user)

      assert {:ok, %User{}} = reset(user, link, @new_password)
      assert {:error, _spent} = reset(user, link, "Another789!")
      assert {:ok, %User{}} = sign_in(user, @new_password)
    end
  end

  describe "changing the password" do
    test "signs every other session out, and keeps the device that changed it signed in", %{
      user: user
    } do
      session = signed_in!(user, @password)
      other = signed_in!(user, @password)

      assert {:ok, %User{} = changed} = change_password(user, @password, @new_password)

      assert revoked?(session)
      assert revoked?(other)
      assert live?(changed.__metadata__.token, user)
      assert {:ok, %User{}} = sign_in(user, @new_password)
    end

    test "kills a reset link sent before it", %{user: user} do
      link = reset_token!(user)

      assert {:ok, %User{}} = change_password(user, @password, @new_password)

      assert {:error, _dead} = reset(user, link, "Another789!")
      assert {:ok, %User{}} = sign_in(user, @new_password)
    end

    test "with a wrong current password, changes nothing and signs nobody out", %{user: user} do
      session = signed_in!(user, @password)

      assert {:error, _wrong} = change_password(user, "NotMyPassword1!", @new_password)

      refute revoked?(session)
      assert {:ok, %User{}} = sign_in(user, @password)
    end
  end

  describe "a password an admin sets" do
    test "signs every session of that account out", %{site: site, user: user} do
      admin = create_user_with_permissions!(["*"], site_id: site.id)
      session = signed_in!(user, @password)
      admins = signed_in!(admin, "Password123!")

      assert {:ok, %User{} = edited} =
               admin_update(user, admin, %{
                 password: @new_password,
                 password_confirmation: @new_password
               })

      assert revoked?(session)
      refute revoked?(admins)
      # The account gets no token: its owner did not sign in anywhere.
      refute Ash.Resource.get_metadata(edited, :token)
      assert {:ok, %User{}} = sign_in(user, @new_password)
    end

    test "an edit that leaves the password alone signs nobody out", %{site: site, user: user} do
      admin = create_user_with_permissions!(["*"], site_id: site.id)
      session = signed_in!(user, @password)

      assert {:ok, %User{}} = admin_update(user, admin, %{email: "renamed@example.com"})

      refute revoked?(session)
    end
  end

  describe "a first password" do
    test "set by an account that had none signs its sessions out", %{user: user} do
      passwordless = claim!(user)
      {:ok, session, _claims} = AshAuthentication.Jwt.token_for_user(passwordless)

      assert {:ok, %User{} = set} =
               passwordless
               |> fresh()
               |> Ash.Changeset.for_update(
                 :set_password,
                 %{password: @new_password, password_confirmation: @new_password},
                 actor: passwordless,
                 tenant: user.site_id
               )
               |> Ash.update()

      assert revoked?(session)
      assert live?(set.__metadata__.token, user)
      assert {:ok, %User{}} = sign_in(user, @new_password)
    end
  end

  test "every update that hashes a password signs sessions out after it" do
    listed =
      User
      |> Ash.Resource.Info.changes()
      |> Enum.find(
        &match?({MishkaCmsCore.Accounts.Changes.LogOutEverywhereOnPasswordChange, _}, &1.change)
      )
      |> Map.fetch!(:where)
      |> Enum.find_value(fn {Ash.Resource.Validation.ActionIs, opts} -> opts[:action] end)
      |> List.wrap()

    hashing =
      for %{type: :update, name: name, changes: changes} <- Ash.Resource.Info.actions(User),
          Enum.any?(changes, &hashes_password?/1),
          do: name

    assert hashing != []

    assert hashing -- listed == [],
           "add these to @password_actions in User: #{inspect(hashing -- listed)}"
  end

  defp hashes_password?(%{change: {AshAuthentication.Strategy.Password.HashPasswordChange, _}}),
    do: true

  defp hashes_password?(_change), do: false

  defp admin_update(user, admin, params) do
    user
    |> fresh()
    |> Ash.Changeset.for_update(:tenant_update, params, actor: admin, tenant: user.site_id)
    |> Ash.update()
  end

  # An account nobody confirmed, claimed by a provider: its password is gone.
  defp claim!(user) do
    user
    |> Ash.Changeset.for_update(:claim_unconfirmed, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.update!()
  end

  defp register!(email, site_id) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.Changeset.set_tenant(site_id)
    |> Ash.create!()
  end

  defp sign_in(user, password) do
    User
    |> Ash.Query.for_read(
      :sign_in_with_password,
      %{email: to_string(user.email), password: password},
      tenant: user.site_id
    )
    |> Ash.read_one()
  end

  defp signed_in!(user, password) do
    {:ok, %User{} = signed_in} = sign_in(user, password)
    signed_in.__metadata__.token
  end

  # The library's own reset link, stored as every token is (`store_all_tokens? true`).
  defp reset_token!(user) do
    {:ok, token} = User |> Info.strategy!(:password) |> Strategy.Password.reset_token_for(user)
    token
  end

  defp reset(user, token, password) do
    User
    |> Info.strategy!(:password)
    |> Strategy.action(
      :reset,
      %{"reset_token" => token, "password" => password, "password_confirmation" => password},
      tenant: user.site_id
    )
  end

  defp change_password(user, current, password) do
    user
    |> fresh()
    |> Ash.Changeset.for_update(
      :change_password,
      %{current_password: current, password: password, password_confirmation: password},
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update()
  end

  # The account as a request reads it: no token from an earlier sign-in rides along.
  defp fresh(user), do: Ash.get!(User, user.id, tenant: user.site_id, authorize?: false)

  defp revoked?(token), do: Tokens.token_revoked?(Token, token)

  defp live?(token, user) do
    match?({:ok, %{"sub" => _subject}, User}, Jwt.verify(token, User, tenant: user.site_id)) and
      not revoked?(token)
  end
end
