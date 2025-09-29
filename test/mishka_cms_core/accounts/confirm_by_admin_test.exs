defmodule MishkaCmsCore.Accounts.ConfirmByAdminTest do
  @moduledoc """
  An admin confirming an account whose confirmation email never came (`:confirm_by_admin`): a holder
  of the user area, for an account of its own site, or a master for any; once.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.User

  setup do
    site = create_site!(active: true)
    %{site: site, writer: create_user!(site_id: site.id)}
  end

  test "an admin of the account's site confirms it, once", %{site: site, writer: writer} do
    admin = create_user_with_permissions!(["admin:dashboard:user"], site_id: site.id)

    assert is_nil(writer.confirmed_at)
    assert {:ok, %User{confirmed_at: %DateTime{}} = confirmed} = confirm(writer, admin)
    assert {:error, %Ash.Error.Invalid{}} = confirm(confirmed, admin)
  end

  test "a master with the user area confirms any site's account", %{writer: writer} do
    master = create_user_with_permissions!(["admin:dashboard:user"])

    assert {:ok, %User{confirmed_at: %DateTime{}}} = confirm(writer, master)
  end

  test "an admin of another site, or anyone without the user area, cannot", %{
    site: site,
    writer: writer
  } do
    stranger =
      create_user_with_permissions!(["admin:dashboard:user"],
        site_id: create_site!(active: true).id
      )

    nobody = create_user_with_permissions!(["admin:dashboard:blog:*"], site_id: site.id)

    for refused <- [stranger, nobody] do
      assert {:error, %Ash.Error.Forbidden{}} = confirm(writer, refused)
    end
  end

  defp confirm(user, actor) do
    user
    |> Ash.Changeset.for_update(:confirm_by_admin, %{}, actor: actor, tenant: user.site_id)
    |> Ash.update()
  end
end
