defmodule MishkaCmsCore.Accounts.User.Senders.SendNewUserConfirmationEmailTest do
  @moduledoc """
  Characterizes the confirmation sender's two non-sending branches with the user struct
  AshAuthentication hands to `send/3`: it stays silent for the first-run installer (a changeset
  tagged `mishka_install: true`), and it returns nil without sending when no sender domain resolves
  (a tenant user with no tenant in context). Only Swoosh is test-mode, so `refute_email_sent`
  observes the real side effect.
  """
  use MishkaCmsCore.DataCase, async: false

  import Swoosh.TestAssertions

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Accounts.User.Senders.SendNewUserConfirmationEmail

  defp install_changeset do
    User
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(%{mishka_install: true})
  end

  test "send/3 returns :ok and sends nothing when the changeset is tagged for install" do
    user = %User{email: "owner@example.com", site_id: nil}

    assert SendNewUserConfirmationEmail.send(user, "tok-install", changeset: install_changeset()) ==
             :ok

    refute_email_sent()
  end

  test "send/3 sends nothing when no sender domain resolves for the user" do
    user = %User{email: "newbie@example.com", site_id: Ecto.UUID.generate()}

    assert SendNewUserConfirmationEmail.send(user, "tok-newbie", []) == :ok

    refute_email_sent()
  end

  test "a sign-in email's link is http with the port on localhost and every *.localhost site" do
    alias MishkaCmsCore.Accounts.Helper

    assert "http://localhost:4000/auth/confirm/tok/" <> _ =
             Helper.auth_link("localhost", "confirm", "tok", nil)

    assert "http://site-a.localhost:4000/auth/confirm/tok/" <> _ =
             Helper.auth_link("site-a.localhost", "confirm", "tok", "t")

    assert "https://acme.com/auth/confirm/tok/" <> _ =
             Helper.auth_link("acme.com", "confirm", "tok", "t")

    assert "https://notlocalhost.com/auth/confirm/tok/" <> _ =
             Helper.auth_link("notlocalhost.com", "confirm", "tok", "t")
  end
end
