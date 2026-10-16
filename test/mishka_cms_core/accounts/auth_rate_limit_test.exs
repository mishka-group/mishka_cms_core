# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.AuthRateLimitTest do
  @moduledoc """
  The limits on signing in with a password, asking for a password reset, asking for a sign-in link
  and changing a password, at the actions themselves: `MishkaCmsCore.Accounts.User` counts each per
  address and per account, within its site, in Hammer's ETS table, held to the `security.*`
  settings.

  Every test lifts the suite's `limit:` override and sets the settings low — two tries per account,
  five per address — and comes from an address and a site of its own, so no test spends another's
  allowance.

  `async: false` — the application environment, the settings cache, `SiteState` and the mailbox
  are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias AshAuthentication.Errors.AuthenticationFailed
  alias AshPhoenix.Form
  alias AshRateLimiter.LimitExceeded
  alias MishkaCmsCore.Accounts.{AuthRateLimit, User}
  alias MishkaCmsCore.Runtime.States.{RateLimitState, SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  @password "Password123!"
  @limits [account: 2, ip: 5]

  # What each limited action is called in its settings, and how it is asked for here.
  @actions [
    sign_in: :sign_in_with_password,
    reset_request: :request_password_reset_token,
    magic_link: :request_magic_link
  ]

  setup do
    previous = Application.fetch_env(:mishka_cms_core, AuthRateLimit)
    Application.delete_env(:mishka_cms_core, AuthRateLimit)
    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      with {:ok, env} <- previous, do: Application.put_env(:mishka_cms_core, AuthRateLimit, env)
      SettingsState.restore(snapshot)
    end)

    for {action, _name} <- @actions, {scope, limit} <- @limits, do: limit!(action, scope, limit)
    limit!(:change_password, :account, @limits[:account])

    :ok = Swoosh.TestAssertions.set_swoosh_global()
    {:ok, site: site!(), ip: address!()}
  end

  defp limit!(action, scope, value),
    do: SettingsState.put(nil, "security.#{action}_per_#{scope}", %{"value" => value})

  # A site in the site cache, which the senders read the link's host from.
  defp site! do
    host = "rate-limit-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp address!(first \\ 10) do
    n = System.unique_integer([:positive])
    "#{first}.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end

  defp email!, do: "someone-#{System.unique_integer([:positive])}@example.com"

  defp tenant(nil), do: nil
  defp tenant(site), do: site.id

  # The context AshAuthentication runs its actions with. `request` is its
  # `ash_authentication_request`: an address alone, as the API and the `/auth` page resolve it, or
  # the peer and `x-forwarded-for` as the browser's routes hand it over.
  defp context(%{} = request),
    do: %{private: %{ash_authentication?: true}, ash_authentication_request: request}

  defp context(ip), do: context(%{remote_ip: ip})

  defp sign_in(site, request, email, password \\ "not-the-password") do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password},
      tenant: tenant(site),
      context: context(request)
    )
    |> Ash.read_one()
  end

  defp ask(:sign_in, site, request, email), do: sign_in(site, request, email)

  defp ask(action, site, request, email) do
    User
    |> Ash.ActionInput.for_action(Keyword.fetch!(@actions, action), %{email: email},
      tenant: tenant(site),
      context: context(request)
    )
    |> Ash.run_action()
  end

  defp change_password(site, user, current) do
    user
    |> Ash.Changeset.for_update(
      :change_password,
      %{
        current_password: current,
        password: "NewPassword123!",
        password_confirmation: "NewPassword123!"
      },
      actor: user,
      tenant: tenant(site)
    )
    |> Ash.update()
  end

  defp limited?({:error, %{errors: errors}}), do: Enum.any?(errors, &match?(%LimitExceeded{}, &1))
  defp limited?(_let_through), do: false

  # The mails with `subject` that have reached this test so far, taken out of its mailbox.
  defp mails(subject) do
    receive do
      {:email, %{subject: ^subject}} -> 1 + mails(subject)
    after
      0 -> 0
    end
  end

  describe "signing in with a password" do
    test "refuses an account's third try, the right password too, from any address", %{
      site: site,
      ip: ip
    } do
      email = email!()
      create_user!(site_id: site.id, email: email)

      for _try <- 1..2, do: refute(site |> sign_in(ip, email) |> limited?())

      assert {:error, %Ash.Error.Forbidden{errors: [%LimitExceeded{}]}} =
               sign_in(site, address!(), email, @password)

      other = email!()
      create_user!(site_id: site.id, email: other)
      assert {:ok, %User{}} = sign_in(site, address!(), other, @password)
    end
  end

  describe "every limited action" do
    for {action, _name} <- @actions do
      test "#{action}: refuses an address's sixth try, whatever accounts it names", %{
        site: site,
        ip: ip
      } do
        for _account <- 1..5, do: refute(ask(unquote(action), site, ip, email!()) |> limited?())

        assert site |> then(&ask(unquote(action), &1, ip, email!())) |> limited?()
        refute site |> then(&ask(unquote(action), &1, address!(), email!())) |> limited?()
      end

      test "#{action}: refuses an account's third try from any address", %{site: site} do
        email = email!()
        for _try <- 1..2, do: refute(ask(unquote(action), site, address!(), email) |> limited?())

        assert site |> then(&ask(unquote(action), &1, address!(), email)) |> limited?()
      end

      test "#{action}: counts every site on its own, and masters together as one more", %{
        site: site,
        ip: ip
      } do
        email = email!()
        for _try <- 1..2, do: ask(unquote(action), site, ip, email)
        for _account <- 1..3, do: ask(unquote(action), site, ip, email!())
        assert site |> then(&ask(unquote(action), &1, ip, email)) |> limited?()

        refute site!() |> then(&ask(unquote(action), &1, ip, email)) |> limited?()
        refute ask(unquote(action), nil, ip, email) |> limited?()
      end
    end
  end

  describe "asking for a password reset and for a sign-in link" do
    test "mails an account nothing once its requests are refused", %{site: site, ip: ip} do
      email = email!()
      create_user!(site_id: site.id, email: email)
      mails("Reset your password")
      mails("Your login link")

      for action <- [:reset_request, :magic_link],
          _request <- 1..2,
          do: assert(ask(action, site, ip, email) == :ok)

      assert mails("Reset your password") == 2
      assert mails("Your login link") == 2

      for action <- [:reset_request, :magic_link],
          do: assert(site |> then(&ask(action, &1, ip, email)) |> limited?())

      assert mails("Reset your password") == 0
      assert mails("Your login link") == 0
    end
  end

  describe "changing a password" do
    test "refuses an account's third try, the right current password too, and no other account's",
         %{site: site} do
      user = create_user!(site_id: site.id, email: email!())

      for _try <- 1..2 do
        assert {:error, %Ash.Error.Forbidden{errors: [%AuthenticationFailed{}]}} =
                 change_password(site, user, "not-the-password")
      end

      assert {:error, error} = change_password(site, user, @password)
      assert %{action: :change_password, key: :account} = AuthRateLimit.limited(error)

      other = create_user!(site_id: site.id, email: email!())
      assert {:ok, %User{}} = change_password(site, other, @password)
    end
  end

  describe "the settings" do
    test "a limit changed in them holds from the next try on", %{site: site, ip: ip} do
      email = email!()
      for _try <- 1..2, do: sign_in(site, ip, email)

      assert {:ok, 4} = Settings.put("security.sign_in_per_account", 4, category: "security")

      for _try <- 3..4, do: refute(site |> sign_in(ip, email) |> limited?())
      assert site |> sign_in(ip, email) |> limited?()
    end

    test "without one, the number the action is written with holds", %{site: site, ip: ip} do
      SettingsState.delete(nil, "security.reset_request_per_account")
      email = email!()

      for _try <- 1..3, do: refute(ask(:reset_request, site, ip, email) |> limited?())
      assert site |> then(&ask(:reset_request, &1, ip, email)) |> limited?()
    end

    test "one that holds no positive integer is passed over for the written number", %{site: site} do
      for {value, n} <- Enum.with_index(["many", 0, -1, nil]) do
        limit!(:reset_request, :account, value)
        email = "#{n}-" <> email!()

        for _try <- 1..3, do: refute(ask(:reset_request, site, address!(), email) |> limited?())
        assert site |> then(&ask(:reset_request, &1, address!(), email)) |> limited?()
      end
    end

    test "declare as their defaults the numbers the actions are written with" do
      Settings.load_definitions()
      scopes = %{by_address: "ip", by_account: "account", by_user: "account"}

      written =
        for {action, name} <- Keyword.put(@actions, :change_password, :change_password),
            step <-
              Map.get(Ash.Resource.Info.action(User, name), :preparations, []) ++
                Map.get(Ash.Resource.Info.action(User, name), :changes, []),
            {limiter, opts} <- [Map.get(step, :preparation) || Map.get(step, :change)],
            limiter in [AshRateLimiter.Preparation, AshRateLimiter.Change],
            {:name, key} = Function.info(opts[:key], :name),
            into: %{},
            do: {"security.#{action}_per_#{Map.fetch!(scopes, key)}", opts[:limit]}

      assert map_size(written) == 7

      for {key, limit} <- written,
          do: assert(%{default: ^limit, scope: :master} = Settings.definition(key), key)
    end
  end

  describe "the address" do
    setup do
      previous = Application.fetch_env(:mishka_cms_core, :trusted_proxies)
      Application.put_env(:mishka_cms_core, :trusted_proxies, ["203.0.113.0/24"])

      on_exit(fn ->
        case previous do
          {:ok, proxies} -> Application.put_env(:mishka_cms_core, :trusted_proxies, proxies)
          :error -> Application.delete_env(:mishka_cms_core, :trusted_proxies)
        end
      end)
    end

    test "is the client x-forwarded-for names past the proxies, as the browser's routes hand it over",
         %{site: site} do
      client = address!(198)

      for n <- 1..5 do
        request = %{remote_ip: address!(), x_forwarded_for: ["#{client}, 203.0.113.#{n}"]}
        sign_in(site, request, email!())
      end

      spoofed = %{remote_ip: address!(), x_forwarded_for: ["192.0.2.1, #{client}, 203.0.113.9"]}
      assert site |> sign_in(spoofed, email!()) |> limited?()
      assert site |> sign_in(client, email!()) |> limited?()

      another = %{remote_ip: address!(), x_forwarded_for: ["#{address!(198)}, 203.0.113.1"]}
      refute site |> sign_in(another, email!()) |> limited?()
    end

    test "of an IPv6 client is its /64, however it reached the action", %{site: site} do
      for n <- 1..5, do: sign_in(site, "2001:db8:1:2::#{n}", email!())

      assert site |> sign_in("2001:db8:1:2::ffff", email!()) |> limited?()

      forwarded = %{remote_ip: address!(), x_forwarded_for: ["2001:db8:1:2:abcd::1"]}
      assert site |> sign_in(forwarded, email!()) |> limited?()

      refute site |> sign_in("2001:db8:1:3::1", email!()) |> limited?()
    end

    test "of an IPv4 client written as IPv6 is that IPv4 address", %{site: site} do
      ip = address!(198)
      for _account <- 1..5, do: sign_in(site, "::ffff:" <> ip, email!())

      assert site |> sign_in(ip, email!()) |> limited?()
      refute site |> sign_in("::ffff:" <> address!(198), email!()) |> limited?()
    end

    test "is read past trusted proxies whose list refuses an entry that is no IP or CIDR range" do
      Application.put_env(:mishka_cms_core, :trusted_proxies, ["203.0.113.0/24", "10.0.0.0/8;"])

      assert_raise ArgumentError, ~r{"10\.0\.0\.0/8;"}, &AuthRateLimit.validate_trusted_proxies!/0

      Application.put_env(:mishka_cms_core, :trusted_proxies, ["203.0.113.0/24", "2a06:98c0::/29"])

      assert AuthRateLimit.validate_trusted_proxies!() == :ok
    end

    test "is the peer when nothing forwarded it", %{site: site, ip: ip} do
      for _account <- 1..5, do: sign_in(site, %{remote_ip: ip, x_forwarded_for: []}, email!())

      assert site |> sign_in(ip, email!()) |> limited?()

      refute site
             |> sign_in(%{remote_ip: address!(), x_forwarded_for: []}, email!())
             |> limited?()
    end
  end

  describe "the refusal" do
    test "names what was refused, by what, and how long the window has left", %{
      site: site,
      ip: ip
    } do
      email = email!()
      for _try <- 1..2, do: ask(:reset_request, site, ip, email)

      {:error, error} = ask(:reset_request, site, ip, email)

      assert %{action: :reset_request, key: :account, retry_after: seconds} =
               limited = AuthRateLimit.limited(error)

      assert seconds in 3_500..3_600

      assert AuthRateLimit.describe(limited) == %{
               title: "Too many password reset requests",
               text: "Try again in 60 minutes."
             }

      failed = %AshAuthentication.Errors.AuthenticationFailed{caused_by: error}
      assert AuthRateLimit.limited(failed) == limited
      assert AuthRateLimit.limited(%{[] => [failed]}) == limited
      assert AuthRateLimit.limited(Ash.Error.Forbidden.exception([])) == nil
    end

    test "waits what the key's window has left, not the window's length", %{site: site, ip: ip} do
      email = email!()
      for _try <- 1..2, do: sign_in(site, ip, email)

      key =
        User
        |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: "x"},
          tenant: site.id
        )
        |> AuthRateLimit.by_account(%{})

      true =
        :ets.update_element(RateLimitState, key, {3, System.system_time(:millisecond) + 90_000})

      {:error, error} = sign_in(site, ip, email)

      assert %{retry_after: seconds} = AuthRateLimit.limited(error)
      assert seconds in 85..90
    end
  end

  describe "an AshPhoenix form" do
    test "counts nothing while it is built and validated, and counts each submit", %{
      site: site,
      ip: ip
    } do
      email = email!()

      form =
        Form.for_action(User, :sign_in_with_password,
          domain: MishkaCmsCore.Accounts,
          as: "user",
          tenant: site.id,
          context: context(ip)
        )

      params = %{"email" => email, "password" => "not-the-password"}
      form = Enum.reduce(1..20, form, fn _keystroke, form -> Form.validate(form, params) end)

      for _submit <- 1..2 do
        assert {:error, submitted} = Form.submit(form, params: params, read_one?: true)
        assert AuthRateLimit.limited(Form.raw_errors(submitted, for_path: :all)) == nil
      end

      assert {:error, submitted} = Form.submit(form, params: params, read_one?: true)

      assert %{action: :sign_in, key: :account} =
               AuthRateLimit.limited(Form.raw_errors(submitted, for_path: :all))

      assert Form.errors(submitted) == []
    end
  end
end
