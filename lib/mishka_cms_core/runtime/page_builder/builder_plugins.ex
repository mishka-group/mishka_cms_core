# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.BuilderPlugins do
  @moduledoc """
  The visual editor's processes and `mishka_installer` plugins, kept apart from the core's own.

  The editor talks to the core only through events, behaviour callbacks and config: its cache
  coherence reacts to `runtime:after_module_compile` (`CardPreviewInvalidator`), its admin pages
  come in on `sidebar:menus`, and the seams the core asks (`runtime:document:editor_url`,
  `runtime:provision:snippets`, `activity:sources`, `settings:register`, the drafts'
  `after_destroy` announcements) are answered by plugins of its own. `MishkaCmsCore.Application`
  supervises `children/0` and then `plugins/0` after the core's plugins, and the test run waits on
  `plugins/0` beside `MishkaCmsCore.Application.plugins/0`.

  `plugins/0` names every editor plugin and answers the ones that exist: a module that is not
  loadable, or that is loadable but is not a supervised plugin yet (it has no `child_spec/1`), is
  left out. So a plugin is supervised from the commit that writes it, and nothing else changes.
  """

  @plugins [
    MishkaCmsCore.Runtime.PageBuilder.CardPreviewInvalidator,
    MishkaCmsCoreWeb.Live.Admin.Builder.SidebarMenu,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.EditorUrl,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.ProvisionSnippet,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.Settings,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.PageDraftDestroy,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.PageDraftMasterDestroy,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.LayoutDraftDestroy,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.LayoutDraftMasterDestroy,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.ErrorPageDraftDestroy,
    MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.ErrorPageDraftMasterDestroy,
    MishkaCmsCore.Activity.Sources.EditorHistory
  ]

  @doc "The processes the editor needs running, in start order."
  @spec children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children, do: []

  @doc "The editor's `mishka_installer` plugins that exist and can be supervised, in start order."
  @spec plugins() :: [module()]
  def plugins, do: Enum.filter(@plugins, &plugin?/1)

  defp plugin?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1)
end
