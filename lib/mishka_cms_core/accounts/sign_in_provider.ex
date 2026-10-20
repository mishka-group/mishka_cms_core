# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SignInProvider do
  @moduledoc """
  Signing in with another service's account as `mishka_installer` plugins on `"auth:providers"`,
  the way `MishkaCmsCore.Captcha.Provider` makes captchas. The core names no provider: each ships as
  its own package (`mishka_cms_auth_google`, `mishka_cms_auth_github`, …) whose application starts
  its plugin, so a host that adds the dependency has the provider on every site's Security tab.

  AshAuthentication does the sign-in itself, through one strategy for every provider
  (`MishkaCmsCore.Accounts.ProviderStrategy`: `/api/auth/user/provider/<id>/request`, and one
  callback for all, `/api/auth/user/provider/callback`). A plugin
  says which Assent strategy speaks to its provider (`c:oauth/0`) — Assent knows each provider's
  addresses and how its answer reads — and adds what differs per site: its keys, whether the site
  offers it, and its button. Every account a provider signs in keeps one
  `MishkaCmsCore.Accounts.UserIdentity` for it, named `"provider/<id>"`.

  A site that has not switched the provider on, has no keys for it, or whose provider plugin is
  stopped refuses it before the visitor is sent anywhere.

  ## Settings

  The Security tab's "Sign-in methods" table: each provider switched on per site
  (`auth.providers.<id>.enabled`) with its keys in its row, and `auth.social.register`, whether a
  first sign-in makes an account. A master signs in on the master site's address with the master
  site's providers. The address each provider sends the visitor back to is `callback_url/1`, which
  its console has to list.

      use MishkaCmsCore.Accounts.SignInProvider,
        id: "github", label: gettext_noop("GitHub"), priority: 20

      @impl true
      def oauth, do: %{assent: Assent.Strategy.Github}
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.{ProviderRegistry, Settings}

  @event "auth:providers"
  @register_key "auth.social.register"

  @type site_id :: String.t() | nil

  @doc "The provider's id, in its route and its setting keys: `\"github\"`."
  @callback id() :: String.t()

  @doc """
  How it signs in: `:assent`, the Assent strategy that speaks to the provider
  (`Assent.Strategy.Github`, or `Assent.Strategy.OAuth2` / `Assent.Strategy.OIDC` with its addresses
  for one Assent does not name), and any `MishkaCmsCore.Accounts.ProviderStrategy` field set over
  Assent's own defaults for it — `base_url`, `authorize_url`, `token_url`, `user_url`,
  `authorization_params`, and `code_verifier: true` for PKCE (S256) where the provider takes it.
  """
  @callback oauth() :: %{required(:assent) => module(), optional(atom()) => term()}

  @doc "The name on the button and the settings page, as a `gettext_noop/1` msgid."
  @callback label() :: String.t()

  @doc "The button's mark: an SVG path in a 24×24 box, and its Tailwind text colour."
  @callback icon() :: %{path: String.t(), color: String.t()}

  @doc "The provider's own key fields (`MishkaCmsCore.Settings.define/3`)."
  @callback settings() :: [Settings.definition()]

  @doc "Whether `site_id` holds every key the provider needs."
  @callback ready?(site_id()) :: boolean()

  @doc "One of its keys for `site_id`: `:client_id` or `:client_secret`."
  @callback secret(name :: atom(), site_id()) :: {:ok, String.t()} | :error

  @doc "Whether the provider is offered on this installation. Every provider is, unless it says not."
  @callback offered?() :: boolean()

  @optional_callbacks offered?: 0

  @doc false
  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
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

  @doc "The offered provider registered under `id`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :unknown_provider | :cannot_run}
  def fetch(id), do: ProviderRegistry.fetch(@event, __MODULE__, id)

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
  The address a provider sends a visitor back to on `site`, which its console has to list: the
  callback every provider shares, on the site's own address, read from the site record.

      SignInProvider.callback_url(site) #=> "https://example.com/api/auth/user/provider/callback"
  """
  @spec callback_url(%{host: String.t()}) :: String.t()
  def callback_url(%{host: host}),
    do: MishkaCmsCore.Helpers.site_url(host, "/api/auth/user/provider/callback")

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
        Enum.map(provider.settings(), &under_switch(&1, provider))
      end)
  end

  # A provider's keys sit in its own row of the table, under its switch, while it is on.
  defp under_switch(definition, provider) do
    definition
    |> Map.merge(%{group: methods_group(), under: enabled_key(provider)})
    |> Settings.shown_when(enabled_key(provider), true)
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
  A provider's key field: a `:string` (or `type`) setting on the Security tab that each site sets for
  itself, drawn in the provider's own row of the "Sign-in methods" table while it is on. `opts` are `MishkaCmsCore.Settings.define/3`'s.
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
