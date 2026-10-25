# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Mail.Provider do
  @moduledoc """
  An email provider: one module that is a `mishka_installer` plugin on the `"mail:providers"` event
  and implements the callbacks below. `MishkaCmsCore.Mail` never names a provider; a site picks one
  on the settings page (`mailer.provider`) and every email of that site goes through it.

      defmodule MyExtension.Mail.Postmark do
        use MishkaCmsCore.Mail.Provider, id: "postmark", label: "Postmark"

        @impl true
        def settings do
          [secret("mailer.postmark.server_token", gettext_noop("Postmark server token"))]
        end

        @impl true
        def ready?(site_id), do: not is_nil(Settings.secret("mailer.postmark.server_token", site_id))

        @impl true
        def deliver(email, site_id, _opts) do
          token = Settings.secret("mailer.postmark.server_token", site_id)
          MishkaCmsCore.Mailer.deliver(email, adapter: Swoosh.Adapters.Postmark, api_key: token)
        end
      end

  Supervise the module in the extension's application, like any other plugin. `use` adds the
  plugin half — the `"mail:providers"` registration, see `MishkaCmsCore.ProviderRegistry` — plus
  `secret/3`, which builds a provider setting the way the core's are built.

  ## Settings

  `settings/0` declares the provider's own fields, shown on the settings page's Email tab under its
  label. Each scope sets its own (`resolve: :own`): a site never sends with the installation's key.
  A key is a `:secret` setting; read it with `MishkaCmsCore.Settings.secret/2`, never `get/3`.

  ## Delivering

  `deliver/3` sends one `Swoosh.Email` for `site_id` and returns `{:ok, message_id}` (`nil` when the
  provider gives none) or `{:error, reason}`. `opts` carries `:idempotency_key` and `:purpose`.
  `retry?/1` says whether a failure may succeed on a later attempt (a rate limit, a timeout) or
  will fail the same way again (a bad key, an unverified domain).

  ## The registered providers

  `all/0`, `offered/0` and `fetch/1` ask the `"mail:providers"` event which providers are installed:
  the core's own — `Resend` and, in development, the `DevMailbox` — register the same way an
  extension's would, so stopping a provider's plugin in the installer takes it off the settings page
  and out of delivery. Nothing is cached: the event is asked when the settings page loads and when an
  email is sent.
  """

  alias MishkaCmsCore.{ProviderRegistry, Settings}

  @event "mail:providers"

  @type site_id :: String.t() | nil

  @doc "The provider's id, stored in `mailer.provider`."
  @callback id() :: String.t()

  @doc "The name on the settings page, as a `gettext_noop/1` msgid."
  @callback label() :: String.t()

  @doc "The provider's own setting definitions (`MishkaCmsCore.Settings.define/3`)."
  @callback settings() :: [Settings.definition()]

  @doc "Whether `site_id` has everything this provider needs to send."
  @callback ready?(site_id()) :: boolean()

  @doc "Sends `email` for `site_id`."
  @callback deliver(Swoosh.Email.t(), site_id(), keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc "Whether a failure `deliver/3` returned is worth another attempt."
  @callback retry?(term()) :: boolean()

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
        event: "mail:providers",
        priority: unquote(priority)

      use Gettext, backend: MishkaCmsCore.Gettext

      @behaviour MishkaCmsCore.Mail.Provider

      alias MishkaCmsCore.Settings

      import MishkaCmsCore.Mail.Provider, only: [secret: 3, secret: 2]

      @impl MishkaCmsCore.Mail.Provider
      def id, do: unquote(id)

      @impl MishkaCmsCore.Mail.Provider
      def label, do: unquote(label)
    end
  end

  @doc "Event a provider plugin listens on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "Every registered provider module, the first of each id."
  @spec all() :: [module()]
  def all, do: ProviderRegistry.all(@event, __MODULE__)

  @doc "The providers this installation offers on the settings page."
  @spec offered() :: [module()]
  def offered, do: ProviderRegistry.offered(@event, __MODULE__)

  @doc "The offered provider registered under `id`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :unknown_provider | :cannot_run}
  def fetch(id), do: ProviderRegistry.fetch(@event, __MODULE__, id)

  @doc """
  A provider's secret field: a `:secret` setting on the Email tab, under the provider's label, that
  each scope sets for itself. `opts` are `MishkaCmsCore.Settings.define/3`'s.
  """
  @spec secret(String.t(), String.t(), keyword()) :: Settings.definition()
  def secret(key, label, opts \\ []) do
    Settings.define(
      key,
      :secret,
      Keyword.merge(
        [
          label: label,
          category: "email",
          scope: :both,
          resolve: :own,
          source: :plugin
        ],
        opts
      )
    )
  end
end
