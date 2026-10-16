# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.OfflineTest do
  @moduledoc """
  What "offline" means, end to end: who may set it, how a site's switch and the master's combine,
  and what a site that is down still accepts.

  The ETS settings cache is process-global rather than sandboxed, so every test refreshes it from the
  (rolled-back) database on exit — the same way `MishkaCmsCore.SettingsTest` does.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.SiteHealth
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCoreWeb.Live.Admin.Components.SiteHealthPanel

  require Phoenix.LiveViewTest

  # The settings cache is process-global rather than sandboxed, so a switch thrown here is still on
  # for whatever runs next — including suites that have nothing to do with this one. Refreshing from
  # the database on the way out is not enough: `on_exit` runs in its own process, without the
  # sandbox's connection, so the read that would restore the cache cannot happen. Every write here
  # therefore drops its own key straight out of ETS, which is a GenServer call and needs no database.
  setup do
    SettingsState.refresh()
    :ok
  end

  defp offline(site_or_nil, value) do
    id = site_or_nil && site_or_nil.id
    opts = if id, do: [site_id: id], else: []

    {:ok, _} = Settings.put("cms.offline", value, opts)
    on_exit(fn -> SettingsState.delete(id, "cms.offline") end)

    :ok
  end

  defp site!, do: create_site!()

  describe "a site's switch and the master's" do
    test "a site is online until something says otherwise" do
      refute Settings.offline?(site!())
      refute Settings.offline?(nil)
    end

    test "a site takes itself offline without touching its neighbours" do
      [one, two] = [site!(), site!()]

      offline(one, true)

      assert Settings.offline?(one)
      refute Settings.offline?(two)
      refute Settings.offline?(nil)
    end

    test "a master takes every site offline at once" do
      [one, two] = [site!(), site!()]

      offline(nil, true)

      assert Settings.offline?(one)
      assert Settings.offline?(two)
      assert Settings.offline?(nil)
    end

    # The one setting that does not resolve the usual way. Everywhere else a site's value replaces
    # the global one, which would let a site walk out of a CMS-wide maintenance window.
    test "a site cannot turn itself back on while the master's switch is on" do
      site = site!()

      offline(site, false)
      offline(nil, true)

      assert Settings.offline?(site)
    end

    test "and is online again once the master's switch goes off, if its own is off" do
      site = site!()

      offline(nil, true)
      offline(nil, false)

      refute Settings.offline?(site)
    end

    test "but stays offline on its own switch after the master's goes off" do
      site = site!()

      offline(site, true)
      offline(nil, true)
      offline(nil, false)

      assert Settings.offline?(site)
    end

    test "takes a site id as readily as a site" do
      site = site!()

      offline(site, true)

      assert Settings.offline?(site.id)
    end
  end

  # What the status widgets and the settings page say: which switch holds a site down.
  describe "which switch holds a site offline" do
    test "none while it is online" do
      assert Settings.offline_by(site!()) == []
      assert Settings.offline_by(nil) == []
    end

    test "its own, the master's, or both" do
      [own, neighbour] = [site!(), site!()]

      offline(own, true)

      assert Settings.offline_by(own) == [:site]
      assert Settings.offline_by(own.id) == [:site]
      assert Settings.offline_by(neighbour) == []

      offline(nil, true)

      assert Settings.offline_by(own) == [:global, :site]
      assert Settings.offline_by(neighbour) == [:global]
      assert Settings.offline_by(nil) == [:global]
    end

    # `get/3` would answer the global value for a site that set nothing, and call it the site's own.
    test "a site's own switch is its own row, never the global one read through it" do
      site = site!()

      offline(nil, true)

      assert Settings.get_own("cms.offline", false, site.id) == false
      assert Settings.get("cms.offline", false, site.id) == true
      refute :site in Settings.offline_by(site)
    end
  end

  # The Sites page's health panel said "Serving requests" for a site whose visitors saw its offline
  # page, because it read `site.active` alone.
  describe "a site's health" do
    test "says it is offline, and by which switch" do
      [own, neighbour] = [site!(), site!()]

      assert %{state: :healthy, offline_by: []} = SiteHealth.compute(own)

      offline(own, true)

      assert %{state: :offline, offline_by: [:site], message: own_message} =
               SiteHealth.compute(own)

      assert own_message =~ "this site's settings"
      assert %{state: :healthy} = SiteHealth.compute(neighbour)

      offline(nil, true)

      assert %{state: :offline, offline_by: [:global], message: global_message} =
               SiteHealth.compute(neighbour)

      assert global_message =~ "Global"
    end

    test "and the panel no longer says it is serving requests" do
      site = site!()
      offline(site, true)

      html =
        Phoenix.LiveViewTest.render_component(&SiteHealthPanel.panel/1,
          health: SiteHealth.compute(site)
        )

      assert html =~ "Offline (maintenance)"
      refute html =~ "Serving requests"
    end
  end

  # A site words its own holding page: the message is set per site and read with the site's id.
  describe "the maintenance message" do
    test "is declared for both the global view and a site's own" do
      declaration =
        Settings.load_definitions()
        |> Enum.find(&(&1.key == "cms.maintenance_message"))

      assert %{scope: :both} = declaration
    end
  end

  # `scope: :both` is what puts the switch on a tenant's own settings page as well as the master's
  # Global view. `:master` — what it was — hides it from a site entirely. Definitions are aggregated
  # into `:persistent_term` at boot, which a test harness does not run, so this loads them itself.
  describe "who can reach the switch" do
    test "it is declared for both the global view and a site's own" do
      declaration =
        Settings.load_definitions()
        |> Enum.find(&(&1.key == "cms.offline"))

      assert %{scope: :both, type: :boolean} = declaration
    end
  end

  describe "registering while a site is offline" do
    setup do
      site = site!()
      offline(site, true)

      %{site: site}
    end

    test "is refused, and says why", %{site: site} do
      assert {:error, %Ash.Error.Forbidden{} = error} =
               register(site, "newcomer#{unique()}@example.com")

      assert Exception.message(error) =~ "not taking new accounts"
    end

    # Through AshAuthentication itself, which is how a real sign-up arrives. Its own
    # `AshAuthenticationInteraction` bypass authorizes every action it runs, so a policy placed after
    # that bypass would never be consulted on this path — the order in the resource is the fix, and
    # this is the test that would notice it moving.
    test "including through the strategy the sign-up form posts to", %{site: site} do
      {:ok, strategy} = AshAuthentication.Info.strategy(User, :password)

      assert {:error, _refused} =
               AshAuthentication.Strategy.action(
                 strategy,
                 :register,
                 %{
                   "email" => "newcomer#{unique()}@example.com",
                   "password" => "Password123!",
                   "password_confirmation" => "Password123!"
                 },
                 tenant: site.id
               )
    end

    test "while the same registration is accepted on a site that is up" do
      assert {:ok, _user} = register(site!(), "newcomer#{unique()}@example.com")
    end

    test "and is refused everywhere once the master's switch is on" do
      offline(nil, true)

      assert {:error, %Ash.Error.Forbidden{}} =
               register(site!(), "newcomer#{unique()}@example.com")
    end
  end

  # Magic link used to be a second sign-up route: `registration_enabled? true` made its sign-in an
  # upsert, so a link requested for an address nobody held created the account on the way in, with
  # none of `register_with_password`'s validations. It signs in only now, which the library expresses
  # by building the action as a read.
  describe "magic link" do
    test "cannot create an account, because it cannot write at all" do
      assert %Ash.Resource.Actions.Read{} =
               Ash.Resource.Info.action(User, :sign_in_with_magic_link)
    end

    test "and the strategy agrees it does not register" do
      {:ok, strategy} = AshAuthentication.Info.strategy(User, :magic_link)

      refute strategy.registration_enabled?
    end

    # Asking for a link is answered the same way whoever asks — telling a stranger that an address is
    # unknown would be a way to enumerate accounts — but nothing is created by asking.
    test "so asking for a link for an address nobody holds creates nobody" do
      {:ok, strategy} = AshAuthentication.Info.strategy(User, :magic_link)
      before = count_users()

      AshAuthentication.Strategy.action(
        strategy,
        :request,
        %{"email" => "stranger#{unique()}@example.com"},
        []
      )

      assert count_users() == before
    end
  end

  defp unique, do: System.unique_integer([:positive])

  defp count_users, do: User |> Ash.Query.for_read(:read) |> Ash.count!(authorize?: false)

  defp register(site, email) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: "Password123!", password_confirmation: "Password123!"},
      tenant: site.id
    )
    |> Ash.create()
  end
end
