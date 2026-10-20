# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SignInProvider do
  @moduledoc """
  Signing in with another service's account — Google, GitHub, Apple — as `mishka_installer`
  plugins, the way `MishkaCmsCore.Captcha.Provider` makes captchas.

  AshAuthentication does the sign-in itself: each provider is a strategy on
  `MishkaCmsCore.Accounts.User` (`google`, `github`, `apple`) with its routes under
  `/api/auth/user/<strategy>`, and every account it signs in keeps one
  `MishkaCmsCore.Accounts.UserIdentity` per provider. A provider plugin adds what differs per site:
  its keys, whether the site offers it, and its button.

  The strategy reads its keys through `MishkaCmsCore.Secrets`, which asks `secret_for/3`. A site
  that has not switched the provider on, has no keys for it, or whose provider plugin is stopped
  answers `:error`, and AshAuthentication stops before the visitor is sent anywhere. The strategies
  are compiled into the User resource, so a plugin can only switch on one of those three; another
  provider is a strategy there first.

  ## Settings

  The Security tab's "Sign-in methods" table: each provider switched on per site
  (`auth.providers.<id>.enabled`) with its keys below it, and `auth.social.register`, whether a
  first sign-in makes an account. A master signs in on the master site's address with the master
  site's providers. The address each provider sends the visitor back to is `callback_url/2`, which
  its console has to list.

      use MishkaCmsCore.Accounts.SignInProvider,
        id: "google", strategy: :google, label: gettext_noop("Google"), priority: 10
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.{ProviderRegistry, Settings}

  @event "auth:providers"
  @register_key "auth.social.register"

  @type site_id :: String.t() | nil

  @doc "The provider's id, in its setting keys: `\"google\"`."
  @callback id() :: String.t()

  @doc "The `MishkaCmsCore.Accounts.User` strategy it switches on: `:google`."
  @callback strategy() :: atom()

  @doc "The name on the button and the settings page, as a `gettext_noop/1` msgid."
  @callback label() :: String.t()

  @doc "The button's mark: an SVG path in a 24×24 box, and its Tailwind text colour."
  @callback icon() :: %{path: String.t(), color: String.t()}

  @doc "The provider's own key fields (`MishkaCmsCore.Settings.define/3`)."
  @callback settings() :: [Settings.definition()]

  @doc "Whether `site_id` holds every key the provider needs."
  @callback ready?(site_id()) :: boolean()

  @doc "One of the strategy's keys for `site_id`, by the name AshAuthentication asks it by."
  @callback secret(name :: atom(), site_id()) :: {:ok, String.t()} | :error

  @doc "Whether the provider is offered on this installation. Every provider is, unless it says not."
  @callback offered?() :: boolean()

  @optional_callbacks offered?: 0

  @doc false
  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    strategy = Keyword.fetch!(opts, :strategy)
    label = Keyword.fetch!(opts, :label)
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaCmsCore.ProviderRegistry,
        event: "auth:providers",
        priority: unquote(priority)

      use Gettext, backend: MishkaCmsCore.Gettext

      @behaviour MishkaCmsCore.Accounts.SignInProvider

      import MishkaCmsCore.Accounts.SignInProvider, only: [key: 3, key: 4, own: 2]
      import MishkaCmsCore.Captcha.Provider, only: [secret?: 2]

      @impl MishkaCmsCore.Accounts.SignInProvider
      def id, do: unquote(id)

      @impl MishkaCmsCore.Accounts.SignInProvider
      def strategy, do: unquote(strategy)

      @impl MishkaCmsCore.Accounts.SignInProvider
      def label, do: unquote(label)
    end
  end

  @doc "`\"auth:providers\"`: a provider plugin adds itself to the `providers` list it carries."
  @spec event() :: String.t()
  def event, do: @event

  @doc "Every registered provider module, the first of each id."
  @spec all() :: [module()]
  def all, do: ProviderRegistry.all(@event, __MODULE__)

  @doc "The providers this installation offers."
  @spec offered() :: [module()]
  def offered, do: ProviderRegistry.offered(@event, __MODULE__)

  @doc "The offered provider that switches on `strategy`, or `:error`."
  @spec for_strategy(atom()) :: {:ok, module()} | :error
  def for_strategy(strategy) do
    case Enum.find(offered(), &(&1.strategy() == strategy)) do
      nil -> :error
      provider -> {:ok, provider}
    end
  end

  @doc "The setting that switches `provider` on for a site."
  @spec enabled_key(module() | String.t()) :: String.t()
  def enabled_key(provider) when is_atom(provider), do: enabled_key(provider.id())
  def enabled_key(id) when is_binary(id), do: "auth.providers.#{id}.enabled"

  @doc "Whether `site_id` offers `provider`: switched on, with every key it needs."
  @spec on?(module(), site_id()) :: boolean()
  def on?(_provider, nil), do: false

  def on?(provider, site_id),
    do:
      Settings.get_own(enabled_key(provider), false, site_id) == true and provider.ready?(site_id)

  @doc "The providers `site_id` offers, in the installation's order: the buttons its sign-in pages draw."
  @spec available(site_id()) :: [module()]
  def available(site_id), do: Enum.filter(offered(), &on?(&1, site_id))

  @doc "Whether a first sign-in with a provider on `site_id` makes an account there."
  @spec register?(site_id()) :: boolean()
  def register?(site_id), do: Settings.get_own(@register_key, true, site_id) == true

  @doc """
  The address `provider` sends a visitor back to on `site`, which its console has to list: the
  strategy's callback route on the site's own address.

      SignInProvider.callback_url(Google, site) #=> "https://example.com/api/auth/user/google/callback"
  """
  @spec callback_url(module(), %{host: String.t()}) :: String.t()
  def callback_url(provider, %{host: host}),
    do: MishkaCmsCore.Helpers.site_url(host, "/api/auth/user/#{provider.strategy()}/callback")

  @doc """
  A strategy key for the request in `conn`, for `MishkaCmsCore.Secrets`: the provider's own from
  the site the request reached, and the callback address on that site's address — read from the
  site record, not from the request's Host. `:error` while the site does not offer the provider.
  """
  @spec secret_for(atom(), atom(), Plug.Conn.t() | term()) :: {:ok, String.t()} | :error
  def secret_for(strategy, name, %Plug.Conn{assigns: %{current_site: %{id: site_id} = site}}) do
    with {:ok, provider} <- for_strategy(strategy),
         true <- on?(provider, site_id) do
      case name do
        :redirect_uri -> {:ok, callback_url(provider, site)}
        name -> provider.secret(name, site_id)
      end
    else
      _not_offered -> :error
    end
  end

  def secret_for(_strategy, _name, _no_site), do: :error

  @doc """
  The rows of the Security tab's "Sign-in methods" table that are about providers — one switch per
  provider and whether a first sign-in makes an account — then each provider's keys, drawn while its
  switch is on. Part of `MishkaCmsCore.Settings`' core definitions.
  """
  @spec settings() :: [Settings.definition()]
  def settings do
    providers = offered()

    Enum.map(providers, &switch/1) ++
      [
        Settings.define(@register_key, :boolean,
          default: true,
          category: "security",
          group: methods_group(),
          collapsed: true,
          layout: :table,
          scope: :site,
          label: gettext_noop("Create an account on a first sign-in with a provider"),
          description:
            gettext_noop(
              "Off, a provider signs in only an account that already has its email. Closing registration stops it too. Masters are never made this way."
            )
        )
      ] ++
      Enum.flat_map(providers, fn provider ->
        Enum.map(provider.settings(), &Settings.shown_when(&1, enabled_key(provider), true))
      end)
  end

  defp switch(provider) do
    Settings.define(enabled_key(provider), :boolean,
      default: false,
      category: "security",
      group: methods_group(),
      collapsed: true,
      layout: :table,
      scope: :site,
      source: :plugin,
      label: provider.label(),
      description:
        gettext_noop("Sign in with an account there. Its keys appear below once it is on.")
    )
  end

  @doc "The Security tab's group every way of signing in is switched in."
  @spec methods_group() :: String.t()
  def methods_group, do: gettext_noop("Sign-in methods")

  @doc """
  A provider's key field: a `:string` (or `type`) setting on the Security tab, in the provider's own
  accordion, that each site sets for itself. `opts` are `MishkaCmsCore.Settings.define/3`'s.
  """
  @spec key(String.t(), atom(), String.t(), keyword()) :: Settings.definition()
  def key(key, type \\ :string, label, opts) do
    Settings.define(
      key,
      type,
      Keyword.merge(
        [
          default: "",
          label: label,
          category: "security",
          collapsed: true,
          scope: :site,
          source: :plugin,
          trim: type != :secret
        ],
        opts
      )
    )
  end

  @doc "A site's own value of a provider setting, trimmed; `nil` when it set none."
  @spec own(String.t(), site_id()) :: String.t() | nil
  defdelegate own(key, site_id), to: MishkaCmsCore.Captcha.Provider
end
