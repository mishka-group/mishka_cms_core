# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SignInDiscord do
  @moduledoc false
  use MishkaCmsCore.Accounts.SignInProvider,
    id: "discord",
    strategy: :discord,
    label: "Discord",
    priority: 40

  alias MishkaCmsCore.Test.SignInProviders

  @impl true
  def icon, do: %{color: "text-[#5865f2]", path: "M0 0h24v24H0z"}

  @impl true
  def settings, do: SignInProviders.settings("discord")

  @impl true
  def ready?(site_id), do: SignInProviders.ready?("discord", site_id)

  @impl true
  def secret(name, site_id), do: SignInProviders.secret("discord", name, site_id)

  # Discord's user object, read as claims, as the package reads it.
  @impl true
  def user_info(%{} = info) do
    info
    |> Map.put("sub", to_string(info["id"]))
    |> Map.put("email_verified", info["verified"] == true)
  end
end
