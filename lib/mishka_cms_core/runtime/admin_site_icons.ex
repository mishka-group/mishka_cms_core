# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.AdminSiteIcons do
  @moduledoc """
  A plain mishka_installer plugin: the admin's pages name the icons of the site they are served on,
  as the site's public pages do. The root layout fires `RootHtml.MetaTags` inside `<head>` with
  `%{html: html, assigns: assigns}`, and this plugin appends the site's icon links
  (`MishkaCmsCore.Runtime.Seo.icon_links/1`: its `site.favicon` and its home-screen icon) to `html`.
  Registered in MishkaCmsCore.Application.

  ## Which pages

  The ones the admin serves: `admin_css` is set on every admin page, and `current_site` is the site
  the request's host resolved to, so a master in master mode sees the icons of the host they are on.
  A public page is left alone, because its head already names the icons
  (`MishkaCmsCore.Runtime.Seo`), and so is a page with no site, such as the installer. A site with
  no favicon and no home-screen icon adds nothing.

  Each link's address is the one the public head names, which `Seo.favicon/1` has checked to be a
  path on the site or an `http(s)` address, and every attribute is escaped.
  """
  use MishkaInstaller.Event.Hook, event: "RootHtml.MetaTags", initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.Seo

  @impl true
  def call(%{html: html, assigns: %{admin_css: true, current_site: %{id: site_id}}} = state)
      when is_binary(html) and is_binary(site_id) do
    {:reply, %{state | html: html <> links(site_id)}}
  end

  def call(state), do: {:reply, state}

  defp links(site_id), do: site_id |> Seo.icon_links() |> Enum.map_join(&link/1)

  defp link(%{tag: "link", attrs: attrs}) do
    "<link" <>
      (attrs |> Phoenix.HTML.attributes_escape() |> Phoenix.HTML.safe_to_string()) <> ">\n"
  end
end
