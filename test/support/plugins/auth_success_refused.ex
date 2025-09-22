defmodule MishkaCmsCore.Test.Plugins.AuthSuccessRefused do
  @moduledoc """
  Test plugin for `AuthController.Success.Refused`: rewords the message a refused sign-in is shown,
  proving a plugin can change what the visitor is told.
  """
  use MishkaInstaller.Event.Hook, event: "AuthController.Success.Refused"

  @impl true
  def call(data, _meta), do: {:reply, %{data | message: "A plugin says: come back later"}}
end
