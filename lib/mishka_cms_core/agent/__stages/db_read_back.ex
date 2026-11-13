# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.DbReadBack do
  @moduledoc """
  The row in the database holds what the operation was meant to leave there.

      {:db_read_back, expect: [status: :published, published_at: :present]}
      {:db_read_back, gone: true}
      {:db_read_back, :installed, resource: MishkaCmsCore.Runtime.Setting,
        by: &MyExtension.Agent.Checks.installed_row/1, expect: [value: :present]}

  ## Options

    * `:expect` — field and what it must hold: a value (`:published`, `true`, `3`), `:present`
      (not nil), `:absent` (nil), `:claimed` (what the action's returned record says it is) or
      `:since_start` (a time no earlier than the operation's start, for a row an upsert may have
      left in place).
    * `:gone` — `true` when the row must no longer exist.
    * `:resource` — the resource to read, the operation's by default.
    * `:by` — the fields that find the row, a keyword list or a check that returns one from the
      context. The record's primary key by default.

  ## How it reads

  One query, straight to the table through the resource's Ecto repo: `SELECT` of the expected
  columns only, `WHERE` the key, and the site's column when the resource is multitenant by
  attribute and the receipt has a site. It goes through no Ash action, policy, preparation or
  archival filter, and it never reuses the struct the action returned, so a bug in the action
  cannot vouch for itself. The values are read back through the attribute's Ash type.

  `observed` keeps each field as the value when it is a scalar a receipt may hold (a status, a
  boolean), `:present`/`:absent` for anything else, and `:matches`/`:differs` for `:claimed`: a
  title or a body is compared, never stored.

  ## What verified means

  Right after the operation, the primary repo returned the row and every expected field held what
  was expected.

  ## What it does not prove

  Side effects, caches (the site and settings caches, compiled pages) and other nodes are not the
  table. With a read replica configured as the read repo, or inside an outer transaction not yet
  committed, the read may be stale or see what is later rolled back. A test's sandbox sees its own
  transaction. Only a resource on AshPostgres can be read (`:unsupported_data_layer` otherwise).
  """
  @behaviour MishkaCmsCore.Agent.Stages

  import Ecto.Query, only: [where: 3, select: 2, limit: 2]

  alias MishkaCmsCore.Agent.Redactor
  alias MishkaCmsCore.Agent.Stages

  @impl true
  def layer(_opts), do: :db

  @impl true
  def verify(ctx, opts) do
    resource = Keyword.get(opts, :resource) || ctx.resource
    expect = Keyword.get(opts, :expect, [])

    with :ok <- postgres(resource),
         {:ok, by} <- by(ctx, opts, resource),
         {:ok, rows} <- read(resource, by, Keyword.keys(expect), ctx) do
      compare(rows, expect, Keyword.get(opts, :gone, false), ctx, resource)
    end
  end

  defp postgres(resource) when is_atom(resource) and not is_nil(resource) do
    case Ash.DataLayer.data_layer(resource) do
      AshPostgres.DataLayer -> :ok
      _other -> {:unverified, :unsupported_data_layer}
    end
  end

  defp postgres(_none), do: {:unverified, :no_resource}

  defp by(ctx, opts, resource) do
    case Keyword.get(opts, :by) do
      nil -> primary_key(ctx, resource)
      by when is_list(by) -> {:ok, by}
      check -> listed(Stages.call(check, ctx))
    end
  end

  defp listed(by) when is_list(by) and by != [], do: {:ok, by}
  defp listed(_none), do: {:unverified, :no_key}

  defp primary_key(%{subject_id: id}, resource) when not is_nil(id) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] -> {:ok, [{key, id}]}
      _composite -> {:unverified, :no_key}
    end
  end

  defp primary_key(_ctx, _resource), do: {:unverified, :no_key}

  defp read(resource, by, fields, ctx) do
    by = scoped(by, resource, ctx)
    columns = Enum.map(fields, &column(resource, &1))

    query =
      resource
      |> AshPostgres.DataLayer.Info.table()
      |> Ecto.Queryable.to_query()
      |> Map.put(:prefix, AshPostgres.DataLayer.Info.schema(resource))

    query =
      by
      |> Enum.reduce(query, fn {field, value}, query ->
        matching(query, resource, field, value)
      end)
      |> select(^Enum.uniq([column(resource, primary(resource)) | columns]))
      |> limit(2)

    repo = AshPostgres.DataLayer.Info.repo(resource, :read)
    {:ok, Enum.map(repo.all(query), &loaded(&1, resource, fields))}
  end

  # The site's column too, so a read for one site can never find another site's row.
  defp scoped(by, resource, %{site_id: site_id}) when is_binary(site_id) do
    with :attribute <- Ash.Resource.Info.multitenancy_strategy(resource),
         attribute when is_atom(attribute) <- Ash.Resource.Info.multitenancy_attribute(resource),
         false <- Keyword.has_key?(by, attribute) do
      by ++ [{attribute, site_id}]
    else
      _not_scoped -> by
    end
  end

  defp scoped(by, _resource, _ctx), do: by

  defp matching(query, resource, field, nil) do
    column = column(resource, field)
    where(query, [row], is_nil(field(row, ^column)))
  end

  defp matching(query, resource, field, value) do
    column = column(resource, field)
    dumped = dump(resource, field, value)
    where(query, [row], field(row, ^column) == ^dumped)
  end

  defp loaded(row, resource, fields) do
    Map.new(fields, fn field ->
      attribute = Ash.Resource.Info.attribute(resource, field)
      raw = Map.get(row, column(resource, field))

      case Ash.Type.cast_stored(attribute.type, raw, attribute.constraints) do
        {:ok, value} -> {field, {:ok, value}}
        _error -> {field, :uncastable}
      end
    end)
  end

  defp compare([], _expect, true, _ctx, _resource), do: {:ok, %{present: false}}

  defp compare([_ | _], _expect, true, _ctx, _resource),
    do: {:mismatch, %{present: false}, %{present: true}}

  defp compare([], _expect, false, _ctx, _resource), do: {:error, :not_found}

  defp compare([row], expect, false, ctx, resource) do
    checked =
      Enum.map(expect, fn {field, wanted} ->
        attribute = Ash.Resource.Info.attribute(resource, field)
        {field, wanted, check(Map.fetch!(row, field), wanted, attribute, ctx)}
      end)

    observed = Map.new(checked, fn {field, _wanted, {_ok?, seen}} -> {field, seen} end)

    case Enum.all?(checked, fn {_field, _wanted, {ok?, _seen}} -> ok? end) do
      true ->
        {:ok, Map.put(observed, :present, true)}

      false ->
        {:mismatch, Map.new(checked, fn {field, wanted, _} -> {field, expected(wanted)} end),
         observed}
    end
  end

  defp compare([_, _ | _], _expect, false, _ctx, _resource), do: {:error, :not_unique}

  defp check(:uncastable, _wanted, _attribute, _ctx), do: {false, :uncastable}
  defp check({:ok, value}, :present, _attribute, _ctx), do: {not is_nil(value), presence(value)}
  defp check({:ok, value}, :absent, _attribute, _ctx), do: {is_nil(value), presence(value)}

  defp check({:ok, %DateTime{} = value}, :since_start, _attribute, %{
         receipt: %{started_at: started}
       }) do
    case DateTime.compare(value, started) do
      :lt -> {false, :before_start}
      _same_or_later -> {true, :since_start}
    end
  end

  defp check({:ok, value}, :since_start, _attribute, _ctx), do: {false, presence(value)}

  defp check({:ok, value}, :claimed, attribute, %{result: {:ok, %{} = record}}) do
    case Ash.Type.equal?(
           attribute.type,
           value,
           Map.get(record, attribute.name),
           attribute.constraints
         ) do
      true -> {true, :matches}
      false -> {false, :differs}
    end
  end

  defp check({:ok, _value}, :claimed, _attribute, _ctx), do: {false, :no_claim}

  defp check({:ok, value}, wanted, attribute, _ctx) do
    {Ash.Type.equal?(attribute.type, value, wanted, attribute.constraints), shown(value)}
  end

  defp expected(wanted) when wanted in [:present, :absent, :claimed, :since_start], do: wanted
  defp expected(wanted), do: shown(wanted)

  defp shown(value) do
    if Redactor.scalar?(value), do: value, else: presence(value)
  end

  defp presence(nil), do: :absent
  defp presence(_value), do: :present

  defp dump(resource, field, value) do
    attribute = Ash.Resource.Info.attribute(resource, field)

    with {:ok, cast} <- Ash.Type.cast_input(attribute.type, value, attribute.constraints),
         {:ok, dumped} <- Ash.Type.dump_to_native(attribute.type, cast, attribute.constraints) do
      dumped
    else
      _uncastable -> value
    end
  end

  defp primary(resource), do: resource |> Ash.Resource.Info.primary_key() |> List.first()

  defp column(resource, field) do
    case Ash.Resource.Info.attribute(resource, field) do
      %{source: source} when is_atom(source) and not is_nil(source) -> source
      _attribute -> field
    end
  end
end
