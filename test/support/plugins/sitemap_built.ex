defmodule MishkaCmsCore.Test.Plugins.SitemapBuilt do
  @moduledoc """
  Test plugin for `runtime:compile:after_sitemap`: reports what each stored sitemap was built from
  to the `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:compile:after_sitemap"

  @impl true
  def call(data) do
    if pid = Process.whereis(:__plugin_hook_probe__), do: send(pid, {:sitemap_built, data})
    {:reply, data}
  end
end
