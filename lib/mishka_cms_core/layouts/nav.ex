# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.Nav do
  @moduledoc """
  `on_mount` hook that records, for the admin chrome in `MishkaCmsCore.Layouts`: the current request
  path as `@current_path` (so the sidebar highlights the active item — updates on live navigation
  too) and `@current_user` with its `:permissions` loaded. Attached to every admin page via
  `MishkaCmsCore.ExtensionLiveView`.

  It also puts the page in the language its admin reads the dashboard in —
  `MishkaCmsCore.Runtime.Languages.admin/1`, chosen in the topbar's user menu — as Gettext's locale
  and as `@admin_language`, with the choices the menu offers as `@admin_languages`. The menu's Sign
  out is the site's sign-out page in the language its admin reads the site in, `@sign_out_path`
  (`MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.auth_address/3`). And it names the page's
  `@footer_credit`: the name and address of the extension that owns the page, or `nil` on the core's
  own (`MishkaCmsCore.Sidebar.credit/1`); `@footer_shown` is `false` for an extension that draws no such line (`MishkaCmsCore.Sidebar.footer?/1`).

  The sidebar follows its settings live: the hook subscribes to `MishkaCmsCore.Sidebar.changed/1` for
  the menu its viewer is shown and raises `@sidebar_version`, which `MishkaCmsCore.Layouts.sidebar/1`
  redraws on. Changes that arrive together are drawn once. Each redraw emits
  `[:mishka_cms, :sidebar, :redrawn]` from the page's own process as it raises `@sidebar_version`,
  with the new `version` as its measurement and the page's `view` as its metadata, so whatever asks
  the page after that event is answered with the redrawn sidebar.

  It keeps `@sidebar_counts`, the numbers entries show (`MishkaCmsCore.Sidebar.Counts`) for the
  viewer's site (`Counts.for_viewer/1`, a master with no site reads the sum): read from memory when
  the page opens, then read again on each count the page hears.

  It keeps `@topbar_items`, what extensions add to the top bar on the `"topbar:items"` event
  (`MishkaCmsCore.Layouts.TopbarItems`): collected when the page opens and again only when its path
  changes, so a patch that keeps the path, and every render, calls no plugin. `@topbar_site` is the
  site the request resolved to, handed to those items. `@topbar_section` is the page's heading on a
  phone (`MishkaCmsCore.Sidebar.section/1`), read with them.

  `@topbar_placeholder` is the search box's placeholder an extension gave on the `"topbar:search"`
  event (`MishkaCmsCore.Layouts.TopbarSearch.placeholder/1`), read with them.

  It keeps `@topbar_bands`, what extensions draw full width under the top bar on the `"topbar:bands"`
  event (`MishkaCmsCore.Layouts.TopbarBands`), collected with the items.

  It keeps `@topbar_needs`, the bell's "What needs you" items on the `"topbar:needs"` event
  (`MishkaCmsCore.Layouts.TopbarNeeds`), collected with the top bar's items and again when an
  extension calls `TopbarNeeds.changed/1` for the viewer's site. The changes that arrive together
  are collected once, and each collection emits `[:mishka_cms, :topbar_needs, :refreshed]` from the
  page's own process. The bell's unread notifications are `MishkaCmsCore.Notify.LiveHooks`'s.

  Loading the permissions here rather than where they are used matters: `MishkaCmsCore.Sidebar` asks
  whether the viewer may see each nav entry, once per entry, through `AccessPermissions.match?/3`,
  which loads an unloaded actor — so without this the chrome would issue a query on every render.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]
  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias MishkaCmsCore.Layouts.{TopbarBands, TopbarItems, TopbarNeeds, TopbarSearch}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Sidebar.Counts

  @sidebar_refresh_ms 50
  @needs_refresh_ms 50
  @redrawn [:mishka_cms, :sidebar, :redrawn]
  @needs_refreshed [:mishka_cms, :topbar_needs, :refreshed]

  def on_mount(:default, _params, session, socket) do
    language = Languages.admin(session)
    Gettext.put_locale(language)

    # Every admin page renders through the compiled admin stylesheet and the Manrope/Space Grotesk/
    # Newsreader web fonts. Set here — the hook attached to every admin LiveView — so a FRESH load of
    # any admin page ships them, not only one navigated to from a page that happens to set them.
    #
    # Two assigns rather than one: the editor's canvas wants the fonts and NOT the stylesheet, because
    # it renders a site's document with its own chrome drawn in inline styles.

    socket =
      socket
      # `code_editor` publishes WHERE CodeMirror lives and downloads none of it — a meta tag of sixty
      # bytes that `assets/js/pb_code_editor.js` reads the first time a code box appears. Set for
      # every admin page rather than page by page, because the alternative is that adding a code
      # field to a form silently gives you a plain textarea and no clue why. `content_editor` does
      # the same for the rich-text editor's bundle, which `assets/js/pb_content_editor.js` reads.
      |> assign(
        admin_css: true,
        admin_fonts: true,
        code_editor: true,
        content_editor: true,
        # THE ADMIN LOADS THE ADMIN'S JAVASCRIPT. It used to load the SITE's — the bundle the runtime
        # compiler builds for whichever site the request resolved to — and got the dashboard's own
        # hooks only because that bundle was built from `app.js` and therefore contained everything.
        # Now that a site's bundle carries only a site's hooks, the two have to be told apart: the
        # admin takes `app.js`, and the site bundle it has no use for is suppressed.
        standalone_assets: true,
        suppress_site_js: true
      )
      |> assign(:current_user, with_permissions(socket.assigns[:current_user]))
      |> assign(
        admin_language: language,
        admin_languages: Languages.admin_choices(site_id(session)),
        sign_out_path:
          SiteLookupPlug.auth_address(session[Languages.session()], site_id(session), "/sign-out"),
        footer_credit: Sidebar.credit(socket.view),
        footer_shown: Sidebar.footer?(socket.view)
      )

    site = session["current_site"]

    {:cont,
     socket
     |> attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
       {:cont, at_path(socket, URI.parse(uri).path, site)}
     end)
     |> follow_sidebar()
     |> follow_needs()}
  end

  defp at_path(%{assigns: %{current_path: path, topbar_items: _items}} = socket, path, _site),
    do: socket

  defp at_path(socket, path, site) do
    context = %{
      current_user: socket.assigns[:current_user],
      current_site: site,
      current_path: path,
      view: socket.view
    }

    assign(socket,
      current_path: path,
      topbar_items: TopbarItems.collect(context),
      topbar_bands: TopbarBands.collect(context),
      topbar_placeholder: TopbarSearch.placeholder(context),
      topbar_needs: TopbarNeeds.collect(context),
      topbar_site: site,
      topbar_section: Sidebar.section(path),
      sidebar_counts: viewer_counts(socket)
    )
  end

  defp follow_needs(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, TopbarNeeds.topic())
      attach_hook(socket, :topbar_needs, :handle_info, &needs_message/2)
    else
      socket
    end
  end

  defp needs_message({:topbar_needs_changed, site_id}, socket) do
    cond do
      not TopbarNeeds.concerns?(socket.assigns[:current_user], site_id) ->
        {:halt, socket}

      socket.private[:needs_refresh_pending] ->
        {:halt, socket}

      true ->
        Process.send_after(self(), :topbar_needs_refresh, @needs_refresh_ms)
        {:halt, put_private(socket, :needs_refresh_pending, true)}
    end
  end

  defp needs_message(:topbar_needs_refresh, socket) do
    needs =
      TopbarNeeds.collect(%{
        current_user: socket.assigns[:current_user],
        current_site: socket.assigns[:topbar_site],
        current_path: socket.assigns[:current_path],
        view: socket.view
      })

    :telemetry.execute(@needs_refreshed, %{total: TopbarNeeds.total(needs)}, %{view: socket.view})

    new_socket =
      socket
      |> put_private(:needs_refresh_pending, false)
      |> assign(:topbar_needs, needs)

    {:halt, new_socket}
  end

  defp needs_message(_message, socket), do: {:cont, socket}

  # The numbers of the viewer's own site. Read when the path changes, after every `on_mount` of the
  # page has run, so a page that scopes its user to a site (an extension's) is read as that site.
  defp viewer_counts(socket), do: Counts.for_viewer(site_of(socket.assigns[:current_user]))

  defp site_of(%{site_id: site_id}) when is_binary(site_id), do: site_id
  defp site_of(_user), do: nil

  defp follow_sidebar(socket) do
    socket = assign(socket, sidebar_version: 0, sidebar_counts: viewer_counts(socket))

    if connected?(socket) do
      Sidebar.subscribe(socket.assigns[:current_user])
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, Counts.topic())
      attach_hook(socket, :sidebar_changed, :handle_info, &sidebar_message/2)
    else
      socket
    end
  end

  defp sidebar_message({:sidebar_changed, _site_id}, socket) do
    if socket.private[:sidebar_refresh_pending] do
      {:halt, socket}
    else
      Process.send_after(self(), :sidebar_refresh, @sidebar_refresh_ms)
      {:halt, put_private(socket, :sidebar_refresh_pending, true)}
    end
  end

  defp sidebar_message(:sidebar_refresh, socket) do
    version = socket.assigns.sidebar_version + 1
    :telemetry.execute(@redrawn, %{version: version}, %{view: socket.view})

    {:halt,
     socket
     |> put_private(:sidebar_refresh_pending, false)
     |> assign(:sidebar_version, version)}
  end

  defp sidebar_message(message, socket)
       when elem(message, 0) == :sidebar_count and tuple_size(message) in [4, 5] do
    {:halt, assign(socket, :sidebar_counts, viewer_counts(socket))}
  end

  defp sidebar_message(_message, socket), do: {:cont, socket}

  defp site_id(%{"current_site" => %{id: id}}), do: id
  defp site_id(_session), do: nil

  defp with_permissions(nil), do: nil

  defp with_permissions(user) do
    if Ash.Resource.loaded?(user, :permissions),
      do: user,
      else: Ash.load!(user, [permissions: [:name]], actor: user)
  end
end
