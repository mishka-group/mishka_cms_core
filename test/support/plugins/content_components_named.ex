defmodule MishkaCmsCore.Test.Plugins.ContentComponentsNamed do
  @moduledoc """
  Test plugin for `runtime:compile:content_components`: answers that the stored content of the site
  it is asked about names `probe-from-content` and `probe-from-content-<site name>`, beside what the
  payload already holds — proving the stylesheet's build hears the names an extension's content uses.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:compile:content_components"

  @impl true
  def call(%{site: site, components: names} = data, _meta),
    do:
      {:reply,
       %{data | components: names ++ ["probe-from-content", "probe-from-content-#{site}", 7]}}
end
