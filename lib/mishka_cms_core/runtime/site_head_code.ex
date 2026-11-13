# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteHeadCode do
  @moduledoc """
  A plain mishka_installer plugin on `runtime:page:head` (`MishkaCmsCore.Runtime.HeadCodes.event/0`):
  it appends the site's own published `MishkaCmsCore.Runtime.HeadCode` entries that apply to the
  page, each item keyed by its entry's id. Registered in MishkaCmsCore.Application.

  The site's entries reach a page's head the way an extension's tags do, so the admin's "From
  extensions" list is every item but these. They are read from
  `MishkaCmsCore.Runtime.States.SiteState`, already parsed, with no query.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:page:head", initial: %{priority: 50}

  alias MishkaCmsCore.Runtime.HeadCodes
  alias MishkaCmsCore.Runtime.States.SiteState

  @impl true
  def call(%{site_id: site_id, items: items} = entry)
      when is_binary(site_id) and is_list(items) do
    page_path = entry |> Map.get(:page) |> page_path()

    own =
      for code <- SiteState.head_codes(site_id),
          HeadCodes.applies?(code.scope, code.paths, Map.get(entry, :path), page_path),
          item <- code.items,
          do: item

    {:reply, %{entry | items: items ++ own}}
  end

  def call(entry), do: {:reply, entry}

  defp page_path(%{path: path}) when is_binary(path), do: path
  defp page_path(_page), do: nil
end
