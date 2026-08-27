defmodule MishkaCmsCore.Accounts.TwoStepPolicyTest do
  @moduledoc """
  What two-step sign-in asks of a site's admins (`MishkaCmsCore.Accounts.SecondFactor.policy/1`): the
  master's choice for every site wins unless it leaves it to each site; a site's own choice then
  applies, and the master site's to masters. Off asks nobody for a code, even with an authenticator
  set up; Required owes a setup to an admin without one; Recommended reminds them at each sign-in.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{SecondFactor, User}
  alias MishkaCmsCore.Accounts.User.Notices.TwoStepReminder
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  @password "Password123!"

  setup do
    snapshot = SettingsState.snapshot()
    SiteState.clear()

    on_exit(fn ->
      SettingsState.restore(snapshot)
      SiteState.clear()
    end)

    master_site = create_site!(name: "master", host: "master.test", active: true, master: true)
    site = create_site!(name: "tenant", host: "tenant.test", active: true)

    for s <- [master_site, site] do
      :ok =
        SiteState.save(%{
          id: s.id,
          name: s.name,
          host: s.host,
          priority: s.priority,
          active: true,
          master: s.master
        })
    end

    %{site: site, master_site: master_site}
  end

  describe "the policy" do
    test "is Optional until anyone chooses", %{site: site} do
      assert SecondFactor.policy(site.id) == :optional
      assert SecondFactor.policy(nil) == :optional
    end

    test "is the site's own while the master leaves it to each site, the master site's for masters",
         %{site: site, master_site: master_site} do
      site_policy!(site, "required")
      site_policy!(master_site, "recommended")

      assert SecondFactor.policy(site.id) == :required
      assert SecondFactor.policy(nil) == :recommended
    end

    test "is the master's for every site once it names one", %{site: site} do
      site_policy!(site, "required")
      {:ok, _} = Settings.put("security.two_step.every_site", "off")

      assert SecondFactor.policy(site.id) == :off
      assert SecondFactor.policy(nil) == :off
    end
  end

  describe "Off" do
    test "asks an account with an authenticator for no code", %{site: site} do
      user = admin!(site, ["admin:dashboard:*"])
      enable!(user)
      assert SecondFactor.asked?(reload(user))

      site_policy!(site, "off")

      refute SecondFactor.asked?(reload(user))
      assert {:ok, %User{}} = sign_in(user)
    end
  end

  describe "Required and Recommended" do
    test "owe a setup to, or remind, an admin without an authenticator — nobody else", %{
      site: site
    } do
      admin = admin!(site, ["admin:dashboard:*"])
      member = admin!(site, [])
      with_one = admin!(site, ["admin:dashboard:*"])
      enable!(with_one)

      site_policy!(site, "required")
      assert SecondFactor.owed?(admin)
      refute SecondFactor.owed?(member)
      refute SecondFactor.owed?(reload(with_one))
      refute SecondFactor.reminded?(admin)

      site_policy!(site, "recommended")
      assert SecondFactor.reminded?(admin)
      refute SecondFactor.reminded?(member)
      refute SecondFactor.owed?(admin)
    end

    test "Recommended sends the reminder notification at sign-in, and only then", %{site: site} do
      admin = admin!(site, ["admin:dashboard:*"])

      TwoStepReminder.call(%{user: admin, conn: nil})
      assert notifications(admin) == []

      site_policy!(site, "recommended")
      TwoStepReminder.call(%{user: admin, conn: nil})

      assert [%{type: "cms_core:account:two_step_recommended", link: link}] = notifications(admin)
      assert link =~ "tab=preferences"
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp site_policy!(site, policy),
    do: {:ok, _} = Settings.put("security.two_step", policy, site_id: site.id)

  defp admin!(site, permissions) do
    create_user_with_permissions!(permissions,
      site_id: site.id,
      password: @password,
      password_confirmation: @password
    )
  end

  defp enable!(user) do
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

  defp sign_in(user) do
    User
    |> Ash.Query.for_read(
      :sign_in_with_password,
      %{email: to_string(user.email), password: @password},
      tenant: user.site_id
    )
    |> Ash.read_one()
  end

  defp notifications(user) do
    MishkaCmsCore.Notify.Notification
    |> Ash.read!(authorize?: false, tenant: user.site_id)
    |> Enum.filter(&(&1.user_id == user.id))
  end

  defp reload(user), do: Ash.get!(User, user.id, tenant: user.site_id, authorize?: false)
end
