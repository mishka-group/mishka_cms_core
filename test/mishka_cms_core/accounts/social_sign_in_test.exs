# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SocialSignInTest do
  @moduledoc """
  Signing in with a provider (`MishkaCmsCore.Accounts.SignInProvider`,
  `MishkaCmsCore.Accounts.SocialSignIn`), through the strategy's own register action as its
  callback runs it: only a verified email; an account made only while the site allows it; a
  password account linked; an account nobody confirmed claimed and cleaned; a master found among
  masters and never made; an account with no password refused a password; its first password set
  without one; and the code step after a provider for an account with an authenticator.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  import MishkaCmsCore.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.{SecondFactor, SignInProvider, SocialSignIn, User, UserIdentity}
  alias MishkaCmsCore.Accounts.AuthGate.Closed
  alias MishkaCmsCore.Accounts.SignInProvider.Widget
  alias MishkaCmsCore.Accounts.SignInProviders.{GitHub, Google}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  @password "Password123!"

  setup do
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)

    # The providers' key definitions, so a `:secret` is stored sealed as the settings page stores it.
    Settings.load_definitions()

    site = create_site!(active: true, host: "shop-#{System.unique_integer([:positive])}.test")
    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))
    on_exit(fn -> SiteState.delete(site.id) end)

    %{site: site}
  end

  describe "the keys a strategy reads" do
    test "are the site's own while it offers the provider, and none otherwise", %{site: site} do
      conn = conn_for(site)

      assert SignInProvider.secret_for(:google, :client_id, conn) == :error

      offer!(site, Google)

      assert SignInProvider.secret_for(:google, :client_id, conn) == {:ok, "google-id"}
      assert SignInProvider.secret_for(:google, :client_secret, conn) == {:ok, "google-secret"}

      assert {:ok, callback} = SignInProvider.secret_for(:google, :redirect_uri, conn)
      assert callback =~ "://#{site.host}"
      assert String.ends_with?(callback, "/api/auth/user/google/callback")

      {:ok, _} = Settings.put(SignInProvider.enabled_key(Google), false, site_id: site.id)
      assert SignInProvider.secret_for(:google, :client_id, conn) == :error
    end

    test "are none without a site, or for a provider missing a key", %{site: site} do
      assert SignInProvider.secret_for(:google, :client_id, %Plug.Conn{}) == :error

      {:ok, _} = Settings.put(SignInProvider.enabled_key(GitHub), true, site_id: site.id)
      {:ok, _} = Settings.put("auth.providers.github.client_id", "only-id", site_id: site.id)

      refute GitHub.ready?(site.id)
      assert SignInProvider.secret_for(:github, :client_id, conn_for(site)) == :error
    end

    test "come from MishkaCmsCore.Secrets as AshAuthentication asks them", %{site: site} do
      offer!(site, GitHub)

      assert MishkaCmsCore.Secrets.secret_for(
               [:authentication, :strategies, :github, :client_secret],
               User,
               [],
               %{conn: conn_for(site)}
             ) == {:ok, "github-secret"}
    end
  end

  describe "a site's account" do
    test "a first sign-in makes a confirmed account with no password, and its identity", %{
      site: site
    } do
      assert {:ok, user} = provider_sign_in(:google, info("new@example.com", "g-1"), site.id)

      assert user.site_id == site.id
      assert user.confirmed_at
      assert is_nil(reload(user).hashed_password)
      assert [%{strategy: "google", uid: "g-1"}] = identities(user)
    end

    test "the next sign-in with the same provider account lands on the same account", %{
      site: site
    } do
      {:ok, first} = provider_sign_in(:google, info("same@example.com", "g-2"), site.id)
      {:ok, again} = provider_sign_in(:google, info("same@example.com", "g-2"), site.id)

      assert again.id == first.id
      assert length(identities(first)) == 1
    end

    test "several providers sit on one account", %{site: site} do
      {:ok, google} = provider_sign_in(:google, info("both@example.com", "g-3"), site.id)
      {:ok, github} = provider_sign_in(:github, info("both@example.com", "h-3"), site.id)

      assert github.id == google.id
      assert google |> identities() |> Enum.map(& &1.strategy) |> Enum.sort() == ~w(github google)
    end

    test "an email the provider did not verify does nothing", %{site: site} do
      unverified = Map.put(info("maybe@example.com", "g-4"), "email_verified", false)

      assert {:error, error} = provider_sign_in(:google, unverified, site.id)
      assert SocialSignIn.refusal(error) == %{reason: :unverified_email}
      refute account("maybe@example.com", site.id)
    end

    test "no account is made while the site makes none this way", %{site: site} do
      {:ok, _} = Settings.put("auth.social.register", false, site_id: site.id)

      assert {:error, error} =
               provider_sign_in(:google, info("nobody@example.com", "g-5"), site.id)

      assert SocialSignIn.refusal(error) == %{reason: :no_account}
      refute account("nobody@example.com", site.id)
    end

    test "but an account already there still signs in", %{site: site} do
      {:ok, _} = Settings.put("auth.social.register", false, site_id: site.id)
      existing = register!("there@example.com", site.id) |> confirm!()

      assert {:ok, user} = provider_sign_in(:google, info("there@example.com", "g-6"), site.id)
      assert user.id == existing.id
    end

    test "closing registration closes it too", %{site: site} do
      {:ok, _} = Settings.put("auth.register.closed", true, site_id: site.id)

      assert {:error, error} =
               provider_sign_in(:google, info("closed@example.com", "g-7"), site.id)

      assert MishkaCmsCore.Accounts.AuthGate.refusal(error) == %{action: :register}
    end

    test "a confirmed password account is linked and keeps its password", %{site: site} do
      existing = register!("linked@example.com", site.id) |> confirm!()

      assert {:ok, user} = provider_sign_in(:github, info("linked@example.com", "h-8"), site.id)

      assert user.id == existing.id
      assert reload(user).hashed_password == reload(existing).hashed_password
      assert [%{strategy: "github"}] = identities(user)
    end

    test "an account nobody confirmed is claimed: confirmed, its password and sessions gone", %{
      site: site
    } do
      planted = register!("victim@example.com", site.id)
      refute reload(planted).confirmed_at

      assert {:ok, user} = provider_sign_in(:google, info("victim@example.com", "g-9"), site.id)

      claimed = reload(user)
      assert claimed.id == planted.id
      assert claimed.confirmed_at
      assert is_nil(claimed.hashed_password)
      assert {:error, _} = password_sign_in("victim@example.com", @password, site.id)
    end
  end

  describe "a master" do
    setup do
      %{master: create_user!(email: "boss-#{System.unique_integer([:positive])}@example.com")}
    end

    test "signs in by their verified email, linked among masters only", %{
      site: site,
      master: master
    } do
      # A site account with the same address is somebody else's, and stays theirs.
      site_user = register!(to_string(master.email), site.id) |> confirm!()

      assert {:ok, user} = provider_sign_in(:google, info(to_string(master.email), "m-1"), nil)

      assert user.id == master.id
      assert [%{site_id: nil, uid: "m-1"}] = identities(master)
      assert identities(site_user) == []
    end

    test "is never made by a provider", %{master: master} do
      assert {:error, error} = provider_sign_in(:google, info("stranger@example.com", "m-2"), nil)
      assert SocialSignIn.refusal(error) == %{reason: :no_master}

      refute User
             |> Ash.Query.filter(email == "stranger@example.com")
             |> Ash.read_one!(authorize?: false)

      assert master
    end

    test "a site account's identity signs no master in", %{site: site, master: master} do
      {:ok, _site_user} =
        provider_sign_in(:google, info("only-site@example.com", "shared-sub"), site.id)

      assert {:error, error} =
               provider_sign_in(:google, info("only-site@example.com", "shared-sub"), nil)

      assert SocialSignIn.refusal(error) == %{reason: :no_master}
      assert identities(master) == []
    end
  end

  describe "an account with no password" do
    test "is refused a password, any password, without a crash", %{site: site} do
      {:ok, _user} = provider_sign_in(:google, info("nopass@example.com", "g-10"), site.id)

      assert {:error, _} = password_sign_in("nopass@example.com", @password, site.id)
      assert {:error, _} = password_sign_in("nopass@example.com", "", site.id)
    end

    test "sets its first password itself, without a current one", %{site: site} do
      {:ok, user} = provider_sign_in(:google, info("first@example.com", "g-11"), site.id)

      assert {:ok, _} = set_password(user, user, "NewPassword1!")
      assert {:ok, %User{}} = password_sign_in("first@example.com", "NewPassword1!", site.id)
    end

    test "nobody else sets it, and one that has a password changes it instead", %{site: site} do
      {:ok, user} = provider_sign_in(:google, info("mine@example.com", "g-12"), site.id)
      other = register!("other@example.com", site.id) |> confirm!()

      assert {:error, %Ash.Error.Forbidden{}} = set_password(user, other, "NewPassword1!")
      assert {:error, _already} = set_password(other, other, "NewPassword1!")
    end
  end

  describe "password as a way in" do
    test "switched off, signs in and registers nobody but the allowed", %{site: site} do
      register!("pw@example.com", site.id) |> confirm!()
      {:ok, _} = Settings.put("auth.password.closed", true, site_id: site.id)
      {:ok, _} = Settings.put("auth.allowed_permissions", [], site_id: site.id)

      assert {:error, error} = password_sign_in("pw@example.com", @password, site.id)
      assert MishkaCmsCore.Accounts.AuthGate.refusal(error) == %{action: :password}

      assert {:error, %Ash.Error.Forbidden{errors: [%Closed{action: :password} | _]}} =
               User
               |> Ash.Changeset.for_create(:register_with_password, %{
                 email: "pw2@example.com",
                 password: @password,
                 password_confirmation: @password
               })
               |> Ash.Changeset.set_tenant(site.id)
               |> Ash.create()
    end
  end

  describe "the code step after a provider" do
    test "a waiting token and a current code sign in, once", %{site: site} do
      {:ok, user} = provider_sign_in(:google, info("coded@example.com", "g-13"), site.id)
      secret = enable_totp!(user)

      {:ok, pending} = SecondFactor.Pending.token(reload(user))

      assert {:error, error} = second_step(pending, "000000", site.id)
      assert SecondFactor.refusal(error) == :invalid

      assert {:ok, %User{} = signed_in} =
               second_step(pending, NimbleTOTP.verification_code(secret), site.id)

      assert is_binary(signed_in.__metadata__.token)

      assert {:error, _spent} =
               second_step(pending, NimbleTOTP.verification_code(secret), site.id)
    end

    test "a token from elsewhere signs nobody in", %{site: site} do
      assert {:error, _} = second_step("not-a-token", "123456", site.id)
    end
  end

  describe "the buttons" do
    test "list the providers the site offers, linked to their request routes", %{site: site} do
      refute render_component(&Widget.sign_in_providers/1, site: site) =~ "auth-provider"

      offer!(site, Google)
      html = render_component(&Widget.sign_in_providers/1, site: site)

      assert html =~ ~s(href="/api/auth/user/google")
      refute html =~ "/api/auth/user/github"
    end

    test "keys drawn beside their switch, whether it reads true or the form's \"true\"" do
      [definition] =
        Settings.load_definitions()
        |> Enum.filter(&(&1.key == "auth.providers.google.client_id"))

      enabled = SignInProvider.enabled_key(Google)

      assert Settings.visible?(definition, %{enabled => true})
      assert Settings.visible?(definition, %{enabled => "true"})
      refute Settings.visible?(definition, %{enabled => "false"})
      refute Settings.visible?(definition, %{enabled => false})
    end

    test "sit in a table of their own on the Security tab" do
      methods = SignInProvider.methods_group()

      table =
        Settings.load_definitions()
        |> Enum.filter(&(&1.group == methods))
        |> Enum.map(& &1.key)

      assert "auth.password.closed" in table
      assert "auth.magic_link.closed" in table
      assert SignInProvider.enabled_key(Google) in table
      assert "auth.social.register" in table
    end
  end

  defp offer!(site, provider) do
    id = provider.id()
    {:ok, _} = Settings.put(SignInProvider.enabled_key(provider), true, site_id: site.id)
    {:ok, _} = Settings.put("auth.providers.#{id}.client_id", "#{id}-id", site_id: site.id)

    {:ok, _} =
      Settings.put("auth.providers.#{id}.client_secret", "#{id}-secret", site_id: site.id)

    :ok
  end

  defp conn_for(site), do: %Plug.Conn{assigns: %{current_site: site}}

  defp info(email, sub), do: %{"sub" => sub, "email" => email, "email_verified" => true}

  defp provider_sign_in(strategy, user_info, tenant) do
    User
    |> AshAuthentication.Info.strategy!(strategy)
    |> AshAuthentication.Strategy.action(
      :register,
      %{user_info: user_info, oauth_tokens: %{"access_token" => "token"}},
      tenant: tenant
    )
  end

  defp password_sign_in(email, password, site_id) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password},
      tenant: site_id
    )
    |> Ash.read_one()
  end

  defp second_step(token, code, site_id) do
    User
    |> Ash.Query.for_read(:sign_in_with_second_factor, %{token: token, totp_code: code},
      tenant: site_id
    )
    |> Ash.read_one()
  end

  defp set_password(user, actor, password) do
    user
    |> Ash.Changeset.for_update(
      :set_password,
      %{password: password, password_confirmation: password},
      actor: actor,
      tenant: user.site_id
    )
    |> Ash.update()
  end

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

  defp confirm!(user) do
    user
    |> Ash.Changeset.for_update(:confirm_by_admin, %{}, authorize?: false, tenant: user.site_id)
    |> Ash.update!()
  end

  defp enable_totp!(user) do
    started =
      user
      |> Ash.Changeset.for_update(:setup_with_totp, %{}, actor: user, tenant: user.site_id)
      |> Ash.update!()

    secret =
      started.__metadata__.totp_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("secret")
      |> Base.decode32!(padding: false)

    user
    |> Ash.Changeset.for_update(
      :confirm_setup_with_totp,
      %{
        setup_token: started.__metadata__.setup_token,
        code: NimbleTOTP.verification_code(secret)
      },
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update!()

    # The confirming code is spent: the next one is the next period's.
    user
    |> reload()
    |> Ash.Changeset.for_update(:record_totp_use, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:last_totp_at, DateTime.add(DateTime.utc_now(), -60))
    |> Ash.update!()

    secret
  end

  defp reload(user), do: Ash.get!(User, user.id, tenant: user.site_id, authorize?: false)

  defp account(email, site_id) do
    User
    |> Ash.Query.filter(email == ^email and site_id == ^site_id)
    |> Ash.read_one!(tenant: site_id, authorize?: false)
  end

  defp identities(user) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(tenant: user.site_id, authorize?: false)
  end
end
