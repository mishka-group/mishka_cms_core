# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.RawBody do
  @moduledoc """
  The bytes a webhook was sent, kept for its signature check.

  A webhook is signed over its body exactly as it was sent — Svix (Resend), Stripe and GitHub all
  sign that way — and `Plug.Parsers` reads the body to decode it, so a route behind the endpoint
  sees only the decoded params. One decoded and encoded again is a different text and never matches.

  Give the endpoint's parsers this body reader:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library(),
        body_reader: {MishkaCmsCore.Runtime.Plugs.RawBody, :read_body, []}

  A request whose path starts with `/webhooks/` then keeps its body in `conn.private[:raw_body]`
  (`raw_body/1`) beside the params, and every other request is read as Plug reads it and keeps
  nothing. An extension mounts its webhooks under that prefix — `/webhooks/<extension>/<sender>` —
  through `MishkaCmsCore.ExtensionRouter`'s `:api` routes.

  The parsers' own `:length` limit applies, so a body is never kept past what they would read. A
  request whose content type no parser reads is not read at all, and keeps nothing: its route reads
  it with `Plug.Conn.read_body/2`.
  """

  @prefix "/webhooks/"

  @doc "The path prefix whose requests keep their body."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  `Plug.Conn.read_body/2`, keeping what it reads when the request is a webhook's. For
  `Plug.Parsers`' `:body_reader`.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{request_path: @prefix <> _rest} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, keep(conn, body)}
      {:more, body, conn} -> {:more, body, keep(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  @doc "The body a webhook request was sent, or `nil` when it was not kept."
  @spec raw_body(Plug.Conn.t()) :: binary() | nil
  def raw_body(%Plug.Conn{private: private}), do: Map.get(private, :raw_body)

  defp keep(conn, chunk),
    do: Plug.Conn.put_private(conn, :raw_body, (raw_body(conn) || "") <> chunk)
end
