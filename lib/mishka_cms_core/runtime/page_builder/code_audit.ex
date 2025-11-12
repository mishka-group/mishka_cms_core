defmodule MishkaCmsCore.Runtime.PageBuilder.CodeAudit do
  @moduledoc """
  How much of the stored code in this database carries a signature this deployment cannot verify.

  ## What it is for

  `MishkaCmsCore.Runtime.PageBuilder.CodeSignature` names each unverified snippet as it compiles,
  which is the right thing to say and the wrong shape to read: the lines are scattered through a boot
  that also logs every site, page and component, and there is no moment at which somebody learns
  "none of the code in this database runs here". A deployment that configures a key for the first
  time, or restores a dump from somewhere else, gets exactly that failure — everything renders, and
  every handler and every live component's `handle_event/3` quietly does nothing.

  So this counts them and says the total once, with the command that fixes it.

  ## What it costs

  Nothing when signing is off, which is the default: `untrusted/0` answers `0` without reading
  anything. With a key configured it is one streamed pass over the four resources that store code,
  run once at boot.

  ## Not a health check

  A non-zero count is not necessarily wrong — a developer holding a production dump SHOULD see one,
  and running `mix mishka.resign_code` on a machine whose database was tampered with is the one
  situation where the count is the honest answer and re-signing is not. The log line says so.
  """

  require Logger

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.PageBuilder.CodeSignature

  @sources [
    {Layout, [:helpers]},
    {Component, [:helpers]},
    {ErrorPage, [:helpers]}
  ]

  @doc """
  The resources that store Elixir, and which of their fields hold it.

  `Mix.Tasks.Mishka.ResignCode` re-signs exactly what this counts, and reads the list from here so
  that a fifth resource gaining a code field cannot be audited and left unsigned, or the reverse.
  """
  @spec sources() :: [{module(), [atom()]}]
  def sources, do: @sources

  @doc """
  How many stored snippets this deployment's key does not verify.

  `0` when signing is off, without reading the database.
  """
  @spec untrusted() :: non_neg_integer()
  def untrusted do
    case CodeSignature.enabled?() do
      false -> 0
      true -> @sources |> Enum.map(&count/1) |> Enum.sum()
    end
  end

  @doc """
  Counts them and logs the total at `warning`, or says nothing at all when there is nothing to say.

  Always answers `:ok`: a database it cannot read is not a reason to fail a boot that otherwise
  succeeded, and the per-snippet warnings still name whatever did compile.
  """
  @spec report() :: :ok
  def report do
    case untrusted() do
      0 ->
        :ok

      count ->
        Logger.warning(
          "[CodeSignature] #{count} stored snippet(s) carry no signature this deployment can " <>
            "verify, and every one of them compiles to a clause that does nothing — handlers, " <>
            "helpers, and a live component's own event handling. If this database came from " <>
            "another environment, run `mix mishka.resign_code`. If it did not, read the lines " <>
            "above that name each one before you sign whatever is in there."
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("[CodeSignature] could not audit stored code: #{inspect(error)}")
      :ok
  end

  defp count({resource, fields}) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.stream!(authorize?: false, batch_size: 100)
    |> Enum.reduce(0, fn row, total -> total + untrusted_in(row, fields) end)
  end

  defp untrusted_in(row, fields) do
    for field <- fields,
        snippet <- row |> Map.get(field) |> List.wrap(),
        not CodeSignature.trusted?(snippet),
        reduce: 0 do
      total -> total + 1
    end
  end
end
