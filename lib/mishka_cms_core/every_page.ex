# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.EveryPage do
  @moduledoc """
  Every row a read finds, however many pages its action splits them into.

  A read action that paginates answers one page. Asked for more rows than its `max_page_size` (250
  unless the action says otherwise), it cuts the page down to that size without a word:
  `page: [limit: 1000]` on such an action answers 250 rows and `more?: true`. An action whose
  pagination is required, read with no page at all, answers its `default_limit`. A caller that takes
  `results` and stops there has dropped the rest, and nothing on screen says so: the editor's palette
  lost every component past the 250th that way, `chelekom-table` among them.

  `read/2` asks for the whole answer instead. An action that does not paginate is read as it is; one
  whose paging is optional is read with `page: false`; one that requires a page is read a page of its
  own `max_page_size` at a time, following `more?` with `Ash.page/2` until the last page, keyset and
  offset alike.

  `Ash.stream!/2` is the same idea for a caller that wants a stream and a raise. This is for the ones
  that answer `{:ok, rows} | {:error, reason}`, or want the whole list (`read!/2`).
  """

  @doc """
  Every row `query` reads, as `Ash.read/2` with `opts` would answer the first page of them.

  `query` is an `Ash.Query` (its action set by `Ash.Query.for_read/4`, or named by `opts[:action]`,
  or the primary read) or a resource. A page `opts` or the query asks for is replaced: the size of
  each page is the action's to decide.
  """
  @spec read(Ash.Query.t() | Ash.Resource.t(), keyword()) ::
          {:ok, [Ash.Resource.Record.t()]} | {:error, term()}
  def read(query, opts \\ []) do
    query = Ash.Query.new(query)

    case pagination(query, opts) do
      %{required?: true, max_page_size: size} ->
        query |> Ash.read(Keyword.put(opts, :page, limit: size)) |> rest([])

      %{} ->
        query |> Ash.read(Keyword.put(opts, :page, false)) |> rows()

      _none ->
        query |> Ash.read(Keyword.delete(opts, :page)) |> rows()
    end
  end

  @doc "`read/2`, raising the read's error instead of answering it."
  @spec read!(Ash.Query.t() | Ash.Resource.t(), keyword()) :: [Ash.Resource.Record.t()]
  def read!(query, opts \\ []) do
    case read(query, opts) do
      {:ok, rows} -> rows
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  # A PAGE THAT CARRIED SOMETHING is what earns the next one: a keyset page with no results answers
  # itself, so a page claiming `more?` over nothing would be asked for its successor for ever.
  defp rest({:ok, %{results: [_ | _] = rows, more?: true} = page}, read),
    do: page |> Ash.page(:next) |> rest([rows | read])

  defp rest({:ok, %{results: rows}}, read),
    do: {:ok, [rows | read] |> Enum.reverse() |> Enum.concat()}

  defp rest({:error, _reason} = error, _read), do: error

  defp rows({:ok, %{results: rows}}), do: {:ok, rows}
  defp rows(result), do: result

  defp pagination(%Ash.Query{action: %{pagination: pagination}}, _opts), do: pagination

  defp pagination(%Ash.Query{resource: resource}, opts) do
    case opts[:action] do
      %{pagination: pagination} -> pagination
      name when is_atom(name) and not is_nil(name) -> action_pagination(resource, name)
      nil -> Ash.Resource.Info.primary_action!(resource, :read).pagination
    end
  end

  defp action_pagination(resource, name) do
    case Ash.Resource.Info.action(resource, name) do
      %{pagination: pagination} -> pagination
      nil -> nil
    end
  end
end
