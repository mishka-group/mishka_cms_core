# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Captcha.Providers.Turnstile do
  @moduledoc """
  [Cloudflare Turnstile](https://developers.cloudflare.com/turnstile/) as a captcha provider.

  Each scope keeps its own widget: its site key (`security.captcha.turnstile.site_key`) and its
  secret key (`security.captcha.turnstile.secret_key`, a `:secret` setting). Whether the visitor
  sees a box, a box that rarely asks anything, or nothing at all is the widget's mode, chosen in
  Cloudflare's dashboard — the same code draws all three. The widget's hostname list there decides
  where it may be drawn.

  A token is good for five minutes and one check. Cloudflare's published test keys draw a box that
  always passes (`1x00000000000000000000AA`) or always fails (`2x00000000000000000000AB`), and
  verify with any token: always (`1x0000000000000000000000000000000AA`), never
  (`2x0000000000000000000000000000000AA`), or as already spent (`3x0000000000000000000000000000000AA`).
  They answer the same token and hostname wherever they were solved, so a test key's answer is held
  neither to the site's address nor to the form, and not remembered as used.
  """

  use MishkaCmsCore.Captcha.Provider,
    id: "turnstile",
    label: gettext_noop("Cloudflare Turnstile"),
    priority: 10

  @site_key "security.captcha.turnstile.site_key"
  @secret "security.captcha.turnstile.secret_key"

  @script "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
  @verify "https://challenges.cloudflare.com/turnstile/v0/siteverify"
  @origin "https://challenges.cloudflare.com"

  @test_secrets ~w(1x0000000000000000000000000000000AA 2x0000000000000000000000000000000AA 3x0000000000000000000000000000000AA)

  # The two-letter codes Turnstile draws its box in; any other language leaves it to the browser's.
  @languages ~w(ar bg zh hr cs da nl en fa fi fr de el he hi hu id it ja ko lt ms nb pl pt ro ru sr sk sl es sv tl th tr uk vi)

  @impl true
  def settings do
    [
      site_key(@site_key, gettext_noop("Turnstile site key"),
        group: gettext_noop("Cloudflare Turnstile"),
        description:
          gettext_noop(
            "From the widget made for this site in Cloudflare's dashboard, under Turnstile. Its hostname list must name this site's address."
          )
      ),
      secret(@secret, gettext_noop("Turnstile secret key"),
        group: gettext_noop("Cloudflare Turnstile"),
        description: gettext_noop("From the same widget. Stored sealed and never shown again.")
      )
    ]
  end

  @impl true
  def ready?(site_id), do: own(@site_key, site_id) != nil and secret?(@secret, site_id)

  @impl true
  def browser(site_id, form, language) do
    %{
      script: @script,
      global: "turnstile",
      mode: :widget,
      options: %{
        "sitekey" => own(@site_key, site_id),
        "action" => Atom.to_string(form),
        "language" => if(language in @languages, do: language, else: "auto"),
        "theme" => "light",
        "refresh-expired" => "auto",
        "response-field" => false
      }
    }
  end

  @impl true
  def csp, do: %{script_src: [@origin], frame_src: [@origin]}

  @impl true
  def verify(token, site_id, request) do
    case Settings.secret(@secret, site_id) do
      nil ->
        {:error, {:unavailable, "no secret key"}}

      secret ->
        with {:ok, answer} <-
               siteverify(@verify, %{
                 secret: secret,
                 response: token,
                 remoteip: request[:remote_ip]
               }) do
          answered(answer, secret in @test_secrets, request[:form])
        end
    end
  end

  # THE FORM IT WAS SOLVED FOR, as Cloudflare advises: a token from one form does not pass another.
  # The test keys answer an action of their own.
  defp answered(answer, true = _test?, _form),
    do: {:ok, %{hostname: answer["hostname"], test?: true}}

  defp answered(%{"action" => action} = answer, false, form) do
    if action == Atom.to_string(form),
      do: {:ok, %{hostname: answer["hostname"], test?: false}},
      else: {:error, {:failed, "action #{inspect(action)}, not #{form}"}}
  end

  defp answered(answer, false, _form), do: {:ok, %{hostname: answer["hostname"], test?: false}}
end
