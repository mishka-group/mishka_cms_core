defmodule MishkaCmsCore.Runtime.SiteAvailability do
  @moduledoc """
  Whether a site is up, and who may reach it when it is not.

  A site is unavailable in two ways:

  | state | set on | who may reach it |
  |-------|--------|------------------|
  | `:inactive` | Admin → Runtime → Sites | a master admin of the surface asked about |
  | `:offline` | Settings → "Take this site offline" (the site's own or the global switch) | its own admins and master admins of the surface asked about |

  A site the site cache does not know — archived, deleted, or not loaded — is `:inactive`, so a gate
  asking about it closes rather than opens.

  Every answer is read from ETS: `MishkaCmsCore.Runtime.States.SiteState` for `active`,
  `MishkaCmsCore.Settings.offline?/1` for the switch, and the permissions the user was loaded with. No
  query, no process call, so it can sit on every request.

  An admin is an admin of a surface: the screens (`:dashboard`, the default) or the admin JSON:API
  and GraphQL (`:api`), or `:any` for either one. See `MishkaCmsCore.Accounts.Helper.master_admin?/2`
  and `MishkaCmsCore.Accounts.Helper.site_admin?/3` for who is who.

  ## Open LiveViews

  `on_mount/4` closes an open LiveView the moment its site closes to its user: on a live navigation,
  on every event, and when `changed/1` announces that the site's state changed. Add it to every
  LiveView:

      on_mount MishkaCmsCore.Runtime.SiteAvailability

  A view on a sign-in address (`MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.sign_in_path?/2`, read
  from the address of every navigation) stays open while its site is offline, so the site's admins
  can sign in; every view closes on an inactive site. A refused view is redirected to the address it
  was on, a full page load that the pipeline answers.

  A view that shows a record of another site — a preview, opened on any address — follows that site
  too, with `follow/3` from its `mount/3`: it is refused there, and closed later, by the rule
  `allowed?/2` answers for that site.

  A view whose viewer the site's closed sign-in signs out (`MishkaCmsCore.Accounts.AuthGate.signs_out?/2`)
  reloads the address it was on the same way, and the pipeline signs them out there. The gate's
  settings call `changed/1` as the offline switch does.

  ## Events

  - `runtime:state:site:availability_changed` — `%{key: site_id}`, `nil` for every site, each time
    `changed/1` is called.
  - `web:live:site_unavailable` — the socket an open LiveView is about to be sent away with, with
    `%{site_id: site_id, path: path}` as its meta. A plugin may redirect it elsewhere.
  """

  alias MishkaCmsCore.Accounts.{AuthGate, Helper, LiveSockets}
  alias MishkaCmsCore.PluginEvent
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Runtime.States.{SiteState, ViewerState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Hook
  alias Phoenix.LiveView

  @pubsub MishkaCmsCore.PubSub

  @type state :: :open | :offline | :inactive

  @doc """
  The site's state by its id.

      SiteAvailability.state(site.id)
      #=> :offline
  """
  @spec state(String.t() | nil) :: state()
  def state(site_id) when is_binary(site_id) do
    case SiteState.get(site_id) do
      {:ok, %{active: true}} -> if Settings.offline?(site_id), do: :offline, else: :open
      _inactive_or_unknown -> :inactive
    end
  end

  def state(_no_site), do: :inactive

  @doc """
  Whether `user` may reach the site `site_id` through `surface` — `:dashboard` (the default) for its
  pages, files, previews and screens, `:api` for its admin APIs, `:any` for either.

  `nil` for `user` is a visitor who is not signed in.

      SiteAvailability.allowed?(site.id, user)
      SiteAvailability.allowed?(site.id, user, :api)
  """
  @spec allowed?(String.t() | nil, map() | nil, Helper.admin_surface()) :: boolean()
  def allowed?(site_id, user, surface \\ :dashboard),
    do: allowed_in?(state(site_id), site_id, user, surface)

  @doc """
  The ids of every site that is up: active, and not offline by its own or the global switch.
  """
  @spec open_site_ids() :: [String.t()]
  def open_site_ids do
    for %{id: id} <- SiteState.get_active_sites(), not Settings.offline?(id), do: id
  end

  @doc """
  The id a socket bound to `site_id` answers to from `c:Phoenix.Socket.id/1`, as the GraphQL
  socket's does. `changed/1` disconnects every socket under it once the site is no longer open, and
  each one that reconnects is asked again.

  Needs the endpoint's PubSub server to be `MishkaCmsCore.PubSub`.
  """
  @spec socket_id(String.t()) :: String.t()
  def socket_id(site_id) when is_binary(site_id), do: "site_sockets:" <> site_id

  @doc """
  `allowed?/3` for a state already read with `state/1`.
  """
  @spec allowed_in?(state(), String.t() | nil, map() | nil, Helper.admin_surface()) :: boolean()
  def allowed_in?(state, site_id, user, surface \\ :dashboard)
  def allowed_in?(:open, _site_id, _user, _surface), do: true

  def allowed_in?(:offline, site_id, user, surface),
    do: Helper.master_admin?(user, surface) or Helper.site_admin?(user, site_id, surface)

  def allowed_in?(:inactive, _site_id, user, surface), do: Helper.master_admin?(user, surface)

  @doc """
  Tells this node's open LiveViews that `site_id`'s state may have changed, and disconnects this
  node's sockets bound to it (`socket_id/1`) when it is no longer open; `nil` for every site.

  `SiteState` and `SettingsState` call it after writing, so a view that checks again reads the new
  state. Local to the node, because each node's caches call it for their own write.
  """
  @spec changed(String.t() | nil) :: :ok
  def changed(site_id) do
    Phoenix.PubSub.local_broadcast(@pubsub, topic(site_id), {:site_availability_changed, site_id})
    disconnect_sockets(site_id)
    Hook.call("runtime:state:site:availability_changed", %{key: site_id}, return: false)
    :ok
  end

  @doc """
  Makes an open LiveView follow `site_id` as well as its host's site, from its `mount/3`.

  `{:error, site_id, state}` — the site that is closed to the viewer, the host's or `site_id` — when
  either is closed now; otherwise the view is closed as soon as one is. `nil` — a global record —
  follows the host's site only. Needs `on_mount/4`.
  """
  @spec follow(LiveView.Socket.t(), String.t() | nil, map()) ::
          {:ok, LiveView.Socket.t()} | {:error, String.t() | nil, :offline | :inactive}
  def follow(socket, site_id, session) do
    viewer = session |> viewer_id() |> ViewerState.get()
    host = socket.private[:site_availability_site]

    cond do
      host && closed?(host, viewer, false) -> {:error, host, state(host)}
      is_nil(site_id) -> {:ok, socket}
      true -> follow_site(socket, site_id, host, viewer)
    end
  end

  defp follow_site(socket, site_id, host, viewer) do
    state = state(site_id)

    if allowed_in?(state, site_id, viewer) do
      if LiveView.connected?(socket) and site_id != host,
        do: Phoenix.PubSub.subscribe(@pubsub, topic(site_id))

      {:ok, LiveView.put_private(socket, :site_availability_follow, site_id)}
    else
      {:error, site_id, state}
    end
  end

  @doc """
  Closes an open LiveView the moment its site closes to its user. See the moduledoc.
  """
  def on_mount(:default, _params, session, socket) do
    case {socket.router, session["current_site"]} do
      {nil, _no_route} -> {:cont, socket}
      {_router, nil} -> {:cont, socket}
      {_router, site} -> {:cont, watch(socket, site, session)}
    end
  end

  defp watch(socket, site, session) do
    viewer_id = viewer_id(session)
    closed_site = fn socket -> closed_site(socket, site.id, viewer_id) end

    socket
    |> LiveView.put_private(:site_availability_site, site.id)
    |> LiveView.attach_hook(:site_availability_params, :handle_params, fn _params, uri, socket ->
      %URI{path: path} = uri = URI.parse(uri)

      socket
      |> LiveView.put_private(:site_availability_path, address(uri))
      |> LiveView.put_private(
        :site_availability_sign_in,
        SiteLookupPlug.sign_in_path?(String.split(path || "/", "/", trim: true), site)
      )
      |> check(closed_site)
    end)
    |> LiveView.attach_hook(:site_availability_event, :handle_event, fn _event, _params, socket ->
      check(socket, closed_site)
    end)
    |> listen(site.id, closed_site)
  end

  defp listen(socket, site_id, closed_site) do
    if LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, topic(site_id))
      Phoenix.PubSub.subscribe(@pubsub, topic(nil))

      LiveView.attach_hook(socket, :site_availability_info, :handle_info, fn
        {:site_availability_changed, _changed}, socket ->
          {:halt, socket |> check(closed_site) |> elem(1)}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp check(socket, closed_site) do
    case closed_site.(socket) do
      nil -> {:cont, socket}
      :signed_out -> {:halt, reload(socket)}
      site_id -> {:halt, leave(socket, site_id)}
    end
  end

  # The site that has closed to the viewer — the host's, or the one the view follows — `:signed_out`
  # for a viewer the host's closed sign-in signs out, or `nil`.
  defp closed_site(socket, site_id, viewer_id) do
    viewer = ViewerState.get(viewer_id)
    followed = socket.private[:site_availability_follow]
    sign_in = socket.private[:site_availability_sign_in] == true

    cond do
      closed?(site_id, viewer, sign_in) -> site_id
      followed && not allowed?(followed, viewer) -> followed
      AuthGate.signs_out?(site_id, viewer) -> :signed_out
      true -> nil
    end
  end

  defp viewer_id(session), do: LiveSockets.user_id(session["live_socket_id"])

  # A sign-in address stays open on an offline site, so its admins can sign in.
  defp closed?(site_id, viewer, sign_in) do
    case state(site_id) do
      :open -> false
      :offline -> not sign_in and not allowed_in?(:offline, site_id, viewer)
      :inactive -> true
    end
  end

  defp leave(socket, site_id) do
    path = socket.private[:site_availability_path] || "/"

    socket =
      PluginEvent.call("web:live:site_unavailable", socket, meta: %{site_id: site_id, path: path})

    if socket.redirected, do: socket, else: LiveView.redirect(socket, to: path)
  end

  defp reload(socket),
    do: LiveView.redirect(socket, to: socket.private[:site_availability_path] || "/")

  defp address(%URI{path: path, query: nil}), do: path || "/"
  defp address(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp topic(nil), do: "site_availability:all"
  defp topic(site_id), do: "site_availability:" <> site_id

  # The broadcast `Endpoint.broadcast/3` would send, on which a socket's transport closes. Sent on
  # PubSub itself, since a cache can write before the endpoint has started. Only for a site that is
  # no longer open: `SiteState.save/1` calls `changed/1` on every edit of a site, and one still up
  # keeps its sockets.
  defp disconnect_sockets(nil),
    do: Enum.each(SiteState.get_active_sites(), &disconnect_sockets(&1.id))

  defp disconnect_sockets(site_id) do
    if state(site_id) != :open do
      id = socket_id(site_id)
      message = %Phoenix.Socket.Broadcast{topic: id, event: "disconnect", payload: %{}}
      Phoenix.PubSub.local_broadcast(@pubsub, id, message)
    end

    :ok
  end
end
