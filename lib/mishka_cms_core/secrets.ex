# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Secrets do
  @moduledoc false
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        MishkaCmsCore.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:mishka_cms_core, :token_signing_secret)
  end

  # A SIGN-IN PROVIDER'S KEYS ARE THE SITE'S, asked per request: AshAuthentication hands the request
  # over as `context.conn` — see `MishkaCmsCore.Accounts.SignInProvider.secret_for/3`.
  def secret_for(
        [:authentication, :strategies, strategy, name],
        MishkaCmsCore.Accounts.User,
        _opts,
        context
      ),
      do: MishkaCmsCore.Accounts.SignInProvider.secret_for(strategy, name, context[:conn])

  def secret_for(_path, _resource, _opts, _context), do: :error
end
