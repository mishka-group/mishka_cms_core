# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SignInGitHub do
  @moduledoc false
  use MishkaCmsCore.Accounts.SignInProvider,
    id: "github",
    strategy: :github,
    label: "GitHub",
    priority: 20

  alias MishkaCmsCore.Test.SignInProviders

  @impl true
  def icon, do: %{color: "text-[#1b1a18]", path: "M0 0h24v24H0z"}

  @impl true
  def settings, do: SignInProviders.settings("github")

  @impl true
  def ready?(site_id), do: SignInProviders.ready?("github", site_id)

  @impl true
  def secret(name, site_id), do: SignInProviders.secret("github", name, site_id)
end
