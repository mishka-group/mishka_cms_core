defmodule MishkaCmsCore.Captcha.Provider do
  @moduledoc """
  A captcha provider: one module that is a `mishka_installer` plugin on the `"captcha:providers"`
  event and implements the callbacks below. `MishkaCmsCore.Captcha` never names a provider: a scope
  picks one on the settings page's Security tab (`security.captcha.provider`), and its sign-in,
  registration, forgot-password and sign-in-link forms ask it.

      defmodule MyExtension.Captcha.Acme do
        use MishkaCmsCore.Captcha.Provider, id: "acme", label: "Acme Captcha"

        @site_key "security.captcha.acme.site_key"
        @secret "security.captcha.acme.secret_key"

        @impl true
        def settings do
          [
            site_key(@site_key, gettext_noop("Acme site key"), group: "Acme Captcha"),
            secret(@secret, gettext_noop("Acme secret key"), group: "Acme Captcha")
          ]
        end

        @impl true
        def ready?(site_id), do: own(@site_key, site_id) != nil and secret?(@secret, site_id)

        @impl true
        def browser(site_id, _form, _language) do
          %{
            script: "https://captcha.acme.example/api.js?render=explicit",
            global: "acme",
            mode: :widget,
            options: %{"sitekey" => own(@site_key, site_id)}
          }
        end

        @impl true
        def csp, do: %{script_src: ["https://captcha.acme.example"], frame_src: ["https://captcha.acme.example"]}

        @impl true
        def verify(token, site_id, request) do
          with {:ok, answer} <-
                 siteverify("https://captcha.acme.example/siteverify", %{
                   secret: Settings.secret(@secret, site_id),
                   response: token,
                   remoteip: request.remote_ip
                 }),
               do: {:ok, %{hostname: answer["hostname"], test?: false}}
        end
      end

  Supervise the module in the extension's application, like any other plugin. `use` adds the plugin
  half — the `"captcha:providers"` registration, see `MishkaCmsCore.ProviderRegistry` — plus
  `site_key/3` and `secret/3`, which build a provider's settings the way the core's are built,
  `own/2`, which reads one, and `siteverify/2`, which asks a provider's server about a token.

  ## Settings

  `settings/0` declares the provider's own fields, shown on the Security tab under its label. Each
  scope sets its own (`resolve: :own`): a site never checks with another site's keys. The secret is a
  `:secret` setting; read it with `MishkaCmsCore.Settings.secret/2`, never `get/3`.

  ## The browser

  `browser/3` tells the one `Captcha` hook (`assets/js/shared_hooks.js`) how to draw the check for
  `form` in `language`: the `script` to load, the `global` it defines, and the `mode` —

    * `:widget` — a box drawn with `global.render(element, options)`, whose `callback` hands back
      the token (Turnstile, reCAPTCHA v2, hCaptcha);
    * `:score` — nothing drawn: `global.execute(options.sitekey, %{action: options.action})` is asked
      for a token as the form is sent (reCAPTCHA v3).

  `csp/0` names the origins the browser loads the provider from; the security headers allow them on
  the sites that use it, and nowhere else.

  ## Verifying

  `verify/3` asks the provider's server about one token, for `site_id`, with `request` —
  `%{remote_ip: address | nil, form: form}` — through `siteverify/2`, which reads the answer the same
  way for every provider. It answers `{:ok, %{hostname: host, test?: boolean}}`: the address the
  check was solved on, and whether the scope checks with the provider's published test keys, which
  pass every token on any address; or `{:error, {:failed, detail}}` when the token was refused —
  wrong, expired, used, a low score — or `{:error, {:unavailable, detail}}` when the provider could
  not be asked or refused the keys themselves. `detail` is a short text for the log and the settings
  page's test.

  ## The registered providers

  `all/0`, `offered/0` and `fetch/1` ask the `"captcha:providers"` event which providers are
  installed: the core's own — Cloudflare Turnstile, Google reCAPTCHA and hCaptcha — register the
  same way an extension's would.
  """

  alias MishkaCmsCore.{ProviderRegistry, Settings}

  @event "captcha:providers"

  @type site_id :: String.t() | nil
  @type form :: :sign_in | :register | :reset_request | :magic_link | :test

  @type browser :: %{
          script: String.t(),
          global: String.t(),
          mode: :widget | :score,
          options: %{String.t() => term()}
        }

  @doc "The provider's id, stored in `security.captcha.provider`."
  @callback id() :: String.t()

  @doc "The name on the settings page, as a `gettext_noop/1` msgid."
  @callback label() :: String.t()

  @doc "The provider's own setting definitions (`MishkaCmsCore.Settings.define/3`)."
  @callback settings() :: [Settings.definition()]

  @doc "Whether `site_id` has everything this provider needs to check."
  @callback ready?(site_id()) :: boolean()

  @doc "How the browser draws the check for `form` on `site_id`, in `language`."
  @callback browser(site_id(), form(), language :: String.t()) :: browser()

  @doc "The origins the browser loads the provider from, by CSP directive."
  @callback csp() ::
              %{optional(:script_src | :frame_src | :style_src | :connect_src) => [String.t()]}

  @doc "Asks the provider about `token`."
  @callback verify(token :: String.t(), site_id(), %{remote_ip: String.t() | nil, form: form()}) ::
              {:ok, %{hostname: String.t() | nil, test?: boolean()}}
              | {:error, {:failed | :unavailable, String.t()}}

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
        event: "captcha:providers",
        priority: unquote(priority)

      use Gettext, backend: MishkaCmsCore.Gettext

      @behaviour MishkaCmsCore.Captcha.Provider

      alias MishkaCmsCore.Settings

      import MishkaCmsCore.Captcha.Provider,
        only: [
          site_key: 2,
          site_key: 3,
          secret: 2,
          secret: 3,
          secret?: 2,
          own: 2,
          siteverify: 2
        ]

      @impl MishkaCmsCore.Captcha.Provider
      def id, do: unquote(id)

      @impl MishkaCmsCore.Captcha.Provider
      def label, do: unquote(label)
    end
  end

  @doc "The event a provider plugin listens on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "Every registered provider module, the first of each id."
  @spec all() :: [module()]
  def all, do: ProviderRegistry.all(@event, __MODULE__)

  @doc "The providers this installation offers on the settings page."
  @spec offered() :: [module()]
  def offered, do: ProviderRegistry.offered(@event, __MODULE__)

  @doc "The offered provider registered under `id`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :unknown_provider}
  def fetch(id), do: ProviderRegistry.fetch(@event, __MODULE__, id)

  @doc """
  A provider's public key field: a `:string` setting on the Security tab that each scope sets for
  itself. `opts` are `MishkaCmsCore.Settings.define/3`'s.
  """
  @spec site_key(String.t(), String.t(), keyword()) :: Settings.definition()
  def site_key(key, label, opts \\ []), do: field(key, :string, label, opts)

  @doc """
  A provider's secret field: a `:secret` setting on the Security tab that each scope sets for
  itself, stored sealed and never shown again. `opts` are `MishkaCmsCore.Settings.define/3`'s.
  """
  @spec secret(String.t(), String.t(), keyword()) :: Settings.definition()
  def secret(key, label, opts \\ []), do: field(key, :secret, label, opts)

  defp field(key, type, label, opts) do
    Settings.define(
      key,
      type,
      Keyword.merge(
        [
          default: "",
          label: label,
          category: "security",
          scope: :both,
          resolve: :own,
          source: :plugin
        ],
        opts
      )
    )
  end

  @doc "A scope's own value of a provider setting, trimmed; `nil` when it set none."
  @spec own(String.t(), site_id()) :: String.t() | nil
  def own(key, site_id) do
    case Settings.get_own(key, "", site_id) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _not_text ->
        nil
    end
  end

  # THE ANSWERS THAT ARE THE PROVIDER'S OR THE KEYS' FAULT, never the visitor's: the only ones a form
  # goes through on. Turnstile, reCAPTCHA and hCaptcha name them the same way.
  @unavailable ~w(missing-input-secret invalid-input-secret internal-error sitekey-secret-mismatch not-using-dummy-passcode)

  @doc """
  Posts `fields` to a provider's verify endpoint, as a form, and reads the answer the way Turnstile,
  reCAPTCHA and hCaptcha all give it: `{:ok, answer}` when it says `"success": true`;
  `{:error, {:unavailable, detail}}` when it could not be reached in time, failed (a 5xx), or refused
  the keys themselves (`missing-input-secret`, `invalid-input-secret`, `sitekey-secret-mismatch`,
  `not-using-dummy-passcode`, `internal-error`); `{:error, {:failed, detail}}` for every other answer —
  a refusal with any other code or none, a 4xx, a body that is no answer. A field that is `nil` is
  left out. No retry and no redirect, so a slow provider cannot hold a sign-in open and the secret is
  never sent anywhere but `url`.

  `config :mishka_cms_core, #{inspect(__MODULE__)}, req_options: [...]` adds to the request — the
  test suite routes it to `Req.Test`.
  """
  @spec siteverify(String.t(), map()) ::
          {:ok, map()} | {:error, {:failed | :unavailable, String.t()}}
  def siteverify(url, fields) do
    form = for {name, value} <- fields, not is_nil(value), into: %{}, do: {name, value}

    [
      url: url,
      form: form,
      retry: false,
      redirect: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 3_000]
    ]
    |> Keyword.merge(Application.get_env(:mishka_cms_core, __MODULE__, [])[:req_options] || [])
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"success" => true} = answer}} ->
        {:ok, answer}

      {:ok, %Req.Response{status: 200, body: %{} = answer}} ->
        refused(List.wrap(answer["error-codes"]))

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, {:unavailable, "HTTP #{status}"}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:failed, "HTTP #{status}"}}

      {:error, exception} ->
        {:error, {:unavailable, Exception.message(exception)}}
    end
  end

  defp refused(codes) do
    detail = if codes == [], do: "refused", else: Enum.join(codes, ", ")

    if Enum.any?(codes, &(&1 in @unavailable)),
      do: {:error, {:unavailable, detail}},
      else: {:error, {:failed, detail}}
  end

  @doc """
  Whether a scope holds a `:secret` setting this server can open. One sealed under another
  `SECRET_KEY_BASE` cannot be, and counts as none: the provider is not ready, nothing is asked, and
  the settings page shows the key as not set until it is typed again.
  """
  @spec secret?(String.t(), site_id()) :: boolean()
  def secret?(key, site_id), do: Settings.secret(key, site_id) != nil
end
