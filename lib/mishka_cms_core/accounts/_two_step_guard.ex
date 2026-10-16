# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.TwoStepGuard do
  @moduledoc """
  The dashboard of a site that requires two-step sign-in (`MishkaCmsCore.Accounts.SecondFactor.policy/1`),
  for an admin who has not set an authenticator up (`SecondFactor.owed?/1`): every page but the
  settings page's Preferences tab sends them there, with a flash saying why. An `on_mount` of every
  admin page — see `MishkaCmsCore.ExtensionLiveView`.

  The settings page's other tabs are live patches, which mount nothing, so they are asked again on
  `handle_params`, of the account as stored: setting the authenticator up on that same page opens
  the rest of the dashboard without a reload.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.Helpers, only: [path: 2]

  alias MishkaCmsCore.Accounts.{SecondFactor, User}
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.SettingsLive

  @preferences "/admin/dashboard/settings?tab=preferences"

  def on_mount(:default, params, _session, socket) do
    cond do
      not SecondFactor.owed?(socket.assigns[:current_user]) ->
        {:cont, socket}

      preferences?(socket.view, params) ->
        {:cont, Phoenix.LiveView.attach_hook(socket, :two_step_owed, :handle_params, &stay/3)}

      true ->
        {:halt, send_there(socket)}
    end
  end

  defp stay(params, _uri, socket) do
    if preferences?(socket.view, params) or not SecondFactor.owed?(stored(socket)),
      do: {:cont, socket},
      else: {:halt, send_there(socket)}
  end

  defp preferences?(SettingsLive, %{"tab" => "preferences"}), do: true
  defp preferences?(_view, _params), do: false

  defp stored(%{assigns: %{current_user: %{id: id, site_id: site_id}}}) do
    case Ash.get(User, id, tenant: site_id, authorize?: false) do
      {:ok, user} -> user
      {:error, _error} -> nil
    end
  end

  defp send_there(socket) do
    socket
    |> Phoenix.LiveView.put_flash(
      :error,
      gettext(
        "This site asks every admin to sign in with two steps. Set up your authenticator to use the dashboard."
      )
    )
    |> Phoenix.LiveView.redirect(to: path(socket, @preferences))
  end
end
