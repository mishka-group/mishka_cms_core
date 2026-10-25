# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Captcha do
  @moduledoc """
  The captcha a site's sign-in, registration, forgot-password and sign-in-link forms ask, through
  the provider the site picked.

  Each scope picks a provider on the settings page's Security tab (`security.captcha.provider`) and
  sets that provider's keys there, for itself alone (`resolve: :own`): Global is the masters' own
  sign-in. Providers are `mishka_installer` plugins (`MishkaCmsCore.Captcha.Provider`), the core's
  own — Cloudflare Turnstile, Google reCAPTCHA and hCaptcha — included. A scope with no provider
  (None) or with one missing a key asks nothing. A scope whose chosen provider does not answer — its
  plugin is gone, raised, or cannot run (`MishkaCmsCore.ProviderRegistry`) — refuses every check
  until it chooses another or None.

  ## Where

  A form draws the check with `<.captcha>` (`MishkaCmsCore.Captcha.Widget`), which `browser/3`
  describes, and its action checks the token (`MishkaCmsCore.Accounts.CaptchaCheck`), so the sign-in
  pages and the `/api/auth` routes ask alike. An extension's form asks the same captcha under a form
  of its own, an atom its action and its `<.captcha for={…}>` both name, and may ask it only once the
  form has been sent (`deferred`, see `MishkaCmsCore.Captcha.Widget`). The security headers let the
  browser load the provider on the sites that use it (`csp_sources/1`).

  ## One check

  `check/4` refuses a missing token, and a token it saw accepted in the last five minutes — each is
  good for one check — without asking anybody, then asks the provider, then holds its answer to the
  site's own address (`security.captcha.check_domain`). A provider that cannot be asked — down, slow,
  refusing the keys — is answered `{:error, {:unavailable, detail}}`, and the action lets the form
  through: its rate limits still hold.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Captcha.Provider
  alias MishkaCmsCore.Runtime.States.{RateLimitState, SiteState}
  alias MishkaCmsCore.Settings

  @provider_key "security.captcha.provider"
  @domain_key "security.captcha.check_domain"

  # Turnstile's tokens live five minutes, reCAPTCHA's two: one seen in that time is spent.
  @lifetime :timer.minutes(5)

  # The longest token sent to a provider. Turnstile's are at most 2048 characters, reCAPTCHA's and
  # hCaptcha's a few thousand; anything longer is refused here.
  @max_token 8_192

  @type site_id :: String.t() | nil
  @type form :: Provider.form()
  @type request :: %{optional(:remote_ip) => String.t() | nil}
  @type answer ::
          :ok
          | {:error, :missing}
          | {:error, {:failed, String.t()}}
          | {:error, {:unavailable, String.t()}}

  @doc """
  The settings the Security tab shows under "Captcha": which provider a scope uses, whether its
  answer is held to the site's address, then every offered provider's own — each drawn only while
  its provider is the one chosen (`MishkaCmsCore.Settings.shown_when/3`). Part of
  `MishkaCmsCore.Settings`' core definitions.
  """
  @spec settings() :: [Settings.definition()]
  def settings do
    providers = Provider.offered()
    group = gettext_noop("Captcha")

    [
      Settings.define(@provider_key, :select,
        default: "none",
        category: "security",
        group: group,
        scope: :both,
        resolve: :own,
        label: gettext_noop("Captcha"),
        description:
          gettext_noop(
            "Asked on this site's sign-in, registration, forgot-password and sign-in-link pages, before the password is checked. The JSON API never asks. Each site uses its own keys, set below; while one is missing, nothing is asked."
          ),
        options:
          [{gettext_noop("None — nothing is asked"), "none"}] ++
            Enum.map(providers, &{&1.label(), &1.id()})
      ),
      Settings.define(@domain_key, :boolean,
        default: true,
        category: "security",
        group: group,
        scope: :both,
        resolve: :own,
        label: gettext_noop("Refuse a check solved on another address"),
        description:
          gettext_noop(
            "The provider says which address the check was solved on, and it must be this site's own. Turn it off only for a key several addresses share."
          ),
        visible: &(&1[@provider_key] not in [nil, "", "none"])
      )
    ] ++
      Enum.flat_map(providers, fn provider ->
        Enum.map(provider.settings(), &Settings.shown_when(&1, @provider_key, provider.id()))
      end)
  end

  @doc """
  Provider `site_id` checks with, ready to check: `{:ok, module}`, or `{:error, reason}` —
  `:off` (none chosen), `:unknown_provider` (chosen, but its plugin is gone), `:cannot_run` (chosen,
  while the providers' plugins cannot run) or `:not_ready` (chosen, but missing a key).
  """
  @spec provider(site_id()) ::
          {:ok, module()} | {:error, :off | :unknown_provider | :cannot_run | :not_ready}
  def provider(site_id) do
    case Settings.get_own(@provider_key, "none", site_id) do
      blank when blank in [nil, "", "none"] ->
        {:error, :off}

      id ->
        with {:ok, provider} <- Provider.fetch(id) do
          if provider.ready?(site_id), do: {:ok, provider}, else: {:error, :not_ready}
        end
    end
  end

  @doc "Whether `site_id`'s forms ask a captcha now."
  @spec on?(site_id()) :: boolean()
  def on?(site_id), do: match?({:ok, _}, provider(site_id))

  @doc """
  How the browser draws `site_id`'s check for `form` in `language` — the provider's
  `c:MishkaCmsCore.Captcha.Provider.browser/3` with its `:provider` id — or `nil` when it asks none.
  """
  @spec browser(site_id(), form(), String.t()) :: map() | nil
  def browser(site_id, form, language) do
    case provider(site_id) do
      {:ok, provider} ->
        site_id |> provider.browser(form, language) |> Map.put(:provider, provider.id())

      {:error, _asks_none} ->
        nil
    end
  end

  @doc """
  The origins, by CSP directive, the browser loads the captcha of any of `site_ids` from — none for
  a scope that asks none. `:all` names every offered provider's, for the settings page, where any of
  them may be tried.
  """
  @spec csp_sources([site_id()] | :all) :: %{optional(atom()) => [String.t()]}
  def csp_sources(:all), do: merge(Provider.offered())

  def csp_sources(site_ids) do
    site_ids
    |> Enum.uniq()
    |> Enum.flat_map(fn site_id ->
      case provider(site_id) do
        {:ok, provider} -> [provider]
        {:error, _asks_none} -> []
      end
    end)
    |> merge()
  end

  defp merge(providers) do
    providers
    |> Enum.map(& &1.csp())
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _directive, a, b -> Enum.uniq(a ++ b) end))
  end

  @doc """
  Checks `token`, sent with `form` to `site_id`: `:ok` when it passed or the scope asks none;
  `{:error, :missing}` without one; `{:error, {:failed, detail}}` when it was used before, the
  provider refused it, it was solved on another address, or the provider the scope chose does not
  answer; `{:error, {:unavailable, detail}}` when the provider could not be asked.
  """
  @spec check(String.t() | nil, site_id(), form(), request()) :: answer()
  def check(token, site_id, form, request) do
    case provider(site_id) do
      {:ok, provider} ->
        with {:ok, _answer} <- verify(provider, token, site_id, form, request), do: :ok

      {:error, missing} when missing in [:unknown_provider, :cannot_run] ->
        {:error, {:failed, "the chosen captcha provider did not answer"}}

      {:error, _asks_none} ->
        :ok
    end
  end

  @doc """
  The settings page's test of `site_id`'s keys with a `token` solved on it: what to tell the admin,
  `{:ok, text}` or `{:error, text}`. The same check a form gets, so a passed test spends the token.
  """
  @spec test(site_id(), String.t() | nil, request()) :: {:ok, String.t()} | {:error, String.t()}
  def test(site_id, token, request) do
    case provider(site_id) do
      {:ok, provider} -> tested(provider, verify(provider, token, site_id, :test, request))
      {:error, reason} -> {:error, not_asked(reason)}
    end
  end

  defp tested(provider, {:ok, %{test?: true}}),
    do:
      {:ok,
       gettext(
         "%{provider} accepted the check — with its test keys, which pass everything. Use real keys on a live site.",
         provider: label(provider)
       )}

  defp tested(provider, {:ok, _answer}),
    do:
      {:ok, gettext("The keys work: %{provider} accepted the check.", provider: label(provider))}

  defp tested(_provider, {:error, :missing}),
    do: {:error, gettext("Solve the check first, then press Test.")}

  defp tested(provider, {:error, {:failed, detail}}),
    do:
      {:error,
       gettext("%{provider} refused the check: %{detail}",
         provider: label(provider),
         detail: detail
       )}

  defp tested(provider, {:error, {:unavailable, detail}}),
    do:
      {:error,
       gettext("%{provider} could not check it: %{detail}. Check the secret key.",
         provider: label(provider),
         detail: detail
       )}

  defp not_asked(:off), do: gettext("No captcha is chosen for this scope: choose one and save.")

  defp not_asked(:unknown_provider),
    do:
      gettext(
        "The captcha chosen for this scope is not installed any more, so every check is refused: choose another or None."
      )

  defp not_asked(:not_ready), do: gettext("Enter both keys and save, then test.")

  defp not_asked(:cannot_run),
    do:
      gettext(
        "The captcha providers' plugins are not loaded, so every check is refused until they are."
      )

  defp label(provider), do: Gettext.gettext(MishkaCmsCore.Gettext, provider.label())

  defp verify(_provider, token, _site_id, _form, _request) when token in [nil, ""],
    do: {:error, :missing}

  defp verify(_provider, token, _site_id, _form, _request) when byte_size(token) > @max_token,
    do: {:error, {:failed, "token too long"}}

  defp verify(provider, token, site_id, form, request) do
    key = used_key(token)

    with :ok <- unused(key),
         {:ok, answer} <- provider.verify(token, site_id, Map.put(request, :form, form)),
         :ok <- solved_here(answer, site_id) do
      used(key, answer)
      {:ok, answer}
    end
  end

  # A TOKEN A PROVIDER ACCEPTED IS REMEMBERED, and refused again before the provider is asked. One it
  # refused needs no remembering — it would refuse it again — and neither does a test key's
  # (`test?: true`): those hand out one same token every time, and accept it every time.
  defp used_key(token),
    do: "captcha:used:" <> (:sha256 |> :crypto.hash(token) |> Base.url_encode64(padding: false))

  defp unused(key) do
    if RateLimitState.get(key, @lifetime) > 0,
      do: {:error, {:failed, "token already used"}},
      else: :ok
  end

  defp used(_key, %{test?: true}), do: :ok
  defp used(key, _answer), do: RateLimitState.inc(key, @lifetime)

  # AN ANSWER THAT NAMES NO ADDRESS cannot show it was solved here, and is refused while the check is
  # on — only a test key's is let through.
  defp solved_here(%{test?: true}, _site_id), do: :ok

  defp solved_here(answer, site_id) do
    expected = host(site_id)
    hostname = answer[:hostname]

    cond do
      Settings.get_own(@domain_key, true, site_id) == false -> :ok
      is_nil(expected) -> :ok
      not is_binary(hostname) -> {:error, {:failed, "no address in the answer"}}
      String.downcase(hostname) == String.downcase(expected) -> :ok
      true -> {:error, {:failed, "solved on #{hostname}, not #{expected}"}}
    end
  end

  # Global is the masters' own sign-in, on the master site's address.
  defp host(nil) do
    case SiteState.get_by_master() do
      {:ok, %{host: host}} -> host
      _none -> nil
    end
  end

  defp host(site_id) do
    case SiteState.get!(site_id) do
      %{host: host} -> host
      nil -> nil
    end
  end
end
