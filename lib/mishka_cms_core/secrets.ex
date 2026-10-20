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

  def secret_for(_path, _resource, _opts, _context), do: :error
end
