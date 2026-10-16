# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.RawBodyTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.Plugs.RawBody` behind `Plug.Parsers`: a webhook's request keeps the bytes
  it was sent beside its params, and no other request keeps anything.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias MishkaCmsCore.Runtime.Plugs.RawBody

  @body ~s({"type":"contact.updated", "data": {"email":"ada@example.com"}})

  defp parsed(path, body, opts \\ []) do
    parsers =
      Plug.Parsers.init(
        Keyword.merge(
          [
            parsers: [:urlencoded, :json],
            pass: ["*/*"],
            json_decoder: Jason,
            body_reader: {RawBody, :read_body, []}
          ],
          opts
        )
      )

    :post
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(parsers)
  end

  test "a webhook keeps its body exactly as it was sent, and is parsed as well" do
    conn = parsed("/webhooks/newsletter/resend", @body)

    assert RawBody.raw_body(conn) == @body
    assert conn.body_params["type"] == "contact.updated"
  end

  test "any other request keeps nothing" do
    conn = parsed("/api/json/v1/user/thing", @body)

    assert RawBody.raw_body(conn) == nil
    assert conn.body_params["type"] == "contact.updated"
  end

  test "a body read in several pieces is kept whole" do
    body = ~s({"padding":") <> String.duplicate("x", 5_000) <> ~s("})
    conn = parsed("/webhooks/x", body, length: 100_000, read_length: 1_000)

    assert RawBody.raw_body(conn) == body
  end

  test "the parsers' own length limit holds" do
    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      parsed("/webhooks/x", ~s({"a":") <> String.duplicate("x", 2_000) <> ~s("}), length: 1_000)
    end
  end

  test "the prefix is /webhooks/" do
    assert RawBody.prefix() == "/webhooks/"
  end
end
