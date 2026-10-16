# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.ExtensionLiveView do
  @moduledoc """
  Shared LiveView module for extensions.

  Use this instead of `MishkaCmsWeb, :live_view` in extension LiveViews.
  Automatically embeds templates from the same directory.

  ## Features

  - Phoenix.LiveView
  - Phoenix.HTML
  - Phoenix.Component
  - Phoenix.LiveView.JS
  - Gettext (translations)
  - CoreComponents (UI components: button, input, table, modal, etc.)
  - Runtime path helpers (path/2, url/2)
  - embed_templates (auto-loads .html.heex files from same directory)

  ## Usage

      # index.ex
      defmodule MishkaBlogWeb.Live.Admin.Dashboard.Blogger.Index do
        use MishkaCmsCore.ExtensionLiveView

        @impl true
        def mount(_params, _session, socket) do
          {:ok, assign(socket, count: 10)}
        end
      end

      # index.html.heex (same directory)
      <div class="container mx-auto px-4 py-8">
        <.header>
          Bloggers {@count}
          <:subtitle>Manage all bloggers</:subtitle>
          <:actions>
            <.button navigate={path(@socket, "/admin/dashboard/blog/bloggers/new")}>
              New Blogger
            </.button>
          </:actions>
        </.header>

        <.table id="bloggers" rows={@bloggers}>
          <:col :let={blogger} label="Name">{blogger.name}</:col>
          <:col :let={blogger} label="Email">{blogger.email}</:col>
        </.table>
      </div>

  ## Available Components

  From `MishkaCmsCore.CoreComponents`:

  - `<.button>` - Buttons with navigation support
  - `<.input>` - Form inputs with labels and error handling
  - `<.table>` - Tables with streams support
  - `<.flash>` - Flash messages
  - `<.header>` - Page headers with actions
  - `<.icon>` - Heroicons
  - `<.list>` - Data lists

  ## Path Helpers

  Since extensions compile before the main CMS, they cannot use `~p` sigils.
  Instead, use the runtime path helpers:

      # In templates - use path/2 with @socket:
      <.link navigate={path(@socket, "/admin/dashboard")}>Dashboard</.link>

      # With dynamic segments:
      <.link navigate={path(@socket, "/posts/\#{@post.id}")}>View</.link>

      # For full URLs:
      url(@socket, "/posts/\#{@post.id}")

  ## Translations

  Use `gettext/1` for translations:

      <h1>{gettext("Welcome")}</h1>
      <p>{ngettext("1 item", "%{count} items", @count)}</p>
  """

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView, layout: {MishkaCmsCore.Layouts, :app}

      # Records the current path so the admin sidebar can highlight the active item
      # The canvas draws its chrome, its icons and the site's theme as `<style>` elements of its own,
      # and `style-src-elem` refuses one without a nonce — see `MishkaCmsCore.Runtime.CspNonce`.
      on_mount(MishkaCmsCore.Runtime.CspNonce)

      # The admin chrome, and the language its admin reads the dashboard in.
      on_mount(MishkaCmsCore.Layouts.Nav)

      # Refuses the page to anyone its declaration in `MishkaCmsCore.Sidebar` does not allow. Every
      # admin page is guarded by this one line: the hook reads `socket.view`, so there is nothing to
      # add per page and nothing to forget — an undeclared page is refused, not waved through.
      on_mount(MishkaCmsCore.Sidebar.PageGuard)

      # Closes the page the moment its site goes inactive, or offline for someone who may not see it.
      on_mount(MishkaCmsCore.Runtime.SiteAvailability)

      # Sends an admin of a site that requires two-step sign-in, and has none, to set it up first.
      on_mount(MishkaCmsCore.Accounts.TwoStepGuard)

      # Makes the topbar bell live: per-user unseen count + real-time updates (overrides Nav's count)
      on_mount(MishkaCmsCore.Notify.LiveHooks)

      # HTML helpers
      import Phoenix.HTML

      # Translations
      use Gettext, backend: MishkaCmsCore.Gettext

      # Core UI components
      import MishkaCmsCore.CoreComponents

      # Runtime path helpers (path/2, url/2)
      import MishkaCmsCore.Helpers

      # JS commands alias
      alias Phoenix.LiveView.JS

      # Embed templates from the same directory as the module
      embed_templates "."
    end
  end
end
