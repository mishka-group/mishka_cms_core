# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.RuntimePageHostLive do
  @moduledoc """
  A stand-in for a host's runtime page LiveView, so a compiled page module can be driven through
  `Phoenix.LiveViewTest.live_isolated/3`: the session names the page module (`"page_module"`) and
  the site it renders for (`"site_id"`); mount names the site for the process, and `render/1` is the
  page module's own.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, %{"page_module" => module, "site_id" => site_id}, socket) do
    :ok = MishkaCmsCore.Runtime.Translations.put_site(site_id)
    {:ok, assign(socket, page_module: String.to_existing_atom(module))}
  end

  @impl true
  def render(assigns), do: assigns.page_module.render(assigns)
end
