defmodule MishkaCmsCore.TestEndpoint do
  @moduledoc """
  The endpoint this extension's suite runs against, doing two jobs at once:

    * it carries the test's HTTP request to `MishkaCmsCore.TestRouter`, and
    * it is what every resource broadcasts through on write, because `config/config.exs` names it as
      `config :mishka_cms_core, endpoint: …` — the setting each `pub_sub do module … end` reads.

  Everything the CMS's real endpoint carries and this one does not — sessions, LiveView, static
  assets, the admin pipeline — is machinery a JSON:API request never touches.

  Test-only: Mix does not compile a path dependency's `test/support`, so the CMS never sees this
  module, and `mix.exs` keeps `test` out of the hex `files:` list.
  """

  use Phoenix.Endpoint, otp_app: :mishka_cms_core

  # The admin LiveViews mount over a session, so the browser pipeline needs one to fetch.
  @session_options [
    store: :cookie,
    key: "_mishka_cms_core_test_key",
    signing_salt: "cms-core-test",
    same_site: "Lax"
  ]

  # `:peer_data` and `:x_headers` as the CMS's: the `/auth` forms are rate limited by the address they
  # name.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, {:json, length: 10_000_000}],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Session, @session_options
  plug Plug.Head
  plug MishkaCmsCore.TestRouter
end
