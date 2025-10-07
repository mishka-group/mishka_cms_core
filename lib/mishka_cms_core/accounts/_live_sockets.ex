defmodule MishkaCmsCore.Accounts.LiveSockets do
  @moduledoc """
  The name a signed-in visitor's live sockets answer to, and the broadcast that cuts them.

  `MishkaCmsCoreWeb.AuthController` writes this name into the session under `live_socket_id` when a
  sign-in succeeds, which is where `Phoenix.LiveView.Socket.id/1` reads it: every socket that
  browser opens afterwards — an admin page, a database page — is subscribed to that topic by
  Phoenix, and a `"disconnect"` broadcast on it shuts all of them down.

  Cutting a socket is not signing anybody out. The browser reconnects immediately and mounts again,
  and everything the old socket had already decided is decided again from scratch: the session's
  token is verified, the user is read, and a page that names permissions asks
  `MishkaCmsCore.Accounts.Checks.AccessPermissions` about the user it just read. A visitor whose
  authorization did not really shrink sees nothing; one whose did is refused at that mount.

  ONE NAME PER USER, NOT PER TOKEN. Everything that fires this belongs to the account rather than to
  one of its sessions — a permission granted or taken away, the account deleted, its password
  changed. A per-token name would mean collecting every session of that user before any of them
  could be cut, and every trigger would need that list; `"users_sessions:<id>"` is the one name all
  of them already know. The two triggers that ARE about a single session, signing out and the
  `:logout` action, cut the user's other sockets too, and the ones still entitled to be there come
  straight back.

  See `MishkaCmsCore.Accounts.Notifiers.DisconnectLiveSockets` for what fires it.
  """
  # The host's endpoint, named by configuration rather than hardcoded — this library does not know
  # which application it is installed into. Applied rather than called so it stays a runtime
  # dispatch: the host's endpoint is not compile-visible from here.
  @host_endpoint Application.compile_env!(:mishka_cms_core, :endpoint)

  @doc """
  The `live_socket_id` of a user, given the user or its id.
  """
  @spec live_socket_id(Ash.Resource.record() | map() | String.t()) :: String.t()
  def live_socket_id(%{id: id}), do: live_socket_id(id)
  def live_socket_id(user_id) when is_binary(user_id), do: "users_sessions:#{user_id}"

  @doc """
  Cuts every live socket held by every session of this user, and drops what
  `MishkaCmsCore.Runtime.States.ViewerState` cached for them.
  """
  @spec disconnect(Ash.Resource.record() | map() | String.t()) :: :ok
  def disconnect(%{id: id}), do: disconnect(id)

  def disconnect(user_id) when is_binary(user_id) do
    MishkaCmsCore.Runtime.States.ViewerState.forget(user_id)
    apply(@host_endpoint, :broadcast, [live_socket_id(user_id), "disconnect", %{}])
    :ok
  end

  @doc """
  The user id a `live_socket_id` names, or `nil` — how a request that has not loaded its user, a file
  or a live navigation, learns who is asking from the session alone.
  """
  @spec user_id(String.t() | nil) :: String.t() | nil
  def user_id("users_sessions:" <> user_id), do: user_id
  def user_id(_other), do: nil
end
