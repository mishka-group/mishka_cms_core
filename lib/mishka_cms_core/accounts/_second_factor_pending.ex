# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SecondFactor.Pending do
  @moduledoc """
  The code step of a sign-in that could not ask for the code itself — one with a provider such as
  Google or GitHub.

  `MishkaCmsCoreWeb.AuthController` opens no session for an account with an authenticator. It hands
  the sign-in page `token/1` instead: AshAuthentication's own token, with the purpose
  `"second_factor"`, for that account, for five minutes, which is no bearer credential and signs
  nobody in. The page's code step sends it back with a code to `sign_in_with_second_factor`
  (`prepare/3`), where it is checked, spent, and exchanged for the short sign-in token the password
  sign-in hands out — the same route then opens the session.
  """

  use Ash.Resource.Preparation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias Ash.Query
  alias AshAuthentication.{Errors.AuthenticationFailed, Jwt, TokenResource}
  alias MishkaCmsCore.Accounts.{Token, User}

  @purpose "second_factor"
  @lifetime {5, :minutes}
  @sign_in_lifetime {60, :seconds}

  @doc "A token that names `user` as waiting for its code, for five minutes."
  @spec token(User.t()) :: {:ok, String.t()} | {:error, term()}
  def token(user) do
    case Jwt.token_for_user(user, %{},
           purpose: :second_factor,
           tenant: user.site_id,
           token_lifetime: @lifetime
         ) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  The preparation of `sign_in_with_second_factor`, before the code is asked: only the account the
  `token` argument names, while it is a live `"second_factor"` token of this site; and after the
  code passed, the token spent and a sign-in token on the account's `:token` metadata.
  """
  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Query.before_action(&named/1)
    |> Query.after_action(&exchanged/2)
  end

  defp named(query) do
    with token when is_binary(token) <- Query.get_argument(query, :token),
         {:ok, %{"purpose" => @purpose, "sub" => subject}, _resource} <-
           Jwt.verify(token, User, tenant: query.tenant),
         {:ok, false} <- Token.revoked(token),
         %URI{query: params} <- URI.parse(subject),
         %{"id" => id} <- URI.decode_query(params || "") do
      Query.filter(query, id == ^id)
    else
      _invalid -> Query.add_error(query, failed(query))
    end
  end

  defp exchanged(query, [user]) do
    with :ok <- TokenResource.revoke(Token, Query.get_argument(query, :token)),
         {:ok, token, _claims} <-
           Jwt.token_for_user(user, %{},
             purpose: :sign_in,
             tenant: query.tenant,
             token_lifetime: @sign_in_lifetime
           ) do
      {:ok, [Ash.Resource.put_metadata(user, :token, token)]}
    else
      _failed -> {:error, failed(query)}
    end
  end

  defp exchanged(query, _not_one), do: {:error, failed(query)}

  defp failed(query) do
    AuthenticationFailed.exception(
      query: query,
      caused_by: %{
        module: __MODULE__,
        action: query.action,
        resource: User,
        message: dgettext_noop("errors", "The second step's token is invalid or expired")
      }
    )
  end
end
