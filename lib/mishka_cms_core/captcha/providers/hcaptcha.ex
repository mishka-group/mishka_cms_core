defmodule MishkaCmsCore.Captcha.Providers.HCaptcha do
  @moduledoc """
  [hCaptcha](https://docs.hcaptcha.com/) as a captcha provider: a box the visitor ticks, which may ask
  a challenge.

  Each scope keeps its own site key (`security.captcha.hcaptcha.site_key`) and secret key
  (`security.captcha.hcaptcha.secret_key`, a `:secret` setting). The site key goes with every check,
  so a token solved for another key is refused. A token is good for one check, within two minutes.

  hCaptcha's published test keys — site key `10000000-ffff-ffff-ffff-000000000001`, secret
  `0x0000000000000000000000000000000000000000` — pass every check (`test?: true`), so their answer is
  not held to the site's address, nor remembered as used.
  """

  use MishkaCmsCore.Captcha.Provider,
    id: "hcaptcha",
    label: gettext_noop("hCaptcha"),
    priority: 30

  @site_key "security.captcha.hcaptcha.site_key"
  @secret "security.captcha.hcaptcha.secret_key"

  @script "https://js.hcaptcha.com/1/api.js"
  @verify "https://api.hcaptcha.com/siteverify"
  @origins ["https://hcaptcha.com", "https://*.hcaptcha.com"]

  @test_secrets ["0x0000000000000000000000000000000000000000"]

  @impl true
  def settings do
    [
      site_key(@site_key, gettext_noop("hCaptcha site key"),
        group: gettext_noop("hCaptcha"),
        description:
          gettext_noop(
            "From the site made for this site in hCaptcha's dashboard. Its hostname list must name this site's address."
          )
      ),
      secret(@secret, gettext_noop("hCaptcha secret key"),
        group: gettext_noop("hCaptcha"),
        description:
          gettext_noop(
            "From your hCaptcha account settings. Stored sealed and never shown again."
          )
      )
    ]
  end

  @impl true
  def ready?(site_id), do: own(@site_key, site_id) != nil and secret?(@secret, site_id)

  @impl true
  def browser(site_id, _form, language) do
    %{
      script: @script <> "?" <> URI.encode_query(render: "explicit", hl: language),
      global: "hcaptcha",
      mode: :widget,
      options: %{"sitekey" => own(@site_key, site_id), "theme" => "light"}
    }
  end

  @impl true
  def csp,
    do: %{script_src: @origins, frame_src: @origins, style_src: @origins, connect_src: @origins}

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
                 sitekey: own(@site_key, site_id),
                 remoteip: request[:remote_ip]
               }),
             do: {:ok, %{hostname: answer["hostname"], test?: secret in @test_secrets}}
    end
  end
end
