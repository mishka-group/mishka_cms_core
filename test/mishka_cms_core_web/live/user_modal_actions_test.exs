# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.UserModalActionsTest do
  @moduledoc """
  The Users page's account actions beside the user modal's close button and in the table's rows:
  Confirm account, for an account whose confirmation email never came, and Turn off two-step, for
  one that lost its authenticator app — which asks a current code from the admin's own authenticator,
  and sends an admin without one to set theirs up. Each is shown only when the policies let the
  admin run it on that account, and never Turn off two-step on the admin's own account, which takes
  a code on the Preferences tab.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{SecondFactor, User}
  alias MishkaCmsCore.Runtime.States.SiteState

  @users "/admin/dashboard/account/users"
  @password "Password123!"
  @confirm "#user-modal-confirm"
  @turn_off "#user-modal-turn-off-two-step"

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

  describe "the user modal" do
    test "confirms an account whose email is not confirmed yet", ctx do
      master = admin!(nil, ["admin:dashboard:*"])
      writer = create_user!(site_id: ctx.site.id)
      view = open(ctx.conn, master)

      show(view, writer)
      view |> element(@confirm) |> render_click()
      render_async(view)

      refute has_element?(view, @confirm)
      assert reload(writer).confirmed_at
      assert render(view) =~ "The account is confirmed."
    end

    test "turns off another account's two-step with the admin's own code, never the admin's own",
         ctx do
      admin = admin!(ctx.site, ["admin:dashboard:*"])
      owner = admin!(ctx.site, ["admin:dashboard:blog:*"])
      secret = enable!(admin)
      enable!(owner)
      view = open(ctx.conn, admin)

      show(view, admin)
      refute has_element?(view, @turn_off)

      show(view, owner)
      view |> element(@turn_off) |> render_click()
      assert has_element?(view, "#user-modal-turn-off-form")

      view |> form("#user-modal-turn-off-form", %{"code" => "12"}) |> render_submit()
      assert has_element?(view, "#user-modal-turn-off-error", "6-digit")

      view |> form("#user-modal-turn-off-form", %{"code" => "000000"}) |> render_submit()
      assert has_element?(view, "#user-modal-turn-off-error")
      assert SecondFactor.enabled?(reload(owner))

      later!(admin)

      view
      |> form("#user-modal-turn-off-form", %{"code" => NimbleTOTP.verification_code(secret)})
      |> render_submit()

      render_async(view)

      refute has_element?(view, "#user-modal-turn-off")
      refute has_element?(view, @turn_off)
      refute SecondFactor.enabled?(reload(owner))
      assert SecondFactor.enabled?(reload(admin))
    end

    test "sends an admin without an authenticator of their own to set one up first", ctx do
      master = admin!(nil, ["admin:dashboard:*"])
      owner = admin!(ctx.site, ["admin:dashboard:blog:*"])
      enable!(owner)
      view = open(ctx.conn, master)

      show(view, owner)
      view |> element(@turn_off) |> render_click()

      assert has_element?(view, "#user-modal-turn-off-own")
      assert has_element?(view, "#user-modal-turn-off-setup[href*='tab=preferences']")
      refute has_element?(view, "#user-modal-turn-off-form")
    end

    test "offers neither where it does not apply: an account holding more, one confirmed", ctx do
      owner = admin!(ctx.site, ["*"])
      enable!(owner)
      admin = ctx.site |> admin!(["admin:dashboard:user"]) |> confirm!()
      view = open(ctx.conn, admin)

      show(view, owner)
      refute has_element?(view, @turn_off)

      show(view, admin)
      refute has_element?(view, @confirm)
    end
  end

  describe "the Users table" do
    test "opens an account's modal on the turn-off step from its row", ctx do
      master = admin!(nil, ["admin:dashboard:*"])
      owner = admin!(ctx.site, ["admin:dashboard:blog:*"])
      enable!(owner)
      enable!(master)
      view = open(ctx.conn, master)

      view
      |> element(
        "button[phx-value-event=turn_off_two_step_modal][phx-value-values*='#{owner.id}']"
      )
      |> render_click()

      render_async(view)

      assert has_element?(view, "#user-modal-turn-off-form")
      assert SecondFactor.enabled?(reload(owner))
    end

    test "confirms an account from its row", ctx do
      master = admin!(nil, ["admin:dashboard:*"])
      writer = create_user!(site_id: ctx.site.id)
      view = open(ctx.conn, master)
      confirm = "button[phx-value-event=confirm_account][phx-value-id='#{writer.id}']"

      view |> element(confirm) |> render_click()

      refute has_element?(view, confirm)
      assert reload(writer).confirmed_at
    end

    test "has no Turn off two-step on the admin's own row", ctx do
      master = admin!(nil, ["admin:dashboard:*"])
      enable!(master)
      view = open(ctx.conn, master)

      refute has_element?(
               view,
               "button[phx-value-event=turn_off_two_step_modal][phx-value-values*='#{master.id}']"
             )
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

  defp open(conn, user) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(@users)

    render_async(view)
    view
  end

  defp show(view, user) do
    send(view.pid, {:row_action, "show_user_modal", %{"id" => user.id}})
    render_async(view)
  end

  # Hands back the authenticator's secret, for the test to compute codes from.
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

    secret
  end

  # As if the next 30-second period had come: the code that confirmed the setup is spent.
  defp later!(user) do
    user
    |> reload()
    |> Ash.Changeset.for_update(:record_totp_use, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:last_totp_at, DateTime.add(DateTime.utc_now(), -60))
    |> Ash.update!()
  end

  defp confirm!(user) do
    user
    |> Ash.Changeset.for_update(:confirm_by_admin, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.update!()
  end

  defp reload(user), do: Ash.get!(User, user.id, tenant: user.site_id, authorize?: false)
end
