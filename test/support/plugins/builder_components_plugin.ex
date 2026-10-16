# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderComponentsPlugin do
  @moduledoc """
  Test plugin: contributes a live-data component to the builder palette through
  `builder:components`.

  This is the §22 Path-B case — a component that cannot be a stored HEEx template because it streams
  real data — and it exists to prove the seam is real rather than documented. It also asserts the
  accumulator convention: the payload it receives already carries the core's database palette, and
  it appends rather than replacing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:components"

  alias MishkaCmsCore.Builder.PaletteEntry

  @entry PaletteEntry.new!(%{
           name: "latest-posts",
           type: "blog",
           description: "The most recent published posts, streamed live.",
           render: {MishkaCmsCore.Test.Plugins.BuilderComponentsPlugin, :latest_posts},
           priority: 10,
           attrs: [%{"name" => "limit", "type" => "integer", "opts" => %{"default" => 5}}]
         })

  @impl true
  def call(%{entries: entries} = payload) do
    if pid = Process.whereis(:__builder_palette_probe__),
      do: send(pid, {:builder_components, length(entries)})

    {:reply, %{payload | entries: entries ++ [@entry]}}
  end

  def call(payload), do: {:reply, payload}

  @doc "The descriptor this plugin contributes, so tests can assert against it directly."
  def entry, do: @entry

  @doc false
  def latest_posts(assigns), do: assigns
end
