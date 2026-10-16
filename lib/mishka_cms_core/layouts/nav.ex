# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.Nav do
  @moduledoc """
  `on_mount` hook that records, for the admin chrome in `MishkaCmsCore.Layouts`: the current request
  path as `@current_path` (so the sidebar highlights the active item — updates on live navigation
  too), `@notification_count` (failed/retrying runtime jobs, shown as the topbar bell badge), and
  `@current_user` with its `:permissions` loaded. Attached to every admin page via
  `MishkaCmsCore.ExtensionLiveView`.

  It also puts the page in the language its admin reads the dashboard in —
  `MishkaCmsCore.Runtime.Languages.admin/1`, chosen in the topbar's user menu — as Gettext's locale
  and as `@admin_language`, with the choices the menu offers as `@admin_languages`. The menu's Sign
  out is the site's sign-out page in the language its admin reads the site in, `@sign_out_path`
  (`MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.auth_address/3`). And it names the page's
  `@footer_credit`: the name and address of the extension that owns the page, or `nil` on the core's
  own (`MishkaCmsCore.Sidebar.credit/1`).

  The sidebar follows its settings live: the hook subscribes to `MishkaCmsCore.Sidebar.changed/1` for
  the menu its viewer is shown and raises `@sidebar_version`, which `MishkaCmsCore.Layouts.sidebar/1`
  redraws on. Changes that arrive together are drawn once.

  Loading the permissions here rather than where they are used matters: `MishkaCmsCore.Sidebar` asks
  whether the viewer may see each nav entry, once per entry, through `AccessPermissions.match?/3`,
  which loads an unloaded actor — so without this the chrome would issue a query on every render.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Ecto.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Sidebar

  @sidebar_refresh_ms 50

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
        notification_count: notification_count(),
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
        footer_credit: Sidebar.credit(socket.view)
      )

    {:cont,
     socket
     |> attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
       {:cont, assign(socket, :current_path, URI.parse(uri).path)}
     end)
     |> follow_sidebar()}
  end

  defp follow_sidebar(socket) do
    socket = assign(socket, :sidebar_version, 0)

    if connected?(socket) do
      Sidebar.subscribe(socket.assigns[:current_user])
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
    {:halt,
     socket
     |> put_private(:sidebar_refresh_pending, false)
     |> assign(:sidebar_version, socket.assigns.sidebar_version + 1)}
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

  defp notification_count do
    query = from(j in Oban.Job, where: j.state in ["retryable", "discarded"], select: count())
    Oban.Repo.one(Oban.config(), query) || 0
  end
end
