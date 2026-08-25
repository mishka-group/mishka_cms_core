defmodule MishkaCmsCore.Accounts.SecondFactorTest do
  @moduledoc """
  An authenticator app as a second step after the password (`MishkaCmsCore.Accounts.SecondFactor`):
  set up by the account itself in two steps, asked for by every password sign-in once it is set up,
  each code accepted once, a sign-in link refused, and turned off by the account with a code or by
  an admin of its site with a code from their own; its recovery codes made with a code, each
  signing in once, and gone with the authenticator; and the account emailed when it is turned off
  or a recovery code is used.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.SecondFactor
  alias MishkaCmsCore.Accounts.SecondFactor.Needed
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Accounts.User.Notices.{RecoveryCodeUsed, SecondFactorTurnedOff}

  @password "Password123!"

  setup do
    site = create_site!(active: true)
    %{site: site, user: register!("owner@example.com", site.id)}
  end

  describe "setting one up" do
    test "stores nothing until a code from the app matches", %{user: user} do
      started = setup!(user)

      assert started.__metadata__.totp_url =~ "otpauth://totp/MishkaCMS:owner@example.com?secret="
      refute SecondFactor.enabled?(reload(user))

      assert {:error, _wrong} = confirm(user, started, "000000")
      refute SecondFactor.enabled?(reload(user))

      assert {:ok, _confirmed} = confirm(user, started, code(secret(started)))
      assert SecondFactor.enabled?(reload(user))
      assert reload(user, [:totp_enabled?]).totp_enabled?
    end

    test "is for the account itself only, admins included", %{site: site, user: user} do
      admin = create_user_with_permissions!(["*"], site_id: site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:setup_with_totp, %{},
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.update()
    end

    test "is refused while one is set up already", %{user: user} do
      enabled = enable!(user)

      assert {:error, %Ash.Error.Forbidden{}} =
               enabled
               |> Ash.Changeset.for_update(:setup_with_totp, %{},
                 actor: enabled,
                 tenant: user.site_id
               )
               |> Ash.update()
    end
  end

  describe "signing in by password" do
    test "asks an account without one for its password alone", %{user: user} do
      assert {:ok, %User{}} = sign_in(user, nil)
    end

    test "asks an account with one for a current code after the password", %{user: user} do
      secret = enable!(user).__metadata__.secret

      assert SecondFactor.refusal(sign_in_error(user, nil)) == :required
      assert SecondFactor.refusal(sign_in_error(user, "000000")) == :invalid
      later!(user)
      assert {:ok, %User{} = signed_in} = sign_in(user, code(secret))
      assert is_binary(signed_in.__metadata__.token)
    end

    test "does not take the code that confirmed the setup again", %{user: user} do
      secret = enable!(user).__metadata__.secret

      assert SecondFactor.refusal(sign_in_error(user, code(secret))) == :invalid
    end

    test "answers a wrong password the old way, saying nothing of a code", %{user: user} do
      enable!(user)

      error = sign_in_error(user, nil, "not the password")
      assert SecondFactor.refusal(error) == nil
    end

    test "accepts each code once", %{user: user} do
      secret = enable!(user).__metadata__.secret
      later!(user)
      once = code(secret)

      assert {:ok, _signed_in} = sign_in(user, once)
      assert SecondFactor.refusal(sign_in_error(user, once)) == :invalid
    end

    test "leaves no new token valid when the code is missing", %{user: user} do
      enable!(user)
      before = valid_tokens(user)

      assert %Needed{reason: :required} = find_needed(sign_in_error(user, nil))
      assert valid_tokens(user) == before
    end

    test "counts wrong codes, and stops them at the limit", %{user: user} do
      # The suite holds every limit out of reach (`config/test.exs`); this test lowers it, and puts
      # the suite's value back for the tests after it.
      previous = Application.fetch_env(:mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit)
      Application.put_env(:mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit, limit: 3)

      on_exit(fn ->
        case previous do
          {:ok, env} ->
            Application.put_env(:mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit, env)

          :error ->
            Application.delete_env(:mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit)
        end
      end)

      # Confirming the setup is one of the three.
      enable!(user)

      assert {:error, %Needed{reason: :invalid}} = check(user, "000000")
      assert {:error, %Needed{reason: :invalid}} = check(user, "000000")
      assert {:error, limited} = check(user, "000000")
      assert %{action: :totp} = MishkaCmsCore.Accounts.AuthRateLimit.limited(limited)
    end
  end

  describe "a sign-in link" do
    test "is refused to an account with an authenticator", %{user: user} do
      enable!(user)
      {:ok, token} = magic_token(user)

      {:error, error} =
        User
        |> Ash.Query.for_read(:sign_in_with_magic_link, %{token: token}, tenant: user.site_id)
        |> Ash.read_one()

      assert SecondFactor.refusal(error) == :password
    end

    test "still signs in an account without one", %{user: user} do
      {:ok, token} = magic_token(user)

      assert {:ok, %User{}} =
               User
               |> Ash.Query.for_read(:sign_in_with_magic_link, %{token: token},
                 tenant: user.site_id
               )
               |> Ash.read_one()
    end
  end

  describe "turning it off" do
    test "takes a current code from the account itself", %{user: user} do
      enabled = enable!(user)

      assert {:error, _wrong} = disable(enabled, "000000")
      assert SecondFactor.enabled?(reload(user))

      later!(user)
      assert {:ok, _off} = disable(enabled, code(enabled.__metadata__.secret))
      refute SecondFactor.enabled?(reload(user))
      assert {:ok, %User{}} = sign_in(user, nil)
    end

    test "is open to an admin of the account's site with a code from their own, not of another",
         %{site: site, user: user} do
      enable!(user)
      admin = create_user_with_permissions!(["admin:dashboard:user"], site_id: site.id)
      own = enable!(admin)
      other_site = create_site!(active: true)
      stranger = create_user_with_permissions!(["admin:dashboard:user"], site_id: other_site.id)
      nobody = create_user_with_permissions!([], site_id: site.id)

      for refused <- [stranger, nobody] do
        assert {:error, %Ash.Error.Forbidden{}} = turn_off(user, refused, "000000")
      end

      assert %Needed{reason: :invalid} = turn_off_error(user, admin, "000000")
      assert SecondFactor.enabled?(reload(user))

      later!(admin)
      assert {:ok, _off} = turn_off(user, admin, code(own.__metadata__.secret))
      refute SecondFactor.enabled?(reload(user))
    end

    test "asks an admin without an authenticator of their own to set one up first", %{
      site: site,
      user: user
    } do
      enable!(user)
      admin = create_user_with_permissions!(["admin:dashboard:user"], site_id: site.id)

      assert %Needed{reason: :own} = turn_off_error(user, admin, "123456")
      assert SecondFactor.enabled?(reload(user))
    end

    test "is not open to an admin holding less than the account", %{site: site} do
      owner = create_user_with_permissions!(["*"], site_id: site.id, password: @password)
      enable!(owner)
      admin = create_user_with_permissions!(["admin:dashboard:user"], site_id: site.id)

      assert {:error, %Ash.Error.Forbidden{}} = turn_off(owner, admin, "000000")
    end

    test "is not open to an admin on its own account, which takes a code", %{site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      enable!(admin)

      assert {:error, %Ash.Error.Forbidden{}} = turn_off(admin, admin, "000000")
      assert SecondFactor.enabled?(reload(admin))
    end

    test "takes the account's recovery codes with it, whoever turns it off", %{
      site: site,
      user: user
    } do
      enabled = enable!(user)
      later!(user)
      {:ok, _made} = generate(user, code(enabled.__metadata__.secret))
      assert SecondFactor.recovery_codes_left(user) == 10

      admin = create_user_with_permissions!(["admin:dashboard:user"], site_id: site.id)
      own = enable!(admin)
      later!(admin)

      assert {:ok, _off} = turn_off(user, admin, code(own.__metadata__.secret))
      assert SecondFactor.recovery_codes_left(user) == 0
    end
  end

  describe "recovery codes" do
    test "are made with a current code from the app: ten, handed back once", %{user: user} do
      enabled = enable!(user)

      assert {:error, _wrong} = generate(user, "000000")
      assert SecondFactor.recovery_codes_left(user) == 0

      later!(user)
      assert {:ok, made} = generate(user, code(enabled.__metadata__.secret))
      assert [_ | _] = codes = made.__metadata__.recovery_codes
      assert length(codes) == 10
      assert Enum.all?(codes, &Regex.match?(~r/\A[A-Z0-9]{12}\z/, &1))
      assert SecondFactor.recovery_codes_left(user) == 10
    end

    test "are only for an account with an authenticator, made by itself", %{
      site: site,
      user: user
    } do
      assert {:error, %Ash.Error.Forbidden{}} = generate(user, "123456")

      enable!(user)
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> reload()
               |> Ash.Changeset.for_update(:generate_recovery_codes, %{code: "123456"},
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.update()
    end

    test "sign in once each in place of the app's code, typed any way", %{user: user} do
      [first, second | _rest] = recovery_codes!(user)

      assert {:ok, %User{}} = recover(user, first)
      assert %Needed{reason: :invalid} = recover_error(user, first)

      typed = second |> String.downcase() |> String.graphemes() |> Enum.chunk_every(4)
      assert {:ok, %User{}} = recover(user, Enum.map_join(typed, "-", &Enum.join/1))
      assert SecondFactor.recovery_codes_left(user) == 8
    end

    test "made again, the old ones stop working", %{user: user} do
      [old | _rest] = recovery_codes!(user)
      later!(user)
      secret = reload(user).totp_secret

      {:ok, _new} = generate(user, code(secret))

      assert SecondFactor.recovery_codes_left(user) == 10
      assert %Needed{reason: :invalid} = recover_error(user, old)
    end

    test "are refused to a wrong code without saying which part was wrong", %{user: user} do
      recovery_codes!(user)

      assert %Needed{reason: :invalid} = recover_error(user, "NOTACODE1234")
      assert SecondFactor.recovery_codes_left(user) == 10
    end
  end

  describe "the account's emails" do
    # A site is emailed from only while it is up, which `SiteState` says. The cache outlives each
    # test's rollback, so an earlier test's site under the same host would keep this one out of it:
    # cleared, then written here.
    setup %{site: site} do
      MishkaCmsCore.Runtime.States.SiteState.clear()

      :ok =
        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: true
        })

      on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.clear() end)
    end

    test "say two-step sign-in was turned off, and whether an admin did it", %{user: user} do
      SecondFactorTurnedOff.call(%{user_id: user.id, site_id: user.site_id, by: nil})

      SecondFactorTurnedOff.call(%{
        user_id: user.id,
        site_id: user.site_id,
        by: Ecto.UUID.generate()
      })

      assert deliveries(user, "second_factor_off") == [
               "An administrator turned off your two-step sign-in",
               "Two-step sign-in was turned off"
             ]
    end

    test "say a recovery code was used", %{user: user} do
      RecoveryCodeUsed.call(%{user_id: user.id, site_id: user.site_id, left: 9})

      assert deliveries(user, "recovery_code_used") == ["A recovery code was used"]
    end

    test "are plugins the core starts" do
      assert SecondFactorTurnedOff in MishkaCmsCore.Application.plugins()
      assert RecoveryCodeUsed in MishkaCmsCore.Application.plugins()
    end
  end

  describe "the setup address" do
    test "names the code after the site's title, keeping the strategy's secret", %{
      site: site,
      user: user
    } do
      MishkaCmsCore.Settings.put("site.title", "Acme: Shop", site_id: site.id)
      started = setup!(user)

      url = SecondFactor.setup_url(started.__metadata__.totp_url, user)
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["issuer"] == "Acme Shop"
      assert URI.decode(URI.parse(url).path) == "/Acme Shop:owner@example.com"
      assert params |> Map.fetch!("secret") |> Base.decode32!(padding: false) == secret(started)
    end

    test "names it after the strategy's issuer when the title is empty", %{site: site, user: user} do
      MishkaCmsCore.Settings.put("site.title", " ", site_id: site.id)
      started = setup!(user)

      params =
        started.__metadata__.totp_url
        |> SecondFactor.setup_url(user)
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert params["issuer"] == AshAuthentication.Info.strategy!(User, :totp).issuer
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp register!(email, site_id) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.Changeset.set_tenant(site_id)
    |> Ash.create!()
  end

  defp setup!(user) do
    user
    |> Ash.Changeset.for_update(:setup_with_totp, %{}, actor: user, tenant: user.site_id)
    |> Ash.update!()
  end

  defp confirm(user, started, code) do
    user
    |> Ash.Changeset.for_update(
      :confirm_setup_with_totp,
      %{setup_token: started.__metadata__.setup_token, code: code},
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update()
  end

  # Sets an authenticator up, and hands back the account with its secret in the metadata, for the
  # test to compute codes from.
  defp enable!(user) do
    started = setup!(user)
    secret = secret(started)
    {:ok, confirmed} = confirm(user, started, code(secret))
    # The confirming code is spent, as a sign-in's would be: the next code is the next period's.
    Ash.Resource.put_metadata(confirmed, :secret, secret)
  end

  defp secret(started) do
    started.__metadata__.totp_url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("secret")
    |> Base.decode32!(padding: false)
  end

  defp code(secret), do: NimbleTOTP.verification_code(secret)

  # As if the next 30-second period had come: the current code confirmed the setup and is spent.
  defp later!(user) do
    user
    |> reload()
    |> Ash.Changeset.for_update(:record_totp_use, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:last_totp_at, DateTime.add(DateTime.utc_now(), -60))
    |> Ash.update!()
  end

  defp check(user, code), do: SecondFactor.check(reload(user), code, user.site_id)

  defp valid_tokens(user) do
    subject = AshAuthentication.user_to_subject(user)

    MishkaCmsCore.Accounts.Token
    |> Ash.Query.filter(subject == ^subject and purpose == "user")
    |> Ash.read!(authorize?: false)
  end

  defp sign_in(user, code, password \\ @password) do
    User
    |> Ash.Query.for_read(
      :sign_in_with_password,
      %{email: to_string(user.email), password: password, totp_code: code},
      tenant: user.site_id
    )
    |> Ash.read_one()
  end

  defp sign_in_error(user, code, password \\ @password) do
    {:error, error} = sign_in(user, code, password)
    error
  end

  defp find_needed(%Needed{} = needed), do: needed
  defp find_needed(%{errors: errors}), do: Enum.find_value(errors, &find_needed/1)
  defp find_needed(%{caused_by: cause}), do: find_needed(cause)
  defp find_needed(_other), do: nil

  defp magic_token(user) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)
    AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
  end

  defp disable(user, code) do
    user
    |> Ash.Changeset.for_update(:disable_totp, %{code: code}, actor: user, tenant: user.site_id)
    |> Ash.update()
  end

  defp turn_off(user, actor, code) do
    user
    |> Ash.Changeset.for_update(:turn_off_totp, %{code: code}, actor: actor, tenant: user.site_id)
    |> Ash.update()
  end

  defp turn_off_error(user, actor, code) do
    {:error, error} = turn_off(user, actor, code)
    find_needed(error)
  end

  defp generate(user, code) do
    user
    |> reload()
    |> Ash.Changeset.for_update(:generate_recovery_codes, %{code: code},
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update()
  end

  # An account with an authenticator and its ten recovery codes, as they were handed back.
  defp recovery_codes!(user) do
    enabled = enable!(user)
    later!(user)
    {:ok, made} = generate(user, code(enabled.__metadata__.secret))
    made.__metadata__.recovery_codes
  end

  defp recover(user, recovery_code) do
    User
    |> Ash.Query.for_read(
      :sign_in_with_password,
      %{email: to_string(user.email), password: @password, recovery_code: recovery_code},
      tenant: user.site_id
    )
    |> Ash.read_one()
  end

  defp recover_error(user, recovery_code) do
    {:error, error} = recover(user, recovery_code)
    find_needed(error)
  end

  # The emails handed to `MishkaCmsCore.Mail` for `user` with `purpose`, by subject — recorded
  # whether or not the test site has a provider to send them with.
  defp deliveries(user, purpose) do
    recipient = to_string(user.email)

    MishkaCmsCore.Mail.Delivery
    |> Ash.read!(authorize?: false, tenant: user.site_id)
    |> Enum.filter(&(&1.purpose == purpose and &1.recipient =~ recipient))
    |> Enum.map(& &1.subject)
    |> Enum.sort()
  end

  defp reload(user, load \\ []) do
    User
    |> Ash.get!(user.id, tenant: user.site_id, authorize?: false)
    |> Ash.load!(load, tenant: user.site_id, authorize?: false)
  end
end
