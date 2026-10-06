defmodule MishkaCmsCore.Test.Plugins.AuthSuccessRequested do
  @moduledoc """
  Test plugin for `AuthController.Success.Requested`: rewords the message a password reset asked for
  over its route is shown, and answers a magic link asked for over its route with a redirect of its
  own, proving a plugin can change what the visitor is told or answer instead.
  """
  use MishkaInstaller.Event.Hook, event: "AuthController.Success.Requested"

  @impl true
  def call(%{activity: {:magic_link, :request}, conn: conn} = data, _meta) do
    conn = conn |> Phoenix.Controller.redirect(to: "/help") |> Plug.Conn.halt()
    {:reply, %{data | conn: conn}}
  end

  def call(data, _meta), do: {:reply, %{data | message: "A plugin says: check your inbox"}}
end
