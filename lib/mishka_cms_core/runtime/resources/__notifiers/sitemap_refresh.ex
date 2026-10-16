# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh do
  @moduledoc """
  A reusable Ash notifier that rebuilds a site's sitemap after a write to a row it is built from.

  Notifiers run **after the transaction commits**, for every action of a resource that lists this —
  master twins, bulk actions and actions added later included. Each hands the record's site to
  `MishkaCmsCore.Runtime.Compilers.SitemapCompiler.schedule/1`, which enqueues that site's
  `"sitemap"` job; a burst of writes is one build.

  The site is the RECORD's `site_id`, not the changeset's tenant: a master twin runs with none. A
  `nil` one is a global row, so every open site is rebuilt. On `MishkaCmsCore.Runtime.Setting` only
  the keys a sitemap reads count.

  An extension whose `seo:sitemap:urls` plugin lists rows of a resource adds it beside that
  resource's other notifiers:

      use Ash.Resource,
        ...,
        notifiers: [
          Ash.Notifier.PubSub,
          MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook,
          MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh
        ]

  Pages and layouts do not list it: `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker` enqueues
  the job after their own. Nor does a site: `ScheduleSiteRuntime` and `BootHandler.compile_site/2`
  do.
  """
  @behaviour Ash.Notifier

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler

  # What a sitemap reads: `seo.sitemap.paths` in `SitemapCompiler`, and the languages a page answers
  # in and how its address names them in `MishkaCmsCore.Runtime.Languages`.
  @settings [
    "seo.sitemap.paths",
    "site.languages",
    "site.language_urls",
    "site.allowed_languages",
    "site.required_languages"
  ]

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: MishkaCmsCore.Runtime.Setting,
        data: %{key: key, site_id: site_id}
      })
      when key in @settings do
    _ = SitemapCompiler.schedule(site_id)
    :ok
  end

  def notify(%Ash.Notifier.Notification{resource: MishkaCmsCore.Runtime.Setting}), do: :ok

  def notify(%Ash.Notifier.Notification{data: %{site_id: site_id}}) do
    _ = SitemapCompiler.schedule(site_id)
    :ok
  end

  def notify(_notification), do: :ok

  # Never require original data: requesting it forces a pre-action load, which makes the action
  # non-atomic (and flips an unauthorized destroy from 403 to 404). The record in `data` carries the
  # site.
  @impl true
  def requires_original_data?(_resource, _action), do: false
end
