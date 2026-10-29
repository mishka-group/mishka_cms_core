# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Builder.Routes do
  @moduledoc """
  The visual editor's routes, mounted like any extension's: the host lists the editor's web module
  in `config :mishka_cms_core, :extensions`, and `MishkaCmsCore.ExtensionRouter.extension_routes/1`
  finds this module beside it.

  The editor declares who may open each page in `MishkaCmsCoreWeb.Live.Admin.Builder.SidebarMenu`;
  without that declaration `MishkaCmsCore.Sidebar.PageGuard` refuses the page.
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @doc """
  The visual page builder, in its own `live_session`.

  `:section` is page | layout | error-page | component; the canvas is a second LiveView the chrome
  embeds in an iframe, addressed by its session token.

  These are `:admin_standalone` rather than `:admin` because the builder is the one admin page whose
  `<head>` is not the admin's usual head — it carries the in-browser Tailwind JIT and the shim that
  nonces what that JIT and CodeMirror create. The root layout builds `<head>` on a dead render only,
  so a live navigation into the builder would hand it the previous page's head. The separate session
  is what makes arriving here a fresh document; navigation BETWEEN these routes stays live and fast.
  """
  @impl true
  def routes(:admin_standalone) do
    [
      {:live, "/runtime/builder/:section/:id", MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive,
       :edit},
      {:live, "/runtime/builder/:section", MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive, :new},
      {:live, "/runtime/builder-canvas/:token", MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive,
       :canvas},
      # One example of one component, rendered alone for the examples modal's preview pane — the same
      # canvas in preview mode, addressed by the editing session's token.
      {:live, "/runtime/builder-canvas/:token/example/:name/:index",
       MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive, :example},
      # The wizard's preview — the component composed from the reader's own choices, which live in
      # the editing session so this canvas can read them.
      {:live, "/runtime/builder-canvas/:token/wizard/:wizard",
       MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive, :wizard}
    ]
  end

  def routes(_type), do: []
end
