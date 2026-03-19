defmodule MishkaCmsCore.Test.Plugins.SitemapUnavailable do
  @moduledoc """
  Test plugin for `web:request:sitemap_unavailable`: reports the reason it was told
  (`:unknown_file`, `:no_site` or `:not_built`) to the `:__plugin_hook_probe__` process and leaves
  the conn to the controller's own answer — a 404, or the 503 for a sitemap not built yet.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:sitemap_unavailable"

  @impl true
  def call(conn, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:sitemap_unavailable, meta[:reason], meta[:site] && meta[:site].id})

    {:reply, conn}
  end
end
