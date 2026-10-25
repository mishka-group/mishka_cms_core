# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Mail.Workers.DeliverWorker do
  @moduledoc """
  Sends one queued email (see `MishkaCmsCore.Mail`), on the `mail` queue.

  The job carries the delivery's id, its site, its idempotency key and the email sealed with the
  endpoint's key — a reset or sign-in email holds a token, and finished jobs stay in `oban_jobs`
  for a week. It carries no provider key: the provider reads its own when the job runs.

  A failure the provider calls worth retrying (`c:MishkaCmsCore.Mail.Provider.retry?/1`) is retried
  with Oban's backoff, with the same idempotency key; anything else, and the last attempt, ends
  the delivery `:failed`. A site that lost its provider in the meantime ends it `:not_configured`.
  Once the provider has answered, the site's history older than `mailer.history_days` goes
  (`MishkaCmsCore.Mail.prune/1`).
  """

  use Oban.Worker, queue: :mail, max_attempts: 5

  alias MishkaCmsCore.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    with {:ok, delivery, email} <- Mail.open(args),
         {:ok, provider} <- provider(delivery) do
      case Mail.run(delivery, email, provider, args["idempotency_key"], attempt >= max_attempts) do
        {:error, reason, false} ->
          {:error, Mail.describe(reason)}

        answered ->
          Mail.prune(delivery.site_id)
          finished(answered)
      end
    else
      {:error, :no_provider} -> {:cancel, :not_configured}
      {:error, reason} -> {:cancel, Mail.describe(reason)}
    end
  end

  defp finished({:ok, _message_id}), do: :ok
  defp finished({:error, reason, true}), do: {:cancel, Mail.describe(reason)}

  defp provider(delivery) do
    case Mail.provider(delivery.site_id) do
      {:ok, provider} ->
        {:ok, provider}

      {:error, reason} ->
        Mail.not_configured(delivery, reason)
        {:error, :no_provider}
    end
  end
end
