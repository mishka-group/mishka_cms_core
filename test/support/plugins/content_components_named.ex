# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ContentComponentsNamed do
  @moduledoc """
  Test plugin for `runtime:compile:content_components`: answers that the stored content of the site
  it is asked about names `probe-from-content` and `probe-from-content-<site name>`, the icons
  `hero-inbox-arrow-down` and `fake-star`, and the classes `bg-[#282828]`,
  `data-[orientation=vertical]:h-32` and a 174-byte `mask-linear-[…]`, beside what the payload already holds — proving the
  stylesheet's build hears the names, the icons and the classes an extension's content uses. Its
  classes also hold what no `@source inline(…)` may carry: a quote, a backslash, a brace.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:compile:content_components"

  @impl true
  def call(%{site: site, components: names, icons: icons, classes: classes} = data, _meta),
    do:
      {:reply,
       %{
         data
         | components: names ++ ["probe-from-content", "probe-from-content-#{site}", 7],
           icons: icons ++ ["hero-inbox-arrow-down", "fake-star", "hero-inbox-arrow-down", 7],
           classes:
             classes ++
               [
                 "bg-[#282828]",
                 "data-[orientation=vertical]:h-32",
                 "bg-[#282828]",
                 "mask-linear-[to_bottom,transparent_0,black_min(40px,var(--scroll-area-overflow-y-start)),black_calc(100%_-_min(40px,var(--scroll-area-overflow-y-end,40px))),transparent_100%]",
                 ~s|x");body{color:red}|,
                 "p-{1,2}",
                 "a\\b",
                 7
               ]
       }}
end
