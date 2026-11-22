# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.ErrorStatusOnce do
  @moduledoc """
  Refuses an Error Page whose `error_pages` hold two entries for one status, naming the second: only
  the first of them would ever be drawn.

  Only a write that changes `:error_pages` is judged, so a row stored with two keeps working and its
  other fields stay editable. Entries that were not taken, as a form's are while one has a status and
  no template yet, are judged as they were sent, so the second is named once its status is picked.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.ErrorStatus

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case {Enum.find(changeset.errors, &refused?/1),
          Ash.Changeset.changing_attribute?(changeset, :error_pages)} do
      {%{value: sent}, _changing} -> sent |> sent_entries() |> once()
      {nil, true} -> changeset |> Ash.Changeset.get_attribute(:error_pages) |> once()
      {nil, false} -> :ok
    end
  end

  defp refused?(%Ash.Error.Changes.InvalidAttribute{path: [:error_pages | _rest]}), do: true
  defp refused?(_another), do: false

  defp sent_entries(entries) when is_list(entries), do: entries

  # A form sends a list as a map of its places.
  defp sent_entries(%{} = placed) do
    entries =
      for {key, entry} when is_binary(key) <- placed,
          {place, ""} <- [Integer.parse(key)],
          do: {place, entry}

    entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  defp sent_entries(_not_entries), do: []

  defp once(entries) do
    statuses = entries |> List.wrap() |> Enum.map(&status/1)

    case Enum.reject(statuses -- Enum.uniq(statuses), &is_nil/1) do
      [] -> :ok
      [status | _rest] -> {:error, field: :error_pages, message: refusal(statuses, status)}
    end
  end

  defp status(%{status: status}), do: ErrorStatus.parse(status)
  defp status(%{"status" => status}), do: ErrorStatus.parse(status)
  defp status(_without), do: nil

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
