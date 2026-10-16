# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Notify.Workers.FanoutWorker do
  @moduledoc """
  Fans a large / unbounded notification audience out to per-recipient rows off the request path.

  Enqueued by `MishkaCmsCore.Notify.Delivery` for `:permission` / `:masters` (or large explicit)
  audiences. It re-resolves the audience from the serialized args and STREAMS recipients in
  batches via `Delivery.fan_out/4`, so a site with a very large user base is written in constant
  memory. `unique` (on `dedup_key`) collapses accidental duplicate fan-outs. The site is carried
  in the args (`"site_id"`) and resolved here — never re-derived.
  """

  use Oban.Worker, queue: :notify, max_attempts: 5

  alias MishkaCmsCore.Notify.Delivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"audience" => audience, "attrs" => attrs} = args}) do
    spec = Delivery.deserialize(audience)
    Delivery.fan_out(spec, attrs, args["site_id"], except: args["except"] || [])
    :ok
  end
end
