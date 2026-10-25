# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TwoStepPolicyLiveTest do
  @moduledoc """
  The dashboard under each two-step policy (`MishkaCmsCore.Accounts.SecondFactor.policy/1`):
  Required sends an admin without an authenticator to the Preferences tab from every other page
  until they set one up (`MishkaCmsCore.Accounts.TwoStepGuard`); Recommended reminds them on the
  dashboard, linking there; Off turns the security cards into a note that nothing is asked.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  @home "/admin/dashboard"
  @preferences "/admin/dashboard/settings?tab=preferences"
  @password "Password123!"

  setup %{conn: conn} do
    snapshot = SettingsState.snapshot()
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

    on_exit(fn ->
      SettingsState.restore(snapshot)
      :persistent_term.erase(:mishka_installed)
    end)

    {:ok, conn: conn, site: site, admin: admin!(site)}
  end

  describe "Required" do
    setup %{site: site}, do: policy!(site, "required")

    test "sends an admin without an authenticator to the Preferences tab, and keeps them there",
         ctx do
      assert {:error, {:redirect, %{to: to, flash: %{"error" => why}}}} =
               open(ctx.conn, ctx.admin, @home)

      assert to =~ "/admin/dashboard/settings?tab=preferences"
      assert why =~ "two steps"

      {:ok, view, _html} = open(ctx.conn, ctx.admin, @preferences)
      assert has_element?(view, "#two-factor-policy", "requires")

      assert {:error, {:redirect, %{to: back}}} =
               render_patch(view, "/admin/dashboard/settings?tab=general")

      assert back =~ "tab=preferences"
    end

    test "opens the dashboard once the admin has one", ctx do
      enable!(ctx.admin)

      assert {:ok, _view, _html} = open(ctx.conn, ctx.admin, @home)
    end
  end

  describe "Recommended" do
    test "reminds an admin without an authenticator on the dashboard, linking to set it up",
         ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.admin, @home)
      refute has_element?(view, "#two-step-reminder")

      policy!(ctx.site, "recommended")
      {:ok, view, _html} = open(ctx.conn, ctx.admin, @home)

      assert has_element?(view, "#two-step-reminder")
      assert has_element?(view, "#two-step-reminder-link[href*='tab=preferences']")
    end
  end

  describe "Off" do
    test "the security cards say nothing is asked, and offer no setup", ctx do
      policy!(ctx.site, "off")
      {:ok, view, _html} = open(ctx.conn, ctx.admin, @preferences)

      assert has_element?(view, "#two-factor-policy-off")
      refute has_element?(view, "#two-factor-start")
      assert has_element?(view, "#recovery-codes-off", "turned off")
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp policy!(site, policy) do
    {:ok, _} = Settings.put("security.two_step", policy, site_id: site.id)
    :ok
  end

  defp admin!(site) do
    create_user_with_permissions!(["admin:dashboard:*"],
      site_id: site.id,
      password: @password,
      password_confirmation: @password
    )
  end

  defp open(conn, user, path) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
    |> live(path)
    |> case do
      {:ok, view, html} ->
        render_async(view)
        {:ok, view, html}

      other ->
        other
    end
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
        code: MishkaCmsCore.Test.Totp.code(secret)
      },
      actor: user,
      tenant: user.site_id
    )
    |> Ash.update!()
  end
end
