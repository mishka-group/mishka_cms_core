# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.ErrorStatusOnce do
  @moduledoc """
  Refuses an Error Page whose `error_pages` hold two entries for one status, naming the second: only
  the first of them would ever be drawn.

  Only a write that changes `:error_pages` is judged, so a row stored with two keeps working and its
  other fields stay editable.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.ErrorStatus

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.changing_attribute?(changeset, :error_pages) do
      true -> changeset |> Ash.Changeset.get_attribute(:error_pages) |> List.wrap() |> once()
      false -> :ok
    end
  end

  defp once(entries) do
    statuses = Enum.map(entries, &ErrorStatus.parse(&1.status))

    case statuses -- Enum.uniq(statuses) do
      [] -> :ok
      [status | _rest] -> {:error, field: :error_pages, message: refusal(statuses, status)}
    end
  end

  defp refusal(statuses, status) do
    [_first, second | _rest] =
      for {^status, number} <- Enum.with_index(statuses, 1), do: number

    dgettext(
      "errors",
      "Entry %{number} is a second %{status} page. Keep one entry for each status.",
      number: second,
      status: to_string(status)
    )
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts) do
    [message: "Validates that an error page holds one entry for each status", vars: []]
  end
end
