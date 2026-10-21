# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.AuthControllerTest do
  @moduledoc """
  Where every browser sign-in ends: `MishkaCmsCoreWeb.AuthController` behind the `/api/auth` routes,
  the `return_to` it follows (`MishkaCmsCoreWeb.ReturnTo`), the DELETE that signs out, who an
  offline site lets in, and the emails that would lead to a sign-in.

  A sign-in is driven the way the sign-in pages drive it: `sign_in_with_password` mints a sign-in
  token, and the `sign_in_with_token` GET it is handed to is what writes the session. The pages
  themselves are each site's runtime pages, tested with the CMS's router.

  `async: false` — the install flag, `SiteState`, the settings cache and the plugin registry are
  process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  require Ash.Query

  import MishkaCmsCore.Test.Factory
  import Swoosh.TestAssertions

  alias MishkaCmsCore.Accounts.{AuthRateLimit, User}
  alias MishkaCmsCore.Accounts.User.Senders.{SendMagicLinkEmail, SendPasswordResetEmail}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCoreWeb.ReturnTo

  @password "Password123!"

  setup %{conn: conn} do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    {:ok, conn: with_host(conn), site: site}
  end

  # `SiteLookupPlug` resolves the site from the raw Host header, and 503s when it cannot. Recycling
  # a conn for a second request does NOT carry that header over, so anything following a response
  # has to re-apply it.
  defp with_host(conn, host \\ "localhost") do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  defp register_user(email, site_id) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.Changeset.set_tenant(site_id)
    |> Ash.create!()
  end

  defp user_with(permissions, site_id) do
    permissions
    |> create_user_with_permissions!(
      site_id: site_id,
      password: @password,
      password_confirmation: @password
    )
    |> Ash.load!([:permissions], authorize?: false, tenant: site_id)
  end

  # The `sign_in_with_token` address a sign-in page hands a visitor to once their password is
  # right, with `params` beside the token — a `return_to`, as a page asked for with one carries it.
  defp handoff(user, params \\ %{}) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in} =
      User
      |> Ash.Query.for_read(
        :sign_in_with_password,
        %{email: to_string(user.email), password: @password},
        tenant: user.site_id,
        context: %{
          strategy: strategy,
          private: %{ash_authentication?: true},
          token_type: :sign_in
        }
      )
      |> Ash.read_one()

    "/api/auth/user/password/sign_in_with_token?" <>
      URI.encode_query(Map.put(params, "token", signed_in.__metadata__.token))
  end

  defp signed(path), do: ReturnTo.sign(@endpoint, path)

  describe "a sign-in asked for with a return_to" do
    @asked "/en/members?tab=2"

    # EVERY WAY OF NOT BEING A TOKEN THIS APPLICATION SIGNED FOR A PAGE OF ITS OWN: one whose
    # signature was edited, one signed too long ago, one signed under another salt, one signed with
    # another application's secret, one this very application signed over somewhere else — which
    # `sign/2` would refuse to mint but a leaked or older one could be — and then the plain
    # addresses that used to be taken at their word, `@asked` itself included: it is a real page
    # here, and being local is no longer what earns a redirect. `/%2F/evil.example` and
    # `/%5Cevil.example` are here rather than among the paths `sign/2` refuses, because they are
    # pages of this site and it signs them — a browser reads neither escape as another origin.
    defp forgeries do
      # An edit inside the SIGNATURE, not at the front of the token: the token opens with the fixed
      # `SFMyNTY` header, and an edit there is turned away for naming an algorithm nothing offers,
      # before any signature is compared. Base64 with no padding leaves the signature's LAST
      # character carrying bits nothing reads — around one edit in fifteen there decodes to the same
      # bytes and still verifies — while its first carries all six of its own, so that is the one an
      # edit always changes.
      [header, payload, signature] = String.split(signed(@asked), ".")
      {first, rest} = String.split_at(signature, 1)

      [
        Enum.join([header, payload, if(first == "A", do: "B", else: "A") <> rest], "."),
        Phoenix.Token.sign(@endpoint, "return_to", @asked,
          signed_at: System.system_time(:second) - 3600
        ),
        Phoenix.Token.sign(@endpoint, "not_the_return_to_salt", @asked),
        Phoenix.Token.sign(
          String.duplicate("another application's secret", 3),
          "return_to",
          @asked
        ),
        Phoenix.Token.sign(@endpoint, "return_to", "//evil.example"),
        @asked,
        "/en/members",
        "https://evil.example/en/members",
        "//evil.example",
        "///evil.example",
        "/\\evil.example",
        "/%2F/evil.example",
        "/%5Cevil.example",
        "/%09/evil.example",
        "javascript:alert(1)",
        "en/members",
        ""
      ]
    end

    test "comes back to that page once signed in", %{conn: conn, site: site} do
      user = register_user("returning@example.com", site.id)
      handoff = handoff(user, %{"return_to" => signed(@asked)})

      assert redirected_to(get(conn, handoff)) == @asked
    end

    # The handoff is a GET anyone can retype, so the forgeries are put on it directly.
    test "goes home rather than anywhere a signature does not vouch for", %{
      conn: conn,
      site: site
    } do
      user = register_user("phished@example.com", site.id)

      for forgery <- forgeries() do
        handoff = handoff(user, %{"return_to" => forgery})

        assert redirected_to(get(conn, handoff)) == "/", "signing in went on to #{forgery}"
      end
    end

    # THE OTHER WAYS IN END IN THE SAME CONTROLLER. Nothing this application emails carries a
    # `return_to`, but the routes those mails lead to are GETs and POSTs anyone can add one to, so
    # each is asked here directly with a signature and with a forgery.
    defp magic_sign_in(conn, user, return_to) do
      strategy = AshAuthentication.Info.strategy!(User, :magic_link)
      {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)

      conn
      |> post(
        "/api/auth/user/magic_link?" <> URI.encode_query(%{"return_to" => return_to}),
        %{"user" => %{"token" => token}}
      )
      |> redirected_to()
    end

    defp password_reset(conn, user, return_to) do
      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)

      conn
      |> post(
        "/api/auth/user/password/reset?" <> URI.encode_query(%{"return_to" => return_to}),
        %{
          "user" => %{
            "reset_token" => token,
            "password" => @password,
            "password_confirmation" => @password
          }
        }
      )
      |> redirected_to()
    end

    test "is followed on a magic-link sign-in only when it was signed", %{conn: conn, site: site} do
      vouched = register_user("magic-vouched@example.com", site.id)
      forged = register_user("magic-forged@example.com", site.id)

      assert magic_sign_in(conn, vouched, signed(@asked)) == @asked
      assert magic_sign_in(conn, forged, "//evil.example") == "/"
    end

    test "is followed on a password reset only when it was signed", %{conn: conn, site: site} do
      vouched = register_user("reset-vouched@example.com", site.id)
      forged = register_user("reset-forged@example.com", site.id)

      assert password_reset(conn, vouched, signed(@asked)) == @asked
      assert password_reset(conn, forged, "https://evil.example/en/members") == "/"
    end

    test "a password reset leaves the browser that made it signed in, and no other session", %{
      conn: conn,
      site: site
    } do
      user = register_user("reset-signed-in@example.com", site.id)

      {:ok, earlier} =
        User
        |> Ash.Query.for_read(
          :sign_in_with_password,
          %{email: to_string(user.email), password: @password},
          tenant: site.id
        )
        |> Ash.read_one()

      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, reset_token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)

      reset =
        post(conn, "/api/auth/user/password/reset", %{
          "user" => %{
            "reset_token" => reset_token,
            "password" => "NewPassword456!",
            "password_confirmation" => "NewPassword456!"
          }
        })

      assert token = Plug.Conn.get_session(reset, "user_token")

      refute AshAuthentication.TokenResource.Actions.token_revoked?(
               MishkaCmsCore.Accounts.Token,
               token
             )

      assert AshAuthentication.TokenResource.Actions.token_revoked?(
               MishkaCmsCore.Accounts.Token,
               earlier.__metadata__.token
             )
    end

    test "is not signed for anywhere but this site in the first place" do
      for elsewhere <- [
            "https://evil.example/en/members",
            "//evil.example",
            "///evil.example",
            "/\\evil.example",
            "/%09/evil.example",
            "javascript:alert(1)",
            "en/members",
            ""
          ] do
        assert signed(elsewhere) == nil, "#{elsewhere} was signed"
      end

      assert @asked |> signed() |> then(&ReturnTo.verify(@endpoint, &1)) == @asked
    end

    defp signs?(address), do: signed(address) != nil

    # Whether `Phoenix.Controller.redirect/2` hands the address out or raises on it. A conn of its
    # own each time, because a redirect is a response already sent.
    defp redirects?(address) do
      Phoenix.Controller.redirect(build_conn(), to: address)
      true
    rescue
      _refused -> false
    end

    # THE CHARACTERS `ReturnTo` REFUSES ARE A COPY OF PHOENIX'S OWN, and this is what holds the two
    # together rather than trust: an address `sign/2` mints a token for has to be one
    # `Phoenix.Controller.redirect/2` will hand out, and one it refuses has to be one redirect
    # refuses too. A Phoenix that grows that list fails here, instead of where a visitor would meet
    # it — as a 500 on the redirect that was meant to take them back to the page they asked for.
    test "signs an address exactly when a redirect would hand it out" do
      addresses =
        for byte <- 0..255,
            character = <<byte>>,
            piece <- [character, "%" <> Base.encode16(character)],
            around <- ["/", "/a", "/a/", "/a/b?q="],
            do: around <> piece <> "/z"

      for address <- addresses ++ ["", "/", "//x", "///x", "a", "/a?b=c"] do
        assert signs?(address) == redirects?(address), "disagreed over #{inspect(address)}"
      end
    end
  end

  describe "signing out" do
    test "the DELETE the sign-out page posts to ends a real session", %{conn: conn, site: site} do
      user = register_user("leaving@example.com", site.id)

      signed_in = get(conn, handoff(user))
      assert Plug.Conn.get_session(signed_in, "user_token")

      signed_out =
        signed_in |> Phoenix.ConnTest.recycle() |> with_host() |> delete("/auth/sign-out")

      assert redirected_to(signed_out) == "/"
      refute Plug.Conn.get_session(signed_out, "user_token")
    end
  end

  # A MASTER SIGNS IN ON THE MASTER SITE'S OWN ADDRESS, once its sign-in page was asked for the
  # master accounts: the flag that leaves the sign-in unscoped travels in the session.
  describe "master sign-in" do
    test "a master signs in on the master site's own address", %{conn: conn} do
      master = user_with(["admin:dashboard:*"], nil)

      signed_in =
        conn
        |> Plug.Test.init_test_session(%{master_mode: true})
        |> get(handoff(master))

      assert redirected_to(signed_in) == "/"
      assert get_session(signed_in, "user_token")

      next = signed_in |> Phoenix.ConnTest.recycle() |> with_host() |> get("/admin/dashboard")
      assert next.assigns.current_user.id == master.id
    end
  end

  # AN OFFLINE SITE SIGNS IN ONLY WHO MAY SEE IT: its own admins, and masters. Everyone else is
  # turned back at the one place every sign-in ends, before a session is written, and is told why.
  # The emails that would lead to a sign-in are not sent to them either.
  describe "signing in while the site is offline" do
    setup %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("cms.offline", true, site_id: site.id)

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SettingsState.delete(site.id, "cms.offline")
      end)

      :ok
    end

    test "the site's admin is signed in", %{conn: conn, site: site} do
      conn = get(conn, handoff(user_with(["*"], site.id)))

      assert redirected_to(conn) == "/"
      assert get_session(conn, :live_socket_id)
    end

    test "the site's admin of one dashboard area is signed in", %{conn: conn, site: site} do
      conn = get(conn, handoff(user_with(["admin:dashboard:runtime:media"], site.id)))

      assert redirected_to(conn) == "/"
      assert get_session(conn, :live_socket_id)
    end

    test "the site's API-only admin is turned back: the screens are not its surface", %{
      conn: conn,
      site: site
    } do
      conn = get(conn, handoff(user_with(["admin:api:*"], site.id)))

      assert redirected_to(conn) == "/auth"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "offline"
      refute get_session(conn, :live_socket_id)
    end

    test "anyone else is turned back to sign-in, told why, with no session", %{
      conn: conn,
      site: site
    } do
      conn = get(conn, handoff(user_with(["probe:role"], site.id)))

      assert redirected_to(conn) == "/auth"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "offline"
      refute get_session(conn, :live_socket_id)
    end

    test "a sign-in email goes to the site's admin, and to nobody else", %{site: site} do
      admin = user_with(["*"], site.id)
      member = user_with(["probe:role"], site.id)

      SendMagicLinkEmail.send(admin, "token", tenant: site.id)
      assert_email_sent(to: to_string(admin.email))

      SendMagicLinkEmail.send(member, "token", tenant: site.id)
      SendPasswordResetEmail.send(member, "token", tenant: site.id)

      SendMagicLinkEmail.send("new-#{System.unique_integer([:positive])}@example.com", "token",
        tenant: site.id
      )

      refute_email_sent()
    end

    test "a plugin on AuthController.Success.Refused may word what the visitor is told", %{
      conn: conn,
      site: site
    } do
      register_plugin(
        MishkaCmsCore.Test.Plugins.AuthSuccessRefused,
        "AuthController.Success.Refused"
      )

      conn = get(conn, handoff(user_with(["probe:role"], site.id)))

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "A plugin says: come back later"
      refute get_session(conn, :live_socket_id)
    end

    test "an email held back is announced on auth:email:held", %{site: site} do
      Process.register(self(), :__plugin_hook_probe__)
      register_plugin(MishkaCmsCore.Test.Plugins.AuthEmailHeld, "auth:email:held")
      site_id = site.id

      SendMagicLinkEmail.send(user_with(["probe:role"], site.id), "token", tenant: site.id)

      assert_receive {:email_held, ^site_id}
    end
  end

  # A WAY IN THAT ASKED NO AUTHENTICATOR CODE opens no session for an account that has one. The token
  # AshAuthentication signed for the reset was never handed out, and is revoked so none is left valid.
  describe "a password reset of an account with an authenticator" do
    defp enable_authenticator!(user) do
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
    end

    defp reset(conn, user) do
      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)

      post(conn, "/api/auth/user/password/reset", %{
        "user" => %{
          "reset_token" => token,
          "password" => @password,
          "password_confirmation" => @password
        }
      })
    end

    defp token_purposes(user) do
      subject = "user?id=#{user.id}"

      MishkaCmsCore.Accounts.Token
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(subject == ^subject)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.purpose)
      |> Enum.frequencies()
    end

    test "sends the visitor to sign in with the code, and leaves no new token valid", %{
      conn: conn,
      site: site
    } do
      user = "reset-totp@example.com" |> register_user(site.id) |> enable_authenticator!()
      before = token_purposes(user)
      assert Map.get(before, "user", 0) > 0, "the account holds a valid token to begin with"

      conn = reset(conn, user)

      assert redirected_to(conn) == "/auth"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Sign in with your password and the code from your authenticator app."

      refute get_session(conn, "user_token"), "a session was opened without the code"

      after_reset = token_purposes(user)

      assert Map.keys(after_reset) == ["revocation"],
             "the reset left a token that is not revoked: #{inspect(after_reset)}"

      assert after_reset["revocation"] > Map.get(before, "revocation", 0)
    end

    test "an account without one is signed in by the same reset", %{conn: conn, site: site} do
      user = register_user("reset-plain@example.com", site.id)

      conn = reset(conn, user)

      assert redirected_to(conn) == "/"
      assert get_session(conn, "user_token")
    end
  end

  # A RESET OR A MAGIC LINK ASKED FOR OVER ITS ROUTE ends with no user signed in, whether or not an
  # account holds the address, and goes back to `/auth` saying neither.
  describe "a reset or a magic link asked for over its route" do
    defp request_over_route(route, email) do
      build_conn()
      |> with_host()
      |> post("/api/auth/user/#{route}", %{"user" => %{"email" => email}})
    end

    test "goes back to sign-in with a message that says nothing about the account" do
      for route <- ["password/reset_request", "magic_link/request"] do
        conn =
          request_over_route(route, "nobody-#{System.unique_integer([:positive])}@example.com")

        assert redirected_to(conn) == "/auth", route

        assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
                 "If an account exists for that email, a link is on its way."
      end
    end

    test "a plugin on AuthController.Success.Requested may word what the visitor is told, or answer instead" do
      register_plugin(
        MishkaCmsCore.Test.Plugins.AuthSuccessRequested,
        "AuthController.Success.Requested"
      )

      email = "someone-#{System.unique_integer([:positive])}@example.com"

      reset = request_over_route("password/reset_request", email)

      assert redirected_to(reset) == "/auth"
      assert Phoenix.Flash.get(reset.assigns.flash, :info) == "A plugin says: check your inbox"

      assert "magic_link/request" |> request_over_route(email) |> redirected_to() == "/help"
    end
  end

  # A SIGN-IN THAT ENDS BACK ON THE SIGN-IN PAGE ENDS ON IT IN THE LANGUAGE THE VISITOR WAS READING,
  # which the last page they read left in the session — whatever URL mode the site is in.
  describe "the sign-in page a visitor is sent back to" do
    setup %{site: site} do
      MishkaCmsCore.DataCase.forget_settings(~w(site.languages site.language_urls), [site.id])
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok
    end

    defp sent_back(session) do
      build_conn()
      |> with_host()
      |> Plug.Test.init_test_session(session)
      |> post("/api/auth/user/password/reset_request", %{
        "user" => %{"email" => "nobody-#{System.unique_integer([:positive])}@example.com"}
      })
      |> redirected_to()
    end

    test "is in the language the visitor reads, the first one unprefixed", %{site: site} do
      language = MishkaCmsCore.Runtime.Languages.session()

      assert sent_back(%{language => "fa"}) == "/fa/auth"
      assert sent_back(%{language => "en"}) == "/auth"
      assert sent_back(%{}) == "/auth"

      {:ok, _} =
        MishkaCmsCore.Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert sent_back(%{language => "fa"}) == "/fa/auth"
      assert sent_back(%{}) == "/en/auth"
    end

    test "is the site's first language for one the site no longer publishes" do
      assert sent_back(%{MishkaCmsCore.Runtime.Languages.session() => "de"}) == "/auth"
    end
  end

  # AN EVENT ONE OF WHOSE PLUGINS IS NOT LOADED answers with the state it was handed, so every way
  # in and out ends as it does with no plugin listening.
  describe "while its plugin events cannot run" do
    test "a password sign-in still writes the session", %{conn: conn, site: site} do
      EventCannotRun.stub!([
        "AuthController.Success.BeforeAuth",
        "AuthController.Success.SignIn",
        "AuthController.Success.AfterAuthentication",
        "AuthController.Success.BeforeRedirect"
      ])

      conn = get(conn, handoff(register_user("unloaded-in@example.com", site.id)))

      assert redirected_to(conn) == "/"
      assert get_session(conn, "user_token")
      assert get_session(conn, :live_socket_id)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You are now signed in"
    end

    test "signing out still ends the session", %{conn: conn, site: site} do
      signed_in = get(conn, handoff(register_user("unloaded-out@example.com", site.id)))
      assert get_session(signed_in, "user_token")

      EventCannotRun.stub!([
        "AuthController.SignOut.BeforeSignOut",
        "AuthController.SignOut.BeforeRedirect"
      ])

      signed_out =
        signed_in |> Phoenix.ConnTest.recycle() |> with_host() |> delete("/auth/sign-out")

      assert redirected_to(signed_out) == "/"
      refute get_session(signed_out, "user_token")
      assert Phoenix.Flash.get(signed_out.assigns.flash, :info) == "You are now signed out"
    end

    test "a sign-in token that does not verify still goes back to sign-in", %{conn: conn} do
      EventCannotRun.stub!([
        "AuthController.Failure.BeforeFailure",
        "AuthController.Failure.InvalidCredentials",
        "AuthController.Failure.BeforeRedirect"
      ])

      conn = get(conn, "/api/auth/user/password/sign_in_with_token?token=not-a-token")

      assert redirected_to(conn) == "/auth"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Incorrect email or password"
      refute get_session(conn, "user_token")
    end

    test "a reset asked for over its route still goes back to sign-in" do
      EventCannotRun.stub!("AuthController.Success.Requested")

      conn =
        build_conn()
        |> with_host()
        |> post("/api/auth/user/password/reset_request", %{
          "user" => %{"email" => "unloaded-#{System.unique_integer([:positive])}@example.com"}
        })

      assert redirected_to(conn) == "/auth"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "If an account exists for that email, a link is on its way."
    end

    test "an offline site still turns back who may not see it", %{conn: conn, site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("cms.offline", true, site_id: site.id)

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SettingsState.delete(site.id, "cms.offline")
      end)

      EventCannotRun.stub!("AuthController.Success.Refused")

      conn = get(conn, handoff(user_with(["probe:role"], site.id)))

      assert redirected_to(conn) == "/auth"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "offline"
      refute get_session(conn, :live_socket_id)
    end

    test "a request refused for its rate is still answered with a 429" do
      previous = Application.fetch_env(:mishka_cms_core, AuthRateLimit)
      Application.put_env(:mishka_cms_core, AuthRateLimit, limit: 1)

      on_exit(fn ->
        case previous do
          {:ok, env} -> Application.put_env(:mishka_cms_core, AuthRateLimit, env)
          :error -> Application.delete_env(:mishka_cms_core, AuthRateLimit)
        end
      end)

      EventCannotRun.stub!("auth:request:rate_limited")
      email = "limited-#{System.unique_integer([:positive])}@example.com"

      [_first, second] =
        for _try <- 1..2 do
          build_conn()
          |> with_host()
          |> post("/api/auth/user/password/reset_request", %{"user" => %{"email" => email}})
        end

      assert second.status == 429
      assert [_seconds] = get_resp_header(second, "retry-after")
      assert second.resp_body =~ ~s(id="auth-rate-limited")
    end
  end

  defp register_plugin(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end
end
