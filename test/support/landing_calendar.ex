# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.LandingCalendar do
  @moduledoc """
  The ISO calendar, with a write landed inside the first comparison that reads one of its dates.

  `MishkaCmsCore.Runtime.PageBuilder.EditorSession.drain_pending/1` sorts the history queue by when
  each entry was made while it works out the drained session — between its read and its write, where
  no plugin is asked. A date on this calendar is a way in: `land/1` queues a write in the calling
  process, and the next time a date on this calendar is compared there, the write runs, once.

  Only what comparing two dates asks of a calendar is answered.
  """

  @doc "Queues `write` for the next comparison of a date on this calendar in the calling process."
  @spec land((-> term())) :: :ok
  def land(write) when is_function(write, 0) do
    send(self(), {__MODULE__, :land, write})
    :ok
  end

  @doc "The present moment, dated on this calendar."
  @spec utc_now() :: DateTime.t()
  def utc_now, do: %{DateTime.utc_now() | calendar: __MODULE__}

  @doc false
  def naive_datetime_to_iso_days(year, month, day, hour, minute, second, microsecond) do
    receive do
      {__MODULE__, :land, write} -> write.()
    after
      0 -> :ok
    end

    Calendar.ISO.naive_datetime_to_iso_days(year, month, day, hour, minute, second, microsecond)
  end
end
