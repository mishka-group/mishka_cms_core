# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TwoFactorTest do
  @moduledoc """
  The authenticator app in the dashboard (`MishkaCmsCore.Accounts.SecondFactor`): the signed-in
  account turns it on and off on the settings page's Preferences tab and makes its recovery codes
  there, and an admin of its site turns it off from the Users table for someone who lost the app,
  with a code from their own.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{SecondFactor, User}
  alias MishkaCmsCore.Runtime.States.SiteState

  @preferences "/admin/dashboard/settings?tab=preferences"
  @users "/admin/dashboard/account/users"
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

    {:ok, conn: conn, site: site}
  end

  describe "the Preferences tab" do
    test "sets one up with a code from the app, and turns it off with another", ctx do
      admin = admin!(ctx.site, ["admin:dashboard:*"])
      view = open(ctx.conn, admin, @preferences)

      assert view |> element("#two-factor-status") |> render() =~ "Off"

      view |> element("#two-factor-start") |> render_click()
      secret = view |> element("#two-factor-secret") |> render() |> secret()

      view
      |> form("#two-factor-confirm", %{"code" => "000000"})
      |> render_submit()

      assert has_element?(view, "#two-factor-message")
      refute SecondFactor.enabled?(reload(admin))

      view
      |> form("#two-factor-confirm", %{"code" => MishkaCmsCore.Test.Totp.code(secret)})
      |> render_submit()

      assert view |> element("#two-factor-status") |> render() =~ "On"
      assert SecondFactor.enabled?(reload(admin))

      view
      |> form("#two-factor-disable", %{"code" => "000000"})
      |> render_submit()

      assert SecondFactor.enabled?(reload(admin))

      later!(admin)

      view
      |> form("#two-factor-disable", %{"code" => MishkaCmsCore.Test.Totp.code(secret)})
      |> render_submit()

      assert view |> element("#two-factor-status") |> render() =~ "Off"
      refute SecondFactor.enabled?(reload(admin))
    end
  end

  describe "a code that is not six digits" do
    test "is answered in the card, and turns nothing on", ctx do
      admin = admin!(ctx.site, ["admin:dashboard:*"])
      view = open(ctx.conn, admin, @preferences)

      view |> element("#two-factor-start") |> render_click()

      for short <- ["", "12", "12345a"] do
        view |> form("#two-factor-confirm", %{"code" => short}) |> render_submit()

        assert view |> element("#two-factor-message") |> render() =~ "6-digit"
      end

      refute SecondFactor.enabled?(reload(admin))
    end
  end

  describe "recovery codes" do
    test "come after the authenticator, made with its code, shown once, then counted", ctx do
      admin = admin!(ctx.site, ["admin:dashboard:*"])
      view = open(ctx.conn, admin, @preferences)

      assert has_element?(view, "#recovery-codes-off")
      refute has_element?(view, "#recovery-codes-form")

      view |> element("#two-factor-start") |> render_click()
      secret = view |> element("#two-factor-secret") |> render() |> secret()

      view
      |> form("#two-factor-confirm", %{"code" => MishkaCmsCore.Test.Totp.code(secret)})
      |> render_submit()

      render_async(view)
      assert has_element?(view, "#recovery-codes-form")

      view |> form("#recovery-codes-form", %{"code" => "000000"}) |> render_submit()
      assert has_element?(view, "#recovery-codes-message")
      refute has_element?(view, "#recovery-codes-shown")

      later!(admin)

      view
      |> form("#recovery-codes-form", %{"code" => MishkaCmsCore.Test.Totp.code(secret)})
      |> render_submit()

      assert has_element?(
               view,
               "#recovery-codes-list li",
               ~r/\A\s*[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}\s*\z/
             )

      assert has_element?(view, "#recovery-codes-download[download='recovery-codes.txt']")

      view |> element("#recovery-codes-hide") |> render_click()

      refute has_element?(view, "#recovery-codes-shown")
      assert view |> element("#recovery-codes-status") |> render() =~ "10 left"
    end
  end

  describe "a code that was being typed when the page reconnected" do
    test "is still in the box of the setup form", ctx do
      admin = admin!(ctx.site, ["admin:dashboard:*"])
      view = open(ctx.conn, admin, @preferences)

      view |> element("#two-factor-start") |> render_click()
      view |> form("#two-factor-confirm", %{"code" => "123 45"}) |> render_change()

      assert view |> element("#two-factor-code") |> render() =~ ~s(value="123 45")

      view |> element("#two-factor-cancel") |> render_click()
      view |> element("#two-factor-start") |> render_click()

      refute view |> element("#two-factor-code") |> render() =~ "123 45"
    end

    test "is still in the box of the turn-off and the recovery-code forms", ctx do
      admin = admin!(ctx.site, ["admin:dashboard:*"])
      enable!(admin)
      view = open(ctx.conn, admin, @preferences)

      view |> form("#two-factor-disable", %{"code" => "9876"}) |> render_change()
      assert view |> element("#two-factor-disable-code") |> render() =~ ~s(value="9876")

      view |> form("#recovery-codes-form", %{"code" => "5432"}) |> render_change()
      assert view |> element("#recovery-codes-code") |> render() =~ ~s(value="5432")
    end

    test "is still in the box of the admin's turn-off step in the Users table", ctx do
      owner = admin!(ctx.site, ["admin:dashboard:blog:*"])
      enable!(owner)
      master = admin!(nil, ["admin:dashboard:*"])
      master |> enable!()

      view = open(ctx.conn, master, @users)

      view
      |> element(
        "button[phx-value-event=turn_off_two_step_modal][phx-value-values*='#{owner.id}']"
      )
      |> render_click()

      render_async(view)

      view |> form("#user-modal-turn-off-form", %{"code" => "246810"}) |> render_change()

      assert view |> element("#user-modal-turn-off-code") |> render() =~ ~s(value="246810")

      view |> element("button[phx-click=user_modal_turn_off_cancel]") |> render_click()

      refute has_element?(view, "#user-modal-turn-off-form")
    end
  end

  describe "the Users table" do
    test "shows who has one, and turns it off with the admin's own code", ctx do
      owner = admin!(ctx.site, ["admin:dashboard:blog:*"])
      enable!(owner)
      master = admin!(nil, ["admin:dashboard:*"])
      secret = master |> enable!() |> secret_of()
      later!(master)

      view = open(ctx.conn, master, @users)

      turn_off =
        "button[phx-value-event=turn_off_two_step_modal][phx-value-values*='#{owner.id}']"

      assert has_element?(view, turn_off)

      view |> element(turn_off) |> render_click()
      render_async(view)

      view
      |> form("#user-modal-turn-off-form", %{"code" => MishkaCmsCore.Test.Totp.code(secret)})
      |> render_submit()

      render_async(view)

      refute has_element?(view, turn_off)
      refute SecondFactor.enabled?(reload(owner))
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp admin!(site, permissions) do
    create_user_with_permissions!(permissions,
      site_id: site && site.id,
      password: @password,
      password_confirmation: @password
    )
  end

  defp open(conn, user, path) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(path)

    render_async(view)
    view
  end

  defp secret(html) do
    [_whole, key] = Regex.run(~r/>\s*([A-Z2-7 ]+?)\s*</, html)
    key |> String.replace(" ", "") |> Base.decode32!(padding: false)
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

  # As if the next 30-second period had come: the code that confirmed the setup is spent.
  defp later!(user) do
    user
    |> reload()
    |> Ash.Changeset.for_update(:record_totp_use, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:last_totp_at, DateTime.add(DateTime.utc_now(), -60))
    |> Ash.update!()
  end

  defp secret_of(user), do: reload(user).totp_secret

  defp reload(user), do: Ash.get!(User, user.id, tenant: user.site_id, authorize?: false)
end
