# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.HelpersTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.TestEndpoint
  alias MishkaCmsCore.TestRouter

  describe "url/2" do
    test "a conn answers the endpoint's address followed by the path under the conn's prefix" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:script_name, ["cms"])
        |> Plug.Conn.put_private(:phoenix_endpoint, TestEndpoint)
        |> Plug.Conn.put_private(:phoenix_router, TestRouter)

      assert Helpers.path(conn, "/admin") == "/cms/admin"
      assert Helpers.url(conn, "/admin") == TestEndpoint.url() <> "/cms/admin"
    end

    test "a socket answers the endpoint's address followed by the endpoint's path" do
      socket = %Phoenix.LiveView.Socket{endpoint: TestEndpoint, router: TestRouter}

      assert Helpers.url(socket, "/posts/1") ==
               TestEndpoint.url() <> TestEndpoint.path("/posts/1")
    end
  end
end
