# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Calculations.ByMaster do
  @moduledoc """
  Whether the account a record names is a master's, for every record in one read.

  `:field` names the attribute holding the user id:

      calculate :author_master?, :boolean,
                {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :author_id}

  Load it beside the account relationship and pass both to `MishkaCmsCore.Accounts.Helper.who/4`.
  A record with no id in `:field` is `false`.
  """
  use Ash.Resource.Calculation

  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def init(opts) do
    case opts[:field] do
      field when is_atom(field) and not is_nil(field) ->
        {:ok, opts}

      _missing ->
        {:error, "#{inspect(__MODULE__)} needs `field:`, the attribute holding a user id"}
    end
  end

  @impl true
  def load(_query, opts, _context), do: [opts[:field]]

  @impl true
  def calculate(records, opts, _context) do
    ids = Enum.map(records, &Map.get(&1, opts[:field]))

    with {:ok, masters} <- Helper.master_ids(ids) do
      {:ok, Enum.map(ids, &MapSet.member?(masters, &1))}
    end
  end
end
