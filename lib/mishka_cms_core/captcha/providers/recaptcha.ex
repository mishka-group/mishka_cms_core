defmodule MishkaCmsCore.Captcha.Providers.Recaptcha do
  @moduledoc """
  [Google reCAPTCHA](https://developers.google.com/recaptcha) as a captcha provider, in either of
  its two kinds — a key is made for one of them in Google's admin console:

    * **v2** (`"v2"`) — the "I'm not a robot" box, drawn above the form's button;
    * **v3** (`"v3"`) — nothing to click: Google scores the visitor from 0 to 1 as the form is sent,
      and a score under `security.captcha.recaptcha.min_score` (out of 100) is refused. Google's
      badge shows in a corner of the page.

  Each scope keeps its own site key, secret key, kind and lowest score. A token is good for two
  minutes and one check; a v3 token must also name the form it was asked for.

  Google's published v2 test keys (site key `6LeIxAcTAAAAAJcZVRqyHh71UMIEGNQ_MXjiZKhI`, secret
  `6LeIxAcTAAAAAGG-vFI1TnRWxMZNFuojJ4WifJWe`) pass every check on any address (`test?: true`), so
  their answer is not held to the site's address, nor remembered as used. v3 has none: test it with a
  key of its own that lists `localhost`.
  """

  use MishkaCmsCore.Captcha.Provider,
    id: "recaptcha",
    label: gettext_noop("Google reCAPTCHA"),
    priority: 20

  @site_key "security.captcha.recaptcha.site_key"
  @secret "security.captcha.recaptcha.secret_key"
  @version "security.captcha.recaptcha.version"
  @min_score "security.captcha.recaptcha.min_score"

  @script "https://www.google.com/recaptcha/api.js"
  @verify "https://www.google.com/recaptcha/api/siteverify"

  @test_secrets ["6LeIxAcTAAAAAGG-vFI1TnRWxMZNFuojJ4WifJWe"]

  @impl true
  def settings do
    group = gettext_noop("Google reCAPTCHA")

    [
      Settings.define(@version, :select,
        default: "v2",
        category: "security",
        group: group,
        scope: :both,
        resolve: :own,
        source: :plugin,
        label: gettext_noop("reCAPTCHA kind"),
        description:
          gettext_noop(
            "The kind the key below was made for in Google's admin console: v2 shows the \"I'm not a robot\" box, v3 asks nothing and scores the visitor."
          ),
        options: [
          {gettext_noop("v2 — the \"I'm not a robot\" box"), "v2"},
          {gettext_noop("v3 — invisible, by score"), "v3"}
        ]
      ),
      site_key(@site_key, gettext_noop("reCAPTCHA site key"),
        group: group,
        description:
          gettext_noop(
            "From the key made for this site in Google's reCAPTCHA admin console. Its domain list must name this site's address."
          )
      ),
      secret(@secret, gettext_noop("reCAPTCHA secret key"),
        group: group,
        description: gettext_noop("From the same key. Stored sealed and never shown again.")
      ),
      Settings.define(@min_score, :integer,
        default: 50,
        min: 1,
        max: 100,
        category: "security",
        group: group,
        scope: :both,
        resolve: :own,
        source: :plugin,
        label: gettext_noop("Lowest v3 score let through (out of 100)"),
        visible: &(&1[@version] == "v3"),
        description:
          gettext_noop(
            "v3 only. Google scores a visitor from 0, a bot, to 100, a person; a form sent with a lower score is refused. Google suggests 50."
          )
      )
    ]
  end

  @impl true
  def ready?(site_id), do: own(@site_key, site_id) != nil and secret?(@secret, site_id)

  @impl true
  def browser(site_id, form, language) do
    site_key = own(@site_key, site_id)

    case version(site_id) do
      "v3" ->
        %{
          script: @script <> "?" <> URI.encode_query(render: site_key, hl: language),
          global: "grecaptcha",
          mode: :score,
          options: %{"sitekey" => site_key, "action" => Atom.to_string(form)}
        }

      _v2 ->
        %{
          script: @script <> "?" <> URI.encode_query(render: "explicit", hl: language),
          global: "grecaptcha",
          mode: :widget,
          options: %{"sitekey" => site_key, "theme" => "light"}
        }
    end
  end

  @impl true
  def csp do
    %{
      script_src: ["https://www.google.com/recaptcha/", "https://www.gstatic.com/recaptcha/"],
      frame_src: ["https://www.google.com/recaptcha/", "https://recaptcha.google.com/recaptcha/"]
    }
  end

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
          answered(answer, secret in @test_secrets, version(site_id), site_id, request[:form])
        end
    end
  end

  defp answered(answer, test?, "v3", site_id, form) do
    score = answer["score"]
    lowest = min_score(site_id)

    cond do
      answer["action"] != Atom.to_string(form) ->
        {:error, {:failed, "action #{inspect(answer["action"])}, not #{form}"}}

      not is_number(score) or score * 100 < lowest ->
        {:error, {:failed, "score #{inspect(score)}, below #{lowest / 100}"}}

      true ->
        {:ok, %{hostname: answer["hostname"], test?: test?}}
    end
  end

  defp answered(answer, test?, _v2, _site_id, _form),
    do: {:ok, %{hostname: answer["hostname"], test?: test?}}

  defp version(site_id), do: Settings.get_own(@version, "v2", site_id)

  defp min_score(site_id) do
    case Settings.get_own(@min_score, 50, site_id) do
      score when is_integer(score) and score in 1..100 -> score
      _unset -> 50
    end
  end
end
