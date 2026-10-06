defmodule MishkaCmsCore.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        MishkaCmsCore.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:mishka_cms_core, :token_signing_secret)
  end
end
