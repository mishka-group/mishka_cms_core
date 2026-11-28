# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.SiteTitleFromName do
  @moduledoc """
  Gives a new site its own `site.title` setting: the name the master typed for it.

  `site.title` resolves the site's own value, then the global one, then the default. The global
  value is the first site's brand, which the installer writes, so a second site with no title of
  its own would name itself after the first one in its page titles, its link previews, its emails
  and its two-factor entries. Every reader of `site.title` gets the site's own name instead, with no
  fallback of its own to keep in step.

  The name is read as typed, before `MishkaCmsCore.Runtime.Resources.Changes.InternalName`
  slugifies it, so a site created as "Acme Docs" is titled "Acme Docs", not `acme-docs`. Put it
  before that change:

      create :create do
        change MishkaCmsCore.Runtime.Resources.Changes.SiteTitleFromName
        change MishkaCmsCore.Runtime.Resources.Changes.InternalName
      end

  The master site is left alone: the global title is its title. The setting is written after the
  transaction, which is what `MishkaCmsCore.Settings.put/3` refreshes the settings cache from, and
  a write that fails is logged without failing the create; the site then shows the global title
  until an admin sets its own.
  """
  use Ash.Resource.Change

  require Logger

  alias Ash.Changeset
  alias MishkaCmsCore.Settings

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.get_attribute(changeset, :name) do
      name when is_binary(name) and name != "" ->
        Changeset.after_transaction(changeset, &write_title(&1, &2, String.trim(name)))

      _no_name ->
        changeset
    end
  end

  defp write_title(_changeset, {:ok, %{master: master, id: site_id}} = result, title)
       when master != true do
    case Settings.put("site.title", title, site_id: site_id, category: "general") do
      {:ok, _title} ->
        result

      {:error, reason} ->
        Logger.warning("[SiteTitleFromName] no site.title for #{site_id}: #{inspect(reason)}")
        result
    end
  end

  defp write_title(_changeset, result, _title), do: result
end
