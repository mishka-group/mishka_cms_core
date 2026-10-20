# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SignInGoogle do
  @moduledoc false
  use MishkaCmsCore.Accounts.SignInProvider,
    id: "google",
    label: "Google",
    priority: 10

  alias MishkaCmsCore.Test.SignInProviders

  @impl true
  def oauth, do: %{assent: Assent.Strategy.Google}

  @impl true
  def icon, do: %{color: "text-[#4285f4]", path: "M0 0h24v24H0z"}

  @impl true
  def settings, do: SignInProviders.settings("google")

  @impl true
  def ready?(site_id), do: SignInProviders.ready?("google", site_id)

  @impl true
  def secret(name, site_id), do: SignInProviders.secret("google", name, site_id)
end
