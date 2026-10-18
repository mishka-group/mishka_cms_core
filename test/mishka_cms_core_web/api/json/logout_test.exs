# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.LogoutTest do
  @moduledoc """
  What `POST /auth/user/logout` says, and when it says it.

  "Logged out successfully" is only true when the token no longer works. The action used to ignore
  the result of revoking it (inside a `rescue`), so a revocation that failed was still answered with
  success and the token went on working. Now the answer follows the revocation:

    * a live token is revoked and the answer is success;
    * a live token whose revocation fails is an error, and the token is untouched by the answer;
    * a string that is not a live token — garbage, a forged token, one already revoked — has nothing
      to revoke and is answered with success, without revoking it: revoking writes a row for the
      `jti` the token names, and a forged token must not name another account's.

  The failure is made real by taking the tokens table away inside the test's own transaction (DDL
  is transactional in PostgreSQL), so the revocation hits a real database error.
  """
  use MishkaCmsCore.ConnCase

  require Ash.Query

  import MishkaCmsCore.Test.Factory
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  alias MishkaCmsCore.Accounts.{LiveSockets, Token}
  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :integration
  @moduletag :capture_log

  @password "Password123!"
  @path "/api/json/v1/auth/user"

  setup do
    SiteState.clear()
    on_exit(fn -> SiteState.clear() end)

    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsCore.TestRouter)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: true
    })

    permission = create_permission!(name: "admin:api:*")

    master =
      MishkaCmsCore.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "logout-master@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password)
      })
      |> Ash.create!(authorize?: false, tenant: nil)
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
        authorize?: false
      )
      |> Ash.update!()

    %{master: master}
  end

  defp logout(token) do
    make_api_request("#{@path}/logout", %{"token" => token}, headers: [{"x-no-tenant", "true"}])
  end

  defp me(token) do
    make_api_request("#{@path}/me", nil,
      method: "GET",
      headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
    )
  end

  defp revocations do
    Token
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(purpose == "revocation")
    |> Ash.read!(authorize?: false)
  end

  # The revocation reads and writes `tokens`; with the table gone it hits a database error.
  defp take_tokens_away! do
    MishkaCmsCore.Repo.query!("ALTER TABLE tokens RENAME TO tokens_taken_away")
  end

  test "a live token is revoked and the answer is success", %{master: master} do
    token = sign_in_master(master, @password)
    assert me(token).status == 200

    response = logout(token)

    assert response.status in 200..299

    assert %{"success" => true, "message" => "Logged out successfully"} =
             Jason.decode!(response.resp_body)

    assert me(token).status == 403, "the token still works after the answer said it did not"
    assert length(revocations()) == 1
  end

  test "a revocation that fails is an error, not 'Logged out successfully'", %{master: master} do
    token = sign_in_master(master, @password)
    take_tokens_away!()

    response = logout(token)

    assert response.status >= 400, "a failed revocation was answered #{response.status}"
    refute response.resp_body =~ "Logged out successfully"
    refute response.resp_body =~ token, "the token was echoed in the error"
  end

  test "a string that is not a live token is answered with success and revokes nothing" do
    for token <- ["invalid.jwt.token", "not-a-token", "a.b.c", String.duplicate("x", 300)] do
      response = logout(token)

      assert response.status in 200..299, token
      assert %{"success" => true} = Jason.decode!(response.resp_body)
    end

    assert revocations() == []
  end

  test "a token signed with another key revokes nothing", %{master: master} do
    live = sign_in_master(master, @password)
    [header, payload, _signature] = String.split(live, ".")

    # The live token's own header and claims — its `jti` included — under a signature that is not
    # the application's.
    forged =
      Enum.join([header, payload, Base.url_encode64("not the signature", padding: false)], ".")

    response = logout(forged)

    assert response.status in 200..299
    assert revocations() == []
    assert me(live).status == 200, "a forged token revoked the live one"
  end

  test "logging out twice with the same token answers success both times", %{master: master} do
    token = sign_in_master(master, @password)

    assert logout(token).status in 200..299
    assert logout(token).status in 200..299
    assert length(revocations()) == 1
  end

  # A MASTER'S TOKEN CARRIES NO TENANT, which verification read as a tenant named `:null`, so the
  # account's sockets were never cut when a master logged out.
  test "cuts the account's live sockets once its token is revoked", %{master: master} do
    topic = LiveSockets.live_socket_id(master)
    MishkaCmsCore.TestEndpoint.subscribe(topic)
    token = sign_in_master(master, @password)

    assert logout(token).status in 200..299
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "cuts nobody's sockets a second time, with the token it already revoked", %{
    master: master
  } do
    topic = LiveSockets.live_socket_id(master)
    MishkaCmsCore.TestEndpoint.subscribe(topic)
    token = sign_in_master(master, @password)

    assert logout(token).status in 200..299
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}

    assert logout(token).status in 200..299
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic}, 200
  end

  test "leaves the account's live sockets alone when the revocation failed", %{master: master} do
    topic = LiveSockets.live_socket_id(master)
    MishkaCmsCore.TestEndpoint.subscribe(topic)
    token = sign_in_master(master, @password)
    take_tokens_away!()

    assert logout(token).status >= 400
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic}, 200
  end

  test "cuts nobody's sockets for a token that is not a live one", %{master: master} do
    topic = LiveSockets.live_socket_id(master)
    MishkaCmsCore.TestEndpoint.subscribe(topic)

    assert logout("invalid.jwt.token").status in 200..299
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic}, 200
  end
end
