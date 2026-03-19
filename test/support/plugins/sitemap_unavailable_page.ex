defmodule MishkaCmsCore.Test.Plugins.SitemapUnavailablePage do
  @moduledoc """
  Test plugin for `web:request:sitemap_unavailable`: answers with a response of its own, proving a
  plugin can replace the controller's 404.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:sitemap_unavailable"

  @impl true
  def call(conn, _meta),
    do: {:reply, conn |> Plug.Conn.send_resp(410, "A plugin's own answer") |> Plug.Conn.halt()}
end
