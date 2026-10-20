# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SignInSlack do
  @moduledoc false
  use MishkaCmsCore.Accounts.SignInProvider,
    id: "slack",
    strategy: :slack,
    label: "Slack",
    priority: 30

  alias MishkaCmsCore.Test.SignInProviders

  @impl true
  def icon, do: %{color: "text-[#4a154b]", path: "M0 0h24v24H0z"}

  @impl true
  def settings, do: SignInProviders.settings("slack")

  @impl true
  def ready?(site_id), do: SignInProviders.ready?("slack", site_id)

  @impl true
  def secret(name, site_id), do: SignInProviders.secret("slack", name, site_id)
end
