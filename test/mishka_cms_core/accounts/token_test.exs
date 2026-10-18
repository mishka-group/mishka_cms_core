# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.TokenTest do
  @moduledoc """
  The ways this application revokes a token, and what each says when the revocation fails.

  A caller that answers "logged out" has to know whether the token still works, so each of
  `Token.revoke/1`, `Token.revoke_unissued/1` and `Token.revoke_minted/1` answers `:ok` or
  `{:error, error}` and never raises; the two for a token that was never handed out log a failure,
  and the log names the errors and never the token.

  A failure is made real by taking the tokens table away inside the test's own transaction (DDL is
  transactional in PostgreSQL), so the revocation hits a database error.

  `async: false` — the table is renamed.
  """
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Accounts.{Token, User}

  require Ash.Query

  @moduletag :integration

  @password "Password123!"

  setup do
    site = create_site!(active: true)

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "token-#{System.unique_integer([:positive])}@example.com",
          password: @password,
          password_confirmation: @password
        },
        tenant: site.id,
        context: %{private: %{ash_authentication?: true}}
      )
      |> Ash.create()

    %{site: site, user: user}
  end

  # A user as AshAuthentication hands one back from a password sign-in: with the token it signed,
  # stored, and not yet given to anybody.
  defp signed_in(user) do
    {:ok, signed_in} =
      User
      |> Ash.Query.for_read(
        :sign_in_with_password,
        %{email: to_string(user.email), password: @password},
        tenant: user.site_id,
        context: %{private: %{ash_authentication?: true}}
      )
      |> Ash.read_one()

    signed_in
  end

  defp purposes(user) do
    subject = "user?id=#{user.id}"

    Token
    |> Ash.Query.filter(subject == ^subject)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.purpose)
    |> Enum.frequencies()
  end

  defp take_tokens_away!,
    do: MishkaCmsCore.Repo.query!("ALTER TABLE tokens RENAME TO tokens_taken")

  describe "revoked/1" do
    test "says false for a token that works, and true once it has been revoked", %{user: user} do
      token = user |> signed_in() |> Ash.Resource.get_metadata(:token)

      assert Token.revoked(token) == {:ok, false}
      assert Token.revoke(token) == :ok
      assert Token.revoked(token) == {:ok, true}
    end

    test "is an error, not 'revoked', when the revocation list cannot be read", %{user: user} do
      token = user |> signed_in() |> Ash.Resource.get_metadata(:token)
      take_tokens_away!()

      assert {:error, _unreadable} = Token.revoked(token)
    end
  end

  describe "revoke/1" do
    test "revokes a token this application signed, and the token stops verifying", %{user: user} do
      token = signed_in(user).__metadata__.token

      assert {:ok, _claims, User} =
               AshAuthentication.Jwt.verify(token, User, tenant: user.site_id)

      assert Token.revoke(token) == :ok

      assert AshAuthentication.Jwt.verify(token, User, tenant: user.site_id) == :error
      assert Map.get(purposes(user), "revocation", 0) >= 1
    end

    test "answers an error, not a raise, for a string that is not a token" do
      assert {:error, _error} = Token.revoke("not-a-token")
    end

    test "answers an error, not a raise, when the database cannot be written", %{user: user} do
      token = signed_in(user).__metadata__.token
      take_tokens_away!()

      assert {:error, _error} = Token.revoke(token)
    end
  end

  describe "revoke_unissued/1" do
    test "revokes a token that was never handed out", %{user: user} do
      token = signed_in(user).__metadata__.token

      assert Token.revoke_unissued(token) == :ok
      assert AshAuthentication.Jwt.verify(token, User, tenant: user.site_id) == :error
    end

    test "logs a failure and answers the error, and the log does not hold the token", %{
      user: user
    } do
      token = signed_in(user).__metadata__.token
      take_tokens_away!()

      log =
        capture_log(fn ->
          assert {:error, _error} = Token.revoke_unissued(token)
        end)

      assert log =~ "could not be revoked"
      refute log =~ token
      refute log =~ user.id
    end
  end

  describe "revoke_minted/1" do
    test "revokes the token on the user's metadata", %{user: user} do
      signed_in = signed_in(user)
      token = signed_in.__metadata__.token

      assert Token.revoke_minted(signed_in) == :ok
      assert AshAuthentication.Jwt.verify(token, User, tenant: user.site_id) == :error
    end

    test "is :ok for a user that carries none", %{user: user} do
      assert Token.revoke_minted(user) == :ok
    end

    test "logs a failure and answers the error", %{user: user} do
      signed_in = signed_in(user)
      take_tokens_away!()

      log =
        capture_log(fn ->
          assert {:error, _error} = Token.revoke_minted(signed_in)
        end)

      assert log =~ "could not be revoked"
      refute log =~ signed_in.__metadata__.token
    end
  end

  describe "failure/1" do
    test "names the modules of the errors and nothing of their values" do
      error = %Ash.Error.Unknown{
        errors: [Ash.Error.Unknown.UnknownError.exception(error: "eyJsecret.token.value")]
      }

      assert Token.failure(error) == "Ash.Error.Unknown.UnknownError"
      refute Token.failure(error) =~ "eyJ"
    end

    test "has a sentence for anything else" do
      assert Token.failure(:timeout) == "an unexpected error"
      assert Token.failure("eyJsecret") == "an unexpected error"
    end
  end
end
