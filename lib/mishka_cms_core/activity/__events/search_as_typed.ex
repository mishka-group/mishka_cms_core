# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Events.SearchAsTyped do
  @moduledoc """
  Keeps the activity log's search as the admin typed it, tags and all.

  gervaz takes HTML tags out of every value a table event carries and every text filter its URL
  carries, so `<b>bold</b>` would quietly become a search for `bold`. The log's search never reaches
  HTML: `MishkaCmsCore.Activity.Query` binds it as a parameter of an escaped `ILIKE`, and the search
  box and the URL write it escaped. So the log keeps the text as typed, on both ways in:

    * as the table's event sanitizer (`events do sanitization … end` on
      `MishkaCmsCore.Activity.ActivityEntry`), for what the admin types;
    * through `keep_search/2` in the page's `handle_params/3`, for the URL a reload or a shared
      link brings back.

  Only what no database reads is taken out: the bytes that are no UTF-8 and the null byte, which
  nobody can type.
  """
  use MishkaGervaz.Table.Web.Events.SanitizationHandler

  @search_param "activity_filter_search"

  @impl true
  def sanitize(value) when is_binary(value), do: readable(value)
  def sanitize(value), do: value

  @doc """
  `url_state` (`MishkaGervaz.Table.Web.UrlSync.decode/3`'s answer) with its search as the URL
  `params` carry it, tags kept. A search gervaz did not take from the URL, one past the length the
  table allows, stays out.
  """
  @spec keep_search(map() | nil, map()) :: map() | nil
  def keep_search(%{filters: %{search: _decoded}} = url_state, %{@search_param => typed})
      when is_binary(typed),
      do: put_in(url_state, [:filters, :search], readable(typed))

  def keep_search(url_state, _params), do: url_state

  defp readable(text), do: text |> String.replace_invalid("") |> String.replace("\0", "")
end
