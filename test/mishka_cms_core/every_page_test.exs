# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.EveryPageTest do
  @moduledoc """
  A read that pages answers one page, and one asked for more than its `max_page_size` is cut down to
  it. `EveryPage` answers every row, whichever way the action pages.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import MishkaCmsCore.Test.Factory
  @moduletag :integration

  alias MishkaCmsCore.EveryPage
  alias MishkaCmsCore.Runtime.{Component, Site}

  require Ash.Query

  # More than the 250 a page of these actions holds at most.
  @count 260

  setup do
    prefix = "every-#{System.unique_integer([:positive])}"

    names =
      for n <- 1..@count,
          do: "#{prefix}-#{n |> Integer.to_string() |> String.pad_leading(3, "0")}"

    create_many!(Component, Enum.map(names, &%{name: &1, template: "<div>row</div>"}))

    {:ok, prefix: prefix, names: names}
  end

  defp ours(action, prefix, opts \\ [authorize?: false]) do
    Component
    |> Ash.Query.for_read(action, %{}, opts)
    |> Ash.Query.filter(contains(name, ^prefix))
  end

  defp names(rows), do: rows |> Enum.map(& &1.name) |> Enum.sort()

  test "a page asked for past the action's limit is cut to it, which is what this is for", ctx do
    assert {:ok, %{results: rows, more?: true}} =
             :for_tenant_with_globals |> ours(ctx.prefix) |> Ash.read(page: [limit: 1000])

    assert length(rows) == 250
  end

  test "every row of an action that requires a page and pages by offset", ctx do
    assert {:ok, rows} = :for_tenant_with_globals |> ours(ctx.prefix) |> EveryPage.read()
    assert names(rows) == ctx.names
  end

  test "every row of an action that requires a page and pages by keyset", ctx do
    assert {:ok, rows} = :read_any |> ours(ctx.prefix) |> EveryPage.read()
    assert names(rows) == ctx.names
  end

  test "every row of an action whose page is optional, in one read", ctx do
    assert {:ok, rows} = :read |> ours(ctx.prefix) |> EveryPage.read()
    assert names(rows) == ctx.names
  end

  test "an action named in the options, or the primary read, on a resource", ctx do
    query = Ash.Query.filter(Component, contains(name, ^ctx.prefix))

    assert names(EveryPage.read!(query, action: :read_any, authorize?: false)) == ctx.names
    assert names(EveryPage.read!(query, authorize?: false)) == ctx.names
  end

  test "a page the query or the options ask for does not cut the answer", ctx do
    query = :for_tenant_with_globals |> ours(ctx.prefix) |> Ash.Query.page(limit: 10)

    assert {:ok, rows} = EveryPage.read(query, page: [limit: 20])
    assert length(rows) == @count
  end

  test "an action that does not page is read as it is" do
    site = create_site!()

    assert {:ok, [%{id: id}]} =
             Site
             |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
             |> Ash.Query.filter(id == ^site.id)
             |> EveryPage.read()

    assert id == site.id
  end

  test "a refused read is answered, not raised; read! raises it", ctx do
    query = ours(:master_read, ctx.prefix, actor: nil)

    assert {:error, _refused} = EveryPage.read(query)
    assert_raise Ash.Error.Forbidden, fn -> EveryPage.read!(query) end
  end
end
