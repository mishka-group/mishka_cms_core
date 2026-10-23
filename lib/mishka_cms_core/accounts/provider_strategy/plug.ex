# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.ProviderStrategy.Plug do
  @moduledoc """
  Both phases of a provider's sign-in: the provider the request path names — kept in the session for
  the callback, which every provider shares — is looked up among the `"auth:providers"` plugins, refused unless the site the request reached offers it, and filled
  into the strategy — its Assent strategy, Assent's own defaults for it, what the plugin overrides,
  the site's keys and the callback on the site's address — before AshAuthentication's
  `OAuth2.Plug` runs the phase.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias AshAuthentication.Errors.AuthenticationFailed
  alias AshAuthentication.Strategy.{OAuth2, Oidc.NonceGenerator}
  alias MishkaCmsCore.Accounts.{ProviderStrategy, SignInProvider}

  import AshAuthentication.Plug.Helpers, only: [store_authentication_result: 2]
  import Plug.Conn, only: [put_session: 3, get_session: 2, delete_session: 2]

  @session_key "user/provider/id"

  @doc "Starts a sign-in with the provider in the path, and keeps which one in the session."
  @spec request(Plug.Conn.t(), ProviderStrategy.t()) :: Plug.Conn.t()
  def request(%Plug.Conn{path_params: %{"provider" => id}} = conn, strategy)
      when is_binary(id) do
    case filled(conn, strategy, id) do
      {:ok, filled} ->
        conn
        |> put_session(@session_key, id)
        |> OAuth2.Plug.request(filled)

      :error ->
        store_authentication_result(conn, {:error, refused(strategy)})
    end
  end

  def request(conn, strategy), do: store_authentication_result(conn, {:error, refused(strategy)})

  @doc "Ends it, where the provider sent the visitor back: with the provider it started with."
  @spec callback(Plug.Conn.t(), ProviderStrategy.t()) :: Plug.Conn.t()
  def callback(conn, strategy) do
    with id when is_binary(id) <- get_session(conn, @session_key),
         {:ok, filled} <- filled(conn, strategy, id) do
      conn
      |> delete_session(@session_key)
      |> OAuth2.Plug.callback(filled)
    else
      _no_sign_in_started -> store_authentication_result(conn, {:error, refused(strategy)})
    end
  end

  defp filled(conn, strategy, id) do
    with %{id: site_id} = site <- conn.assigns[:current_site],
         {:ok, provider} <- SignInProvider.fetch(id),
         true <- SignInProvider.on?(provider, site_id),
         {:ok, client_id} <- provider.secret(:client_id, site_id),
         {:ok, client_secret} <- provider.secret(:client_secret, site_id) do
      {:ok,
       strategy
       |> with_provider(provider.oauth())
       |> Map.merge(%{
         client_id: client_id,
         client_secret: client_secret,
         redirect_uri: SignInProvider.callback_url(site),
         __connection_id__: provider.id()
       })}
    else
      _not_offered -> :error
    end
  end

  # ASSENT KNOWS EACH PROVIDER: its addresses, scope and how it authenticates are its own
  # `default_config/1`, under whatever the plugin sets over them.
  defp with_provider(strategy, %{assent: assent} = oauth) do
    fields =
      []
      |> assent.default_config()
      |> Map.new()
      |> Map.merge(Map.delete(oauth, :assent))
      |> Map.take(Map.keys(Map.from_struct(strategy)))

    strategy
    |> Map.merge(fields)
    |> Map.put(:assent_strategy, assent)
    |> openid(oidc?(assent))
  end

  # AN OPENID CONNECT PROVIDER gets a nonce, and `openid` only once: Assent asks for it itself.
  defp openid(strategy, true) do
    scope =
      strategy.authorization_params
      |> Keyword.get(:scope, "")
      |> String.split()
      |> Enum.reject(&(&1 == "openid"))
      |> Enum.join(" ")

    %{
      strategy
      | nonce: {NonceGenerator, []},
        openid_default_scope: "openid",
        authorization_params: Keyword.put(strategy.authorization_params, :scope, scope)
    }
  end

  defp openid(strategy, false), do: strategy

  defp oidc?(assent),
    do:
      Assent.Strategy.OIDC.Base in List.flatten(
        Keyword.get_values(assent.module_info(:attributes), :behaviour)
      )

  defp refused(strategy) do
    AuthenticationFailed.exception(
      strategy: strategy,
      caused_by: %{
        module: __MODULE__,
        strategy: strategy,
        message: dgettext_noop("errors", "This site does not offer that sign-in provider.")
      }
    )
  end
end
