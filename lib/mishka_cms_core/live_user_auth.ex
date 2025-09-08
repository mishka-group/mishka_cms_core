defmodule MishkaCmsCore.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component

  # Extensions compile before the host's router exists, so `~p` is unavailable here; `path/2` resolves
  # the same literal paths against the router the socket was mounted through.
  import MishkaCmsCore.Helpers, only: [path: 2]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  # Where `:live_user_lazy` keeps the session for `load_current_user/1`. Private rather than an
  # assign because the socket's private is not change-tracked and is never part of a diff sent to
  # the browser, while an assign would be re-sent on every render that touched it.
  #
  # IT IS NOT HIDDEN FROM THE PAGE. `Phoenix.LiveView.Renderer` hands every template the socket as
  # `@socket` with `private` untouched, so a runtime template can render this session's token. That
  # is acceptable only because such a template is arbitrary Elixir compiled into the LiveView — its
  # author can already read anything this process can — and it is the reason nothing here treats
  # `private` as a place a secret is safe from the page.
  @lazy_session :mishka_cms_lazy_session

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {MishkaCmsCore.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  # NO USER IS READ, AND NONE IS ASSIGNED — not even `current_user: nil`, because an absent assign is
  # what lets `load_current_user/1` fill one in later through `assign_new/3`.
  #
  # `AshAuthentication.Phoenix.LiveSession`'s own hook, which `ash_authentication_live_session`
  # installs, verifies the session's token and loads the user on EVERY mount. That is right for the
  # admin, where every route needs one, and wrong for `MishkaCmsWeb.RuntimeLive`: it answers every
  # database page from one `live "/*path"`, most of those pages never mention a visitor, and a
  # signed-in one paid a token-row read and a user read for each of them. Which page was asked for,
  # and whether it needs a user at all, is known only after `RuntimeLive` has resolved and compiled
  # it — so the session waits here, in the socket's private, and the loading happens there.
  def on_mount(:live_user_lazy, _params, session, socket) do
    socket =
      socket
      |> Phoenix.LiveView.put_private(@lazy_session, session)
      |> assign_current_tenant(session)

    {:cont, socket}
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, maybe_load_user_site(socket)}
    else
      new_socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, gettext("You must log in to access this page."))
        |> Phoenix.LiveView.redirect(to: path(socket, "/auth"))

      {:halt, new_socket}
    end
  end

  def on_mount({:require_permission, permissions}, _params, _session, socket) do
    current_user = socket.assigns[:current_user]

    if AccessPermissions.match?(current_user, %{}, permissions: permissions) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(
         :error,
         gettext("You don't have permission to access this page")
       )
       |> Phoenix.LiveView.redirect(to: path(socket, "/"))}
    end
  end

  @doc """
  The signed-in user, verified now — what `:live_user_lazy` left until something needed one.

  Exactly the checks the live session's own hook makes on mount, because underneath it is the same
  function: the session's token is verified, its row must still be in the token resource — so a
  token that was signed out, revoked or never issued by this application is refused — and only then
  is the subject read back into a user. A tenant user's site is loaded after it, as every hook here
  does.

  `assign_new/3`, for two reasons. The first HTTP response was already given a verified user by the
  `:load_from_session` plug, so it is reused rather than read again; and a visitor who patches from
  one page to another inside the same LiveView keeps the user the first of them loaded, rather than
  paying for it once per page.

  A socket that was not mounted through `:live_user_lazy` carries no session and answers nobody,
  which every caller has to treat as "not signed in" — refused wherever a page names permissions.
  """
  @spec load_current_user(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_current_user(socket) do
    session = socket.private[@lazy_session] || %{}

    socket
    |> AshAuthentication.Phoenix.LiveSession.assign_new_resources(session,
      context: session["context"] || %{}
    )
    |> maybe_load_user_site()
  end

  @doc """
  The signed-in user read again, now, over whatever this socket loaded earlier.

  `load_current_user/1` answers from the assign once it has one, which is right for a page being
  drawn: the user was verified when the socket mounted, and a change to that user cuts the socket
  (see `MishkaCmsCore.Accounts.LiveSockets`). It is not enough before ACTING on a page that names
  permissions — between the write that took a permission away and the broadcast that ends the
  socket there is a moment in which the assign still says the visitor may, and an event arriving in
  that moment must not be answered from it.

  So the same verification runs again, through the same library function, with `assign/3` in place
  of `assign_new/3`: the session's token is verified and its row looked for, and the user is read
  back with the permissions it has now. A token that was signed out, revoked or expired since the
  mount answers nobody, which every caller reads as "not signed in".
  """
  @spec reload_current_user(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reload_current_user(socket) do
    session = socket.private[@lazy_session] || %{}

    AshAuthentication.Plug.Helpers.assign_new_resources(
      socket,
      session,
      fn socket, key, read_user -> assign(socket, key, read_user.()) end,
      otp_app: AshAuthentication.Phoenix.Components.Helpers.otp_app_from_socket(socket),
      context: session["context"] || %{}
    )
    |> maybe_load_user_site()
  end

  # `:current_tenant` is the tenant `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` chose for the
  # request, always assigned so a runtime page reads `@current_tenant` whoever is asking: the site's
  # id, or `nil` for a master and for a visitor signing in to the master accounts. An
  # AshAuthentication.Phoenix component and a page's sign-in forms scope themselves by it.
  defp assign_current_tenant(socket, session),
    do: assign(socket, :current_tenant, session["tenant"])

  # Load site relation for tenant users (site_id is not nil)
  defp maybe_load_user_site(socket) do
    case socket.assigns.current_user do
      %{site_id: site_id, site: %Ash.NotLoaded{}} when is_binary(site_id) ->
        user = Ash.load!(socket.assigns.current_user, :site)
        assign(socket, :current_user, user)

      _ ->
        socket
    end
  end
end
