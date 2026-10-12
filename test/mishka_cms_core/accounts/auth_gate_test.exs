defmodule MishkaCmsCore.Accounts.AuthGateTest do
  @moduledoc """
  `MishkaCmsCore.Accounts.AuthGate`: a site — or the installation, for every site — closing
  sign-in, registration, password reset and sign-in links, with who still gets in, asked at the
  account actions themselves.

  `async: false` — the settings cache, `SiteState` and the mailbox are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias AshAuthentication.Errors.AuthenticationFailed
  alias MishkaCmsCore.Accounts.{AuthGate, User}
  alias MishkaCmsCore.Accounts.AuthGate.Closed
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, ViewerState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @password "Password123!"

  defmodule CloseEverything do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "auth:gate:check"

    @impl true
    def call(data), do: {:reply, %{data | allowed?: false}}
  end

  setup do
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    %{site: site!(), other: site!()}
  end

  defp site! do
    host = "gate-#{System.unique_integer([:positive])}.test"
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

  defp email!, do: "someone-#{System.unique_integer([:positive])}@example.com"

  defp close!(action, site_id),
    do: {:ok, _} = Settings.put("auth.#{action}.closed", true, site_id: site_id)

  defp sign_out_on!(site_id),
    do: {:ok, _} = Settings.put("auth.sign_in.sign_out", true, site_id: site_id)

  defp context, do: %{private: %{ash_authentication?: true}}

  defp purposes(user) do
    subject = "user?id=#{user.id}"

    MishkaCmsCore.Accounts.Token
    |> Ash.Query.filter(subject == ^subject)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.purpose)
  end

  defp sign_in(site_id, email, password \\ @password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password},
      tenant: site_id,
      context: context()
    )
    |> Ash.read_one()
  end

  defp register(site_id, email) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      tenant: site_id,
      context: context()
    )
    |> Ash.create()
  end

  defp ask_reset(site_id, email) do
    User
    |> Ash.ActionInput.for_action(:request_password_reset_token, %{email: email},
      tenant: site_id,
      context: context()
    )
    |> Ash.run_action()
  end

  defp closed?({:error, error}, action), do: AuthGate.refusal(error) == %{action: action}
  defp closed?(_answer, _action), do: false

  describe "signing in" do
    test "a closed site refuses its users once the password is right, and only then", %{
      site: site
    } do
      email = email!()
      create_user!(site_id: site.id, email: email)
      close!(:sign_in, site.id)

      assert closed?(sign_in(site.id, email), :sign_in)

      assert {:error, %{errors: [%AuthenticationFailed{}]}} =
               sign_in(site.id, email, "wrong-password"),
             "a wrong password says nothing about the gate"
    end

    test "the token AshAuthentication made for a refused sign-in is revoked, not left valid", %{
      site: site
    } do
      user = create_user!(site_id: site.id, email: email!())
      close!(:sign_in, site.id)

      before = Enum.frequencies(purposes(user))

      assert closed?(sign_in(site.id, to_string(user.email)), :sign_in)

      after_refusal = Enum.frequencies(purposes(user))

      assert Map.get(after_refusal, "user", 0) == Map.get(before, "user", 0),
             "the refused sign-in left a valid token"

      assert Map.get(after_refusal, "revocation", 0) == Map.get(before, "revocation", 0) + 1
    end

    test "a site closing its sign-in leaves every other site open", %{site: site, other: other} do
      email = email!()
      create_user!(site_id: other.id, email: email)
      close!(:sign_in, site.id)

      assert {:ok, %User{}} = sign_in(other.id, email)
    end

    test "the installation closes every site, with its own lists", %{site: site, other: other} do
      ours = email!()
      theirs = email!()
      create_user!(site_id: site.id, email: ours)
      create_user!(site_id: other.id, email: theirs)
      close!(:sign_in, nil)
      {:ok, _} = Settings.put("auth.allowed_emails", [theirs], site_id: nil)

      assert closed?(sign_in(site.id, ours), :sign_in)
      assert {:ok, %User{}} = sign_in(other.id, theirs)
    end

    test "an allowed address or permission still gets in, and a master always", %{site: site} do
      listed = email!()
      admin = email!()
      create_user!(site_id: site.id, email: listed)
      create_user_with_permissions!(["*"], site_id: site.id, email: admin)
      master = create_user!(email: email!())

      close!(:sign_in, site.id)
      close!(:sign_in, nil)
      {:ok, _} = Settings.put("auth.allowed_emails", [String.upcase(listed)], site_id: site.id)
      {:ok, _} = Settings.put("auth.allowed_emails", [listed], site_id: nil)

      assert {:ok, %User{}} = sign_in(site.id, listed)
      assert {:ok, %User{}} = sign_in(site.id, admin)
      assert {:ok, %User{}} = sign_in(nil, master.email)
    end

    test "a plugin on auth:gate:check decides last", %{site: site} do
      email = email!()
      create_user!(site_id: site.id, email: email)

      {:ok, _} =
        Event.write(%{
          name: CloseEverything,
          event: "auth:gate:check",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("auth:gate:check", :start, false)

      on_exit(fn ->
        Event.unregister(:name, CloseEverything, false)
        EventHandler.do_compile("auth:gate:check", :start, false)
      end)

      assert closed?(sign_in(site.id, email), :sign_in)
    end

    test "while the plugins on auth:gate:check cannot run, every way in is closed", %{site: site} do
      email = email!()
      create_user!(site_id: site.id, email: email)
      MishkaCmsCore.Test.EventCannotRun.stub!("auth:gate:check")

      assert closed?(sign_in(site.id, email), :sign_in)
      refute AuthGate.allowed?(:register, site.id, %{email: email!()})
    end
  end

  describe "who is already signed in" do
    test "stays while sign-in is only closed; with sign-out on, whoever could not sign in now goes",
         %{site: site, other: other} do
      member = create_user!(site_id: site.id, email: email!())
      admin = create_user_with_permissions!(["*"], site_id: site.id, email: email!())
      master = create_user!(email: email!())
      elsewhere = create_user!(site_id: other.id, email: email!())

      close!(:sign_in, site.id)
      refute AuthGate.signs_out?(site.id, member)

      sign_out_on!(site.id)
      assert AuthGate.signs_out?(site.id, member)
      refute AuthGate.signs_out?(site.id, admin)
      refute AuthGate.signs_out?(site.id, master)
      refute AuthGate.signs_out?(other.id, elsewhere)
      refute AuthGate.signs_out?(site.id, nil)
    end

    test "the installation's switches sign out on every site, by its own lists", %{
      site: site,
      other: other
    } do
      ours = create_user!(site_id: site.id, email: email!())
      listed = create_user!(site_id: other.id, email: email!())
      close!(:sign_in, nil)
      sign_out_on!(nil)
      {:ok, _} = Settings.put("auth.allowed_emails", [to_string(listed.email)], site_id: nil)

      assert AuthGate.signs_out?(site.id, ours)
      refute AuthGate.signs_out?(other.id, listed)
    end

    test "a cached viewer is answered as the account it caches", %{site: site} do
      member = create_user!(site_id: site.id, email: email!())
      admin = create_user_with_permissions!(["*"], site_id: site.id, email: email!())
      Enum.each([member, admin], &ViewerState.remember/1)
      on_exit(fn -> Enum.each([member, admin], &ViewerState.forget(&1.id)) end)
      close!(:sign_in, site.id)
      sign_out_on!(site.id)

      assert AuthGate.signs_out?(site.id, ViewerState.get(member.id))
      refute AuthGate.signs_out?(site.id, ViewerState.get(admin.id))
    end

    test "locks_out?/3 asks only what the save itself would change", %{site: site} do
      editor =
        create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id, email: email!())

      master = create_user!(email: email!())
      closing = %{{site.id, "auth.sign_in.closed"} => true}
      signing_out = Map.put(closing, {site.id, "auth.sign_in.sign_out"}, true)

      assert AuthGate.locks_out?(site.id, editor, closing)
      assert AuthGate.locks_out?(site.id, editor, signing_out)

      refute AuthGate.locks_out?(
               site.id,
               editor,
               Map.put(signing_out, {site.id, "auth.allowed_emails"}, [to_string(editor.email)])
             )

      refute AuthGate.locks_out?(site.id, master, signing_out)

      close!(:sign_in, nil)

      refute AuthGate.locks_out?(site.id, editor, closing),
             "the installation already keeps them out; this save changes nothing for them"
    end

    test "sign_out/2 revokes every token the account holds", %{site: site} do
      user = create_user!(site_id: site.id, email: email!())
      {:ok, %User{}} = sign_in(site.id, to_string(user.email))

      assert Enum.count(purposes(user), &(&1 == "user")) >= 2
      assert AuthGate.sign_out(user, site.id) == :ok
      refute "user" in purposes(user)
    end
  end

  describe "registering" do
    test "a closed site takes no new accounts but those it lists", %{site: site} do
      invited = email!()
      close!(:register, site.id)
      {:ok, _} = Settings.put("auth.allowed_emails", [invited], site_id: site.id)

      assert closed?(register(site.id, email!()), :register)
      assert {:ok, %User{}} = register(site.id, invited)
    end
  end

  describe "asking for a reset" do
    test "answers the same while closed, and mails only an account still let in", %{site: site} do
      plain = email!()
      admin = email!()
      create_user!(site_id: site.id, email: plain)
      create_user_with_permissions!(["*"], site_id: site.id, email: admin)
      close!(:reset, site.id)

      assert :ok = ask_reset(site.id, plain)
      refute_receive {:email, %Swoosh.Email{subject: "Reset your password", to: [{_, ^plain}]}}

      assert :ok = ask_reset(site.id, admin)
      assert_receive {:email, %Swoosh.Email{subject: "Reset your password", to: [{_, ^admin}]}}
    end
  end

  describe "completing a reset" do
    defp reset_token!(user) do
      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)
      token
    end

    defp reset_params(token),
      do: %{
        reset_token: token,
        password: "NewPassword123!",
        password_confirmation: "NewPassword123!"
      }

    test "is refused by its policy while reset is closed, and passes an allowed account", %{
      site: site
    } do
      plain = create_user!(site_id: site.id, email: email!())
      listed = create_user!(site_id: site.id, email: email!())
      close!(:reset, site.id)
      {:ok, _} = Settings.put("auth.allowed_emails", [to_string(listed.email)], site_id: site.id)

      reset = fn user ->
        user
        |> Ash.Changeset.for_update(:reset_password_with_token, reset_params(reset_token!(user)),
          tenant: site.id
        )
        |> Ash.update()
      end

      assert closed?(reset.(plain), :reset)
      assert {:ok, %User{}} = reset.(listed)
    end

    test "through the API is refused the same way", %{site: site} do
      user = create_user!(site_id: site.id, email: email!())
      close!(:reset, site.id)

      answer =
        User
        |> Ash.ActionInput.for_action(:reset_password_api, reset_params(reset_token!(user)),
          tenant: site.id,
          context: context()
        )
        |> Ash.run_action()

      assert closed?(answer, :reset)
    end
  end

  describe "the settings" do
    test "sit on the Security tab, beside the sign-in limits" do
      keys = Enum.map(Settings.definitions("security"), & &1.key)

      assert "security.sign_in_per_account" in keys

      assert "auth.sign_in.closed" in keys
      assert "auth.sign_in.sign_out" in keys
      assert "auth.allowed_permissions" in keys
      assert %{resolve: :any, scope: :both} = Settings.definition("auth.register.closed")
      assert Settings.get("auth.allowed_permissions") == ["*"]
    end

    test "say what is closed, for a page that knows no one yet", %{site: site} do
      refute AuthGate.closed?(:magic_link, site.id)
      close!(:magic_link, nil)
      assert AuthGate.closed?(:magic_link, site.id)
    end
  end

  test "a refusal reads the same in an error and in the JSON:API document" do
    error = Closed.exception(action: :register, site_id: nil)

    assert AuthGate.refusal(error) == %{action: :register}

    assert AuthGate.refusal(%{"code" => "auth_closed", "meta" => %{"action" => "reset"}}) ==
             %{action: :reset}

    assert %AshJsonApi.Error{status_code: 403, code: "auth_closed"} =
             AshJsonApi.ToJsonApiError.to_json_api_error(error)
  end
end
