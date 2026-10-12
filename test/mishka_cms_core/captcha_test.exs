defmodule MishkaCmsCore.CaptchaTest do
  @moduledoc """
  `MishkaCmsCore.Captcha` and its two providers, Cloudflare Turnstile and Google reCAPTCHA: which
  provider a scope asks, how the browser is told to draw it, which origins the security headers
  allow, and one check — a used token refused before anybody is asked, the provider's answer read,
  held to the site's address — with the providers' servers answered by `Req.Test` stubs.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Captcha
  alias MishkaCmsCore.Captcha.Provider
  alias MishkaCmsCore.Captcha.Providers.{HCaptcha, Recaptcha, Turnstile}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  setup do
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()

    host = "captcha-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true,
        master: false
      })

    on_exit(fn ->
      SettingsState.restore(snapshot)
      SiteState.delete(site.id)
    end)

    %{site: site}
  end

  describe "the providers" do
    test "Turnstile, reCAPTCHA and hCaptcha are installed as plugins on captcha:providers" do
      assert Turnstile in Provider.offered()
      assert Recaptcha in Provider.offered()
      assert HCaptcha in Provider.offered()
      assert {:ok, Turnstile} = Provider.fetch("turnstile")
      assert {:error, :unknown_provider} = Provider.fetch("nope")
    end

    test "the Security tab offers them, each with its own keys", %{site: _site} do
      keys = Enum.map(Captcha.settings(), & &1.key)

      assert "security.captcha.provider" in keys
      assert "security.captcha.turnstile.secret_key" in keys
      assert "security.captcha.recaptcha.min_score" in keys

      provider = Settings.definition("security.captcha.provider")
      assert {_none, "none"} = hd(provider.options)
      assert Enum.any?(provider.options, &match?({_label, "turnstile"}, &1))
      assert Settings.definition("security.captcha.turnstile.secret_key").type == :secret
    end
  end

  describe "which provider a scope asks" do
    test "none until one is chosen, and none while a key is missing", %{site: site} do
      assert Captcha.provider(site.id) == {:error, :off}

      put!(site, "security.captcha.provider", "turnstile")
      assert Captcha.provider(site.id) == {:error, :not_ready}

      put!(site, "security.captcha.turnstile.site_key", "site-key")
      assert Captcha.provider(site.id) == {:error, :not_ready}

      put!(site, "security.captcha.turnstile.secret_key", "secret")
      assert Captcha.provider(site.id) == {:ok, Turnstile}
    end

    test "each scope its own: a site never borrows Global's keys", %{site: site} do
      turnstile!(nil)

      assert Captcha.on?(nil)
      refute Captcha.on?(site.id)
    end

    test "a secret this server cannot open — sealed under another SECRET_KEY_BASE — asks nothing",
         %{site: site} do
      turnstile!(site)
      assert Captcha.on?(site.id)

      SettingsState.put(site.id, "security.captcha.turnstile.secret_key", %{
        "value" => "sealed-under-an-old-key"
      })

      assert Captcha.provider(site.id) == {:error, :not_ready}
      assert Captcha.browser(site.id, :sign_in, "en") == nil
      assert Settings.secret_hint("security.captcha.turnstile.secret_key", site.id) == :unreadable
    end

    test "a provider whose plugin is gone refuses every check, until the scope chooses None",
         %{site: site} do
      put!(site, "security.captcha.provider", "gone")

      assert Captcha.provider(site.id) == {:error, :unknown_provider}
      assert {:error, {:failed, _detail}} = Captcha.check(token("pass"), site.id, :sign_in, %{})

      put!(site, "security.captcha.provider", "none")
      assert Captcha.check(nil, site.id, :sign_in, %{}) == :ok
    end

    test "a scope that chose one refuses every check while the providers' plugins cannot run",
         %{site: site} do
      turnstile!(site)
      MishkaCmsCore.Test.EventCannotRun.stub!(Provider.event())

      assert Captcha.provider(site.id) == {:error, :cannot_run}
      refute Captcha.on?(site.id)
      assert {:error, {:failed, _detail}} = Captcha.check(token("pass"), site.id, :sign_in, %{})
    end

    test "a scope that chose none asks nothing while they cannot run", %{site: site} do
      MishkaCmsCore.Test.EventCannotRun.stub!(Provider.event())

      assert Captcha.check(nil, site.id, :sign_in, %{}) == :ok
    end

    test "the secret key is stored sealed", %{site: site} do
      turnstile!(site)

      refute Settings.get_own("security.captcha.turnstile.secret_key", nil, site.id) ==
               "1x0000000000000000000000000000000AA"

      assert Settings.secret("security.captcha.turnstile.secret_key", site.id) ==
               "1x0000000000000000000000000000000AA"
    end
  end

  describe "the browser" do
    test "Turnstile is a widget drawn with the site key, the form and a language it knows", %{
      site: site
    } do
      turnstile!(site)

      browser = Captcha.browser(site.id, :register, "fa")

      assert browser.provider == "turnstile"
      assert browser.mode == :widget
      assert browser.global == "turnstile"
      assert browser.script =~ "challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"

      assert %{
               "sitekey" => "1x00000000000000000000AA",
               "action" => "register",
               "language" => "fa"
             } =
               browser.options

      assert Captcha.browser(site.id, :register, "xx").options["language"] == "auto"
    end

    test "reCAPTCHA v2 is a widget, v3 a score asked as the form is sent", %{site: site} do
      recaptcha!(site, "v2")
      v2 = Captcha.browser(site.id, :sign_in, "en")

      assert v2.mode == :widget
      assert v2.script =~ "render=explicit"
      assert v2.script =~ "hl=en"

      put!(site, "security.captcha.recaptcha.version", "v3")
      v3 = Captcha.browser(site.id, :sign_in, "en")

      assert v3.mode == :score
      assert v3.script =~ "render=recaptcha-site-key"
      assert v3.options == %{"sitekey" => "recaptcha-site-key", "action" => "sign_in"}
    end

    test "nothing for a scope that asks none", %{site: site} do
      assert Captcha.browser(site.id, :sign_in, "en") == nil
    end
  end

  describe "the origins the security headers allow" do
    test "the provider a site uses, and nothing for one that uses none", %{site: site} do
      assert Captcha.csp_sources([site.id]) == %{}

      turnstile!(site)

      assert Captcha.csp_sources([site.id]) == %{
               script_src: ["https://challenges.cloudflare.com"],
               frame_src: ["https://challenges.cloudflare.com"]
             }
    end

    test "every offered provider's, for the settings page" do
      sources = Captcha.csp_sources(:all)

      assert "https://challenges.cloudflare.com" in sources.script_src
      assert "https://www.gstatic.com/recaptcha/" in sources.script_src
      assert "https://recaptcha.google.com/recaptcha/" in sources.frame_src
    end
  end

  describe "the security headers" do
    test "name the provider's origins on a site that uses it, and only there", %{site: site} do
      refute policy("/en/auth", site) =~ "challenges.cloudflare.com"

      turnstile!(site)
      policy = policy("/en/auth", site)

      assert policy =~ "script-src 'self' 'nonce-"
      assert policy =~ ~r/script-src [^;]*https:\/\/challenges\.cloudflare\.com/
      assert policy =~ "frame-src 'self' https://challenges.cloudflare.com"

      other = create_site!(name: "other.test", host: "other.test", active: true)
      refute policy("/en/auth", %{id: other.id, master: false}) =~ "cloudflare"
    end

    test "the master site's pages carry Global's too, which the masters' sign-in asks", %{
      site: site
    } do
      turnstile!(nil)

      refute policy("/en/auth", %{id: site.id, master: false}) =~ "cloudflare"
      assert policy("/en/auth", %{id: site.id, master: true}) =~ "cloudflare"
    end

    test "every admin page carries every offered provider's: live navigation keeps the first page's",
         %{site: site} do
      for path <- ["/admin/dashboard/settings", "/admin/dashboard"] do
        policy = policy(path, site)

        assert policy =~ "https://www.gstatic.com/recaptcha/", path
        assert policy =~ "https://challenges.cloudflare.com", path
        assert policy =~ "https://*.hcaptcha.com", path
      end
    end
  end

  describe "a check" do
    setup %{site: site} do
      turnstile!(site)
      :ok
    end

    test "passes a token Cloudflare accepts, sending it the secret, the token and the address", %{
      site: site
    } do
      Req.Test.expect(MishkaCmsCore.Captcha, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        fields = URI.decode_query(body)

        assert conn.request_path == "/turnstile/v0/siteverify"
        assert fields["secret"] == "1x0000000000000000000000000000000AA"
        assert fields["response"] =~ "pass-"
        assert fields["remoteip"] == "203.0.113.9"

        Req.Test.json(conn, %{"success" => true, "hostname" => "localhost"})
      end)

      assert Captcha.check(token("pass"), site.id, :sign_in, %{remote_ip: "203.0.113.9"}) == :ok
    end

    test "refuses a missing token without asking anybody", %{site: site} do
      assert Captcha.check(nil, site.id, :sign_in, %{}) == {:error, :missing}
      assert Captcha.check("", site.id, :sign_in, %{}) == {:error, :missing}
    end

    test "refuses a token accepted before, without asking Cloudflare again", %{site: site} do
      put!(site, "security.captcha.turnstile.secret_key", "0x-a-real-secret")

      Req.Test.expect(
        MishkaCmsCore.Captcha,
        1,
        &Req.Test.json(&1, %{"success" => true, "hostname" => site.host})
      )

      once = token("once")

      assert Captcha.check(once, site.id, :sign_in, %{}) == :ok

      assert {:error, {:failed, "token already used"}} =
               Captcha.check(once, site.id, :sign_in, %{})
    end

    test "remembers no token a test key accepted: they hand out one same token", %{site: site} do
      answer!(%{"success" => true})

      assert Captcha.check("XXXX.DUMMY.TOKEN.XXXX", site.id, :sign_in, %{}) == :ok
      assert Captcha.check("XXXX.DUMMY.TOKEN.XXXX", site.id, :sign_in, %{}) == :ok
    end

    test "refuses a token Cloudflare refuses", %{site: site} do
      answer!(%{"success" => false, "error-codes" => ["timeout-or-duplicate"]})

      assert {:error, {:failed, "timeout-or-duplicate"}} =
               Captcha.check(token("old"), site.id, :sign_in, %{})
    end

    test "refuses every other answer: no reason, an unknown one, a malformed request, a 4xx", %{
      site: site
    } do
      for {answer, detail} <- [
            {%{"success" => false}, "refused"},
            {%{"success" => false, "error-codes" => ["bad-request"]}, "bad-request"},
            {%{"success" => false, "error-codes" => ["something-new"]}, "something-new"},
            {%{"no" => "answer"}, "refused"}
          ] do
        answer!(answer)

        assert Captcha.check(token("odd"), site.id, :sign_in, %{}) == {:error, {:failed, detail}},
               "let through: #{inspect(answer)}"
      end

      Req.Test.stub(MishkaCmsCore.Captcha, &Plug.Conn.send_resp(&1, 413, "too large"))

      assert Captcha.check(token("big"), site.id, :sign_in, %{}) ==
               {:error, {:failed, "HTTP 413"}}
    end

    test "refuses a token too long to be one, without asking Cloudflare", %{site: site} do
      Req.Test.stub(MishkaCmsCore.Captcha, fn _conn -> flunk("Cloudflare was asked") end)

      assert Captcha.check(String.duplicate("a", 8_193), site.id, :sign_in, %{}) ==
               {:error, {:failed, "token too long"}}
    end

    test "cannot check when Cloudflare refuses the keys, is down or does not answer", %{
      site: site
    } do
      answer!(%{"success" => false, "error-codes" => ["invalid-input-secret"]})

      assert {:error, {:unavailable, "invalid-input-secret"}} =
               Captcha.check(token("key"), site.id, :sign_in, %{})

      Req.Test.stub(MishkaCmsCore.Captcha, &Plug.Conn.send_resp(&1, 503, "down"))

      assert {:error, {:unavailable, "HTTP 503"}} =
               Captcha.check(token("down"), site.id, :sign_in, %{})

      Req.Test.stub(MishkaCmsCore.Captcha, &Req.Test.transport_error(&1, :timeout))

      assert {:error, {:unavailable, _timeout}} =
               Captcha.check(token("slow"), site.id, :sign_in, %{})
    end

    test "holds a real key's answer to the site's address, unless the site turned that off", %{
      site: site
    } do
      put!(site, "security.captcha.turnstile.secret_key", "0x-a-real-secret")
      answer!(%{"success" => true, "hostname" => "elsewhere.test"})

      assert {:error, {:failed, "solved on elsewhere.test, not " <> _host}} =
               Captcha.check(token("away"), site.id, :sign_in, %{})

      answer!(%{"success" => true, "hostname" => String.upcase(site.host)})
      assert Captcha.check(token("home"), site.id, :sign_in, %{}) == :ok

      answer!(%{"success" => true})

      assert {:error, {:failed, "no address in the answer"}} =
               Captcha.check(token("nowhere"), site.id, :sign_in, %{})

      put!(site, "security.captcha.check_domain", false)
      answer!(%{"success" => true, "hostname" => "elsewhere.test"})
      assert Captcha.check(token("shared"), site.id, :sign_in, %{}) == :ok
    end

    test "holds a real key's token to the form it was solved for", %{site: site} do
      put!(site, "security.captcha.turnstile.secret_key", "0x-a-real-secret")
      answer!(%{"success" => true, "hostname" => site.host, "action" => "register"})

      assert {:error, {:failed, "action \"register\", not sign_in"}} =
               Captcha.check(token("other-form"), site.id, :sign_in, %{})

      assert Captcha.check(token("this-form"), site.id, :register, %{}) == :ok
    end

    test "a test key's answer names no address to hold it to", %{site: site} do
      answer!(%{"success" => true, "hostname" => "example.com"})

      assert Captcha.check(token("dummy"), site.id, :sign_in, %{}) == :ok
    end
  end

  describe "hCaptcha" do
    setup %{site: site} do
      put!(site, "security.captcha.provider", "hcaptcha")
      put!(site, "security.captcha.hcaptcha.site_key", "10000000-ffff-ffff-ffff-000000000001")

      put!(
        site,
        "security.captcha.hcaptcha.secret_key",
        "0x0000000000000000000000000000000000000000"
      )

      :ok
    end

    test "is a widget, in the page's language, loaded from hCaptcha's origins", %{site: site} do
      browser = Captcha.browser(site.id, :sign_in, "fa")

      assert browser.mode == :widget
      assert browser.global == "hcaptcha"
      assert browser.script =~ "https://js.hcaptcha.com/1/api.js?render=explicit&hl=fa"
      assert browser.options["sitekey"] == "10000000-ffff-ffff-ffff-000000000001"

      sources = Captcha.csp_sources([site.id])
      assert "https://*.hcaptcha.com" in sources.script_src
      assert "https://*.hcaptcha.com" in sources.style_src
    end

    test "sends the site key with the token, and passes what hCaptcha accepts", %{site: site} do
      Req.Test.expect(MishkaCmsCore.Captcha, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        fields = URI.decode_query(body)

        assert conn.host == "api.hcaptcha.com"
        assert fields["sitekey"] == "10000000-ffff-ffff-ffff-000000000001"
        assert fields["secret"] == "0x0000000000000000000000000000000000000000"

        Req.Test.json(conn, %{"success" => true, "hostname" => "dummy-key-pass"})
      end)

      assert Captcha.check(token("h"), site.id, :register, %{}) == :ok
    end

    test "refuses a token hCaptcha refuses; cannot check with a key it refuses", %{site: site} do
      answer!(%{"success" => false, "error-codes" => ["already-seen-response"]})

      assert {:error, {:failed, "already-seen-response"}} =
               Captcha.check(token("seen"), site.id, :sign_in, %{})

      answer!(%{"success" => false, "error-codes" => ["sitekey-secret-mismatch"]})

      assert {:error, {:unavailable, "sitekey-secret-mismatch"}} =
               Captcha.check(token("mismatch"), site.id, :sign_in, %{})
    end
  end

  describe "a reCAPTCHA v3 check" do
    setup %{site: site} do
      recaptcha!(site, "v3")
      put!(site, "security.captcha.check_domain", false)
      :ok
    end

    test "passes a score at or above the lowest, for the form it was asked for", %{site: site} do
      answer!(%{"success" => true, "score" => 0.5, "action" => "sign_in"})

      assert Captcha.check(token("person"), site.id, :sign_in, %{}) == :ok
    end

    test "refuses a lower score, and a token asked for another form", %{site: site} do
      put!(site, "security.captcha.recaptcha.min_score", 70)
      answer!(%{"success" => true, "score" => 0.6, "action" => "sign_in"})

      assert {:error, {:failed, "score 0.6, below 0.7"}} =
               Captcha.check(token("bot"), site.id, :sign_in, %{})

      answer!(%{"success" => true, "score" => 0.9, "action" => "register"})

      assert {:error, {:failed, "action \"register\", not sign_in"}} =
               Captcha.check(token("elsewhere"), site.id, :sign_in, %{})
    end
  end

  describe "the settings page's test" do
    test "says why nothing can be tested, then what the provider answered", %{site: site} do
      assert {:error, "No captcha is chosen" <> _} = Captcha.test(site.id, "t", %{})

      put!(site, "security.captcha.provider", "turnstile")
      assert {:error, "Enter both keys" <> _} = Captcha.test(site.id, "t", %{})

      turnstile!(site)
      assert {:error, "Solve the check first" <> _} = Captcha.test(site.id, "", %{})

      answer!(%{"success" => true})

      assert {:ok, "Cloudflare Turnstile accepted the check — with its test keys" <> _} =
               Captcha.test(site.id, token("dummy"), %{})

      answer!(%{"success" => false, "error-codes" => ["invalid-input-secret"]})

      assert {:error, "Cloudflare Turnstile could not check it: invalid-input-secret" <> _} =
               Captcha.test(site.id, token("bad-key"), %{})
    end

    test "says the keys work when real keys pass", %{site: site} do
      turnstile!(site)
      put!(site, "security.captcha.turnstile.secret_key", "0x-a-real-secret")
      answer!(%{"success" => true, "hostname" => site.host})

      assert {:ok, "The keys work" <> _} = Captcha.test(site.id, token("real"), %{})
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp put!(site, key, value),
    do: {:ok, _} = Settings.put(key, value, site_id: site && site.id)

  defp turnstile!(site) do
    put!(site, "security.captcha.provider", "turnstile")
    put!(site, "security.captcha.turnstile.site_key", "1x00000000000000000000AA")
    put!(site, "security.captcha.turnstile.secret_key", "1x0000000000000000000000000000000AA")
  end

  defp recaptcha!(site, version) do
    put!(site, "security.captcha.provider", "recaptcha")
    put!(site, "security.captcha.recaptcha.version", version)
    put!(site, "security.captcha.recaptcha.site_key", "recaptcha-site-key")
    put!(site, "security.captcha.recaptcha.secret_key", "recaptcha-secret")
  end

  defp policy(path, site) do
    Plug.Test.conn(:get, path)
    |> Plug.Conn.assign(:current_site, site)
    |> MishkaCmsWeb.Runtime.Plugs.SecurityHeaders.call([])
    |> Plug.Conn.get_resp_header("content-security-policy-report-only")
    |> List.first()
  end

  defp answer!(json), do: Req.Test.stub(MishkaCmsCore.Captcha, &Req.Test.json(&1, json))

  # A token of its own for every check: a token seen once is refused for five minutes.
  defp token(name), do: "#{name}-#{System.unique_integer([:positive])}"
end
