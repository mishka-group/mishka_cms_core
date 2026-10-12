defmodule MishkaCmsCore.Accounts.CaptchaCheckTest do
  @moduledoc """
  The captcha in the actions a visitor fills a form for (`MishkaCmsCore.Accounts.CaptchaCheck`):
  signing in, registering, asking for a password reset and for a sign-in link. Asked between the
  per-address and the per-account limit, before the password; never asked of the JSON:API, of a call
  made with `authorize?: false`, or of a sign-in's code step; and a provider that cannot be asked
  lets the form through. Cloudflare is a `Req.Test` stub.

  `async: false` — the application environment, the settings cache, `SiteState` and the rate-limit
  table are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{AuthRateLimit, CaptchaCheck, User}
  alias MishkaCmsCore.Accounts.CaptchaCheck.Refused
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  @password "Password123!"

  defmodule Heard do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "auth:captcha:refused"

    @impl true
    def call(data) do
      send(:persistent_term.get({__MODULE__, :test}), {:captcha_refused, data})
      {:reply, data}
    end
  end

  setup do
    previous = Application.fetch_env(:mishka_cms_core, AuthRateLimit)
    Application.delete_env(:mishka_cms_core, AuthRateLimit)
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()

    host = "captcha-check-#{System.unique_integer([:positive])}.test"
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
      with {:ok, env} <- previous, do: Application.put_env(:mishka_cms_core, AuthRateLimit, env)
      SettingsState.restore(snapshot)
      SiteState.delete(site.id)
    end)

    for {key, value} <- [
          {"security.captcha.provider", "turnstile"},
          {"security.captcha.turnstile.site_key", "1x00000000000000000000AA"},
          {"security.captcha.turnstile.secret_key", "1x0000000000000000000000000000000AA"}
        ] do
      {:ok, _} = Settings.put(key, value, site_id: site.id)
    end

    {:ok, site: site, user: user!(site), ip: address!()}
  end

  describe "signing in" do
    test "refuses a form without the token, before the password is checked", ctx do
      assert {:error, error} = sign_in(ctx, nil)
      assert CaptchaCheck.refusal(error) == %{reason: :missing}
    end

    test "refuses a form while the captcha providers' plugins cannot run, asking nobody", ctx do
      MishkaCmsCore.Test.EventCannotRun.stub!(MishkaCmsCore.Captcha.Provider.event())

      assert {:error, error} = sign_in(ctx, token())
      assert CaptchaCheck.refusal(error) == %{reason: :failed}
    end

    test "signs in with a token Cloudflare accepts", ctx do
      pass!()
      assert {:ok, %User{}} = sign_in(ctx, token())
    end

    test "refuses one Cloudflare refuses, and says it as the captcha, not as a wrong password",
         ctx do
      refuse!()

      assert {:error, error} = sign_in(ctx, token())
      assert CaptchaCheck.refusal(error) == %{reason: :failed}
    end

    test "asks nothing of a site with no captcha", ctx do
      {:ok, _} = Settings.put("security.captcha.provider", "none", site_id: ctx.site.id)

      assert {:ok, %User{}} = sign_in(ctx, nil)
    end

    test "lets the form through when Cloudflare cannot be asked", ctx do
      Req.Test.stub(MishkaCmsCore.Captcha, &Plug.Conn.send_resp(&1, 503, "down"))

      assert {:ok, %User{}} = sign_in(ctx, token())
    end

    test "asks nothing of the JSON:API, nor of a call made with authorize?: false", ctx do
      assert {:ok, %User{}} =
               sign_in(ctx, nil, context(%{remote_ip: ctx.ip, api?: true}))

      assert {:ok, %User{}} =
               User
               |> Ash.Query.for_read(
                 :sign_in_with_password,
                 %{email: to_string(ctx.user.email), password: @password},
                 tenant: ctx.site.id,
                 authorize?: false
               )
               |> Ash.read_one()
    end

    test "asks nothing of the code step, once the password step passed it", ctx do
      assert {:ok, %User{}} =
               sign_in(ctx, nil, Map.put(context(%{remote_ip: ctx.ip}), :captcha_passed?, true))
    end

    test "the browser cannot say it passed: an argument named so is not the context", ctx do
      assert {:error, _refused} =
               User
               |> Ash.Query.for_read(
                 :sign_in_with_password,
                 %{
                   "email" => to_string(ctx.user.email),
                   "password" => @password,
                   "captcha_passed?" => "true"
                 },
                 tenant: ctx.site.id,
                 context: context(%{remote_ip: ctx.ip})
               )
               |> Ash.read_one()
    end

    test "is heard by plugins on auth:captcha:refused", ctx do
      :persistent_term.put({Heard, :test}, self())
      listen(Heard, "auth:captcha:refused")

      sign_in(ctx, nil)

      assert_receive {:captcha_refused, %{form: :sign_in, reason: :missing, site_id: site_id}}
      assert site_id == ctx.site.id
    end
  end

  describe "between the two limits" do
    setup do
      limit!("security.sign_in_per_ip", 3)
      limit!("security.sign_in_per_account", 2)
      :ok
    end

    test "attempts that fail the captcha count against their address, not the account", ctx do
      refuse!()

      for _try <- 1..3 do
        assert {:error, error} = sign_in(ctx, token())
        assert CaptchaCheck.refusal(error) == %{reason: :failed}
      end

      assert {:error, error} = sign_in(ctx, token())
      assert limited(error) == %{action: :sign_in, key: :ip}

      pass!()
      assert {:ok, %User{}} = sign_in(%{ctx | ip: address!()}, token())
    end

    test "an address over its limit costs Cloudflare no request", ctx do
      refuse!()
      for _try <- 1..3, do: sign_in(ctx, token())

      Req.Test.stub(MishkaCmsCore.Captcha, fn _conn -> flunk("Cloudflare was asked") end)

      assert {:error, error} = sign_in(ctx, token())
      assert limited(error) == %{action: :sign_in, key: :ip}
    end
  end

  describe "registering" do
    test "refuses a form without the token", ctx do
      assert {:error, error} = register(ctx, nil)
      assert CaptchaCheck.refusal(error) == %{reason: :missing}
    end

    test "registers with a token Cloudflare accepts", ctx do
      pass!()
      assert {:ok, %User{}} = register(ctx, token())
    end

    test "a typo spends no token: invalid fields are refused before Cloudflare is asked", ctx do
      Req.Test.stub(MishkaCmsCore.Captcha, fn _conn -> flunk("Cloudflare was asked") end)

      assert {:error, error} = register(ctx, token(), "NotTheSame123!")
      assert CaptchaCheck.refusal(error) == nil
    end

    test "one address registers no more accounts in an hour than its setting allows", ctx do
      limit!("security.register_per_ip", 2)
      pass!()

      assert {:ok, _} = register(ctx, token())
      assert {:ok, _} = register(ctx, token())
      assert {:error, error} = register(ctx, token())
      assert limited(error) == %{action: :register, key: :ip}
    end

    test "the installer and the seeds are held to neither the limit nor the captcha", ctx do
      limit!("security.register_per_ip", 1)

      for _account <- 1..2 do
        assert {:ok, _} =
                 User
                 |> Ash.Changeset.for_create(
                   :register_with_password,
                   %{email: email!(), password: @password, password_confirmation: @password},
                   tenant: ctx.site.id,
                   authorize?: false,
                   context: context(%{remote_ip: ctx.ip})
                 )
                 |> Ash.create()
      end
    end
  end

  describe "asking for a reset or a sign-in link" do
    test "refuses a request without the token", ctx do
      for action <- [:request_password_reset_token, :request_magic_link] do
        assert {:error, error} = request(ctx, action, nil)
        assert CaptchaCheck.refusal(error) == %{reason: :missing}, "#{action} asked nothing"
      end
    end

    test "asks with a token Cloudflare accepts", ctx do
      pass!()

      for action <- [:request_password_reset_token, :request_magic_link] do
        assert :ok = request(ctx, action, token())
      end
    end
  end

  describe "the refusal" do
    test "is found inside whatever wraps it, and said in words" do
      refused = Refused.exception(reason: :failed, form: :sign_in, site_id: nil)

      assert CaptchaCheck.refusal(Ash.Error.to_error_class(refused)) == %{reason: :failed}
      assert CaptchaCheck.refusal([%{caused_by: refused}]) == %{reason: :failed}
      assert CaptchaCheck.refusal(:something_else) == nil
      assert CaptchaCheck.describe(:missing).title == "Complete the security check"
      assert Exception.message(refused) =~ "The security check did not pass"
    end
  end

  # ---------------------------------------------------------------------------------------------

  # The context AshAuthentication's routes and the sign-in pages run the actions with.
  defp context(request),
    do: %{private: %{ash_authentication?: true}, ash_authentication_request: request}

  defp sign_in(ctx, captcha, context \\ nil) do
    User
    |> Ash.Query.for_read(
      :sign_in_with_password,
      %{email: to_string(ctx.user.email), password: @password, captcha_token: captcha},
      tenant: ctx.site.id,
      context: context || context(%{remote_ip: ctx.ip})
    )
    |> Ash.read_one()
  end

  defp register(ctx, captcha, confirmation \\ @password) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: email!(),
        password: @password,
        password_confirmation: confirmation,
        captcha_token: captcha
      },
      tenant: ctx.site.id,
      context: context(%{remote_ip: ctx.ip})
    )
    |> Ash.create()
  end

  defp request(ctx, action, captcha) do
    User
    |> Ash.ActionInput.for_action(
      action,
      %{email: to_string(ctx.user.email), captcha_token: captcha},
      tenant: ctx.site.id,
      context: context(%{remote_ip: ctx.ip})
    )
    |> Ash.run_action()
  end

  defp user!(site) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email!(), password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.Changeset.set_tenant(site.id)
    |> Ash.create!()
  end

  defp limited(error) do
    case AuthRateLimit.limited(error) do
      %{} = limited -> Map.take(limited, [:action, :key])
      nil -> flunk("not a rate limit: #{inspect(error)}")
    end
  end

  defp limit!(key, value), do: SettingsState.put(nil, key, %{"value" => value})

  defp pass!, do: Req.Test.stub(MishkaCmsCore.Captcha, &Req.Test.json(&1, %{"success" => true}))

  defp refuse!,
    do:
      Req.Test.stub(
        MishkaCmsCore.Captcha,
        &Req.Test.json(&1, %{"success" => false, "error-codes" => ["invalid-input-response"]})
      )

  defp listen(module, event) do
    {:ok, _} =
      Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      Event.unregister(:name, module, false)
      EventHandler.do_compile(event, :start, false)
    end)
  end

  defp token, do: "token-#{System.unique_integer([:positive])}"
  defp email!, do: "captcha-#{System.unique_integer([:positive])}@example.com"

  defp address! do
    n = System.unique_integer([:positive])
    "10.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end
end
