# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defimpl AshAuthentication.Strategy, for: MishkaCmsCore.Accounts.ProviderStrategy do
  @moduledoc false

  alias AshAuthentication.{Info, Strategy.OAuth2}
  alias MishkaCmsCore.Accounts.ProviderStrategy

  def name(strategy), do: strategy.name

  def phases(_strategy), do: [:request, :callback]

  def actions(%ProviderStrategy{registration_enabled?: true}), do: [:register]
  def actions(%ProviderStrategy{registration_enabled?: false}), do: [:sign_in]

  # POST as well, for a provider that answers with `response_mode=form_post`.
  def method_for_phase(_strategy, :request), do: :get
  def method_for_phase(_strategy, :callback), do: [:get, :post]

  def routes(strategy) do
    base =
      [Info.authentication_subject_name!(strategy.resource), strategy.name]
      |> Enum.map_join("/", &to_string/1)

    # One callback for every provider, as AshAuthentication's `dynamic_oidc` has: the provider a
    # sign-in started with waits in the session.
    [{"/#{base}/:provider/request", :request}, {"/#{base}/callback", :callback}]
  end

  def plug(strategy, :request, conn), do: ProviderStrategy.Plug.request(conn, strategy)
  def plug(strategy, :callback, conn), do: ProviderStrategy.Plug.callback(conn, strategy)

  def action(strategy, :register, params, options),
    do: OAuth2.Actions.register(strategy, params, options)

  def action(strategy, :sign_in, params, options),
    do: OAuth2.Actions.sign_in(strategy, params, options)

  def tokens_required?(_strategy), do: false
end
