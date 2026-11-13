# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.ReceiptWorker do
  @moduledoc """
  An Oban worker for the receipt tests: it succeeds, or raises when its args say `"fail"`, so a
  test can watch `MishkaCmsCore.Agent.Stages.JobDone` hear both.
  """
  use Oban.Worker, queue: :default

  @impl true
  def perform(%Oban.Job{args: %{"fail" => true}}), do: raise("the job could not run")
  def perform(_job), do: :ok
end
