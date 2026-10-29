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

  @children [
    # Live editing sessions, shared by the editor chrome and its canvas iframe.
    MishkaCmsCore.Runtime.States.EditorSessionState,
    # The undo history's documents, beside the session rather than in it — ETS flattens what it
    # stores, so fifty snapshots that share their nodes in memory would be copied fifty times over
    # on every read of the session. Started after it: its sweep reads that table's live tokens.
    MishkaCmsCore.Runtime.States.EditorHistoryState,
    # Rendered palette-card previews. Keyed on the template a card would drop, because a
    # component's first render is a module compile and every later one is two milliseconds.
    MishkaCmsCore.Runtime.States.CardPreviewState,
    # Co-editing avatars, on the editing session's own topic of `MishkaCmsCore.PubSub`, which the
    # core's application starts before these.
    MishkaCmsCore.Runtime.PageBuilder.Presence
  ]

  @doc """
  The processes the editor needs running, in start order. None of them reads the repo when it
  starts: three are ETS tables and one is `Phoenix.Presence`.
  """
  @spec children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children, do: @children

  @doc "The editor's `mishka_installer` plugins that exist and can be supervised, in start order."
  @spec plugins() :: [module()]
  def plugins, do: Enum.filter(@plugins, &plugin?/1)

  defp plugin?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1)
end
