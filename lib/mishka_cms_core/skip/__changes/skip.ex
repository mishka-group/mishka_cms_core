# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Skip.Changes.Skip do
  @moduledoc """
  The `:skip` action of a row that can be skipped (`MishkaCmsCore.Skip`): refuses a row that is not
  a failure, writes `skipped_at`, `skipped_by_id` (the actor) and `skip_reason` (the action's
  `reason` argument, `MishkaCmsCore.Skip.reason/1`), sets the state, cancels the row's jobs and,
  once committed, calls `MishkaCmsCore.Skip.changed/1`.

  Options:

    * `source` — the name of what is skipped across the CMS, such as `"shop:delivery"`
      (`MishkaCmsCore.Skip.key/2`); required.
    * `status` — `{attribute, value}` the state takes, such as `{:status, :skipped}`; leave it out
      for a resource with no state.
    * `from` — the values of the state a row may be skipped from, such as `[:failed]`; with
      `status` only. Any other row is refused with "Only a failed item can be skipped.".
    * `worker` — the AshOban worker of the row's trigger (`worker_module_name`): its waiting jobs
      for the row are cancelled and its given-up ones marked (`MishkaCmsCore.Skip.skip_jobs/2`).

      update :skip do
        require_atomic? false
        argument :reason, :string
        change {MishkaCmsCore.Skip.Changes.Skip,
                source: "shop:delivery", status: {:status, :skipped}, from: [:failed],
                worker: MyShop.Delivery.Worker}
      end
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Skip

  @impl true
  def change(changeset, opts, context) do
    case skippable?(changeset.data, opts) do
      true -> mark(changeset, opts, context)
      false -> Ash.Changeset.add_error(changeset, field: :status, message: refused())
    end
  end

  defp refused, do: dgettext("errors", "Only a failed item can be skipped.")

  defp skippable?(%{skipped_at: %DateTime{}}, _opts), do: false

  defp skippable?(data, opts) do
    case {opts[:status], opts[:from]} do
      {{attribute, _value}, [_ | _] = from} -> Map.get(data, attribute) in from
      _no_state -> true
    end
  end

  defp mark(changeset, opts, context) do
    mark = Skip.mark(context.actor, Ash.Changeset.get_argument(changeset, :reason))

    changeset
    |> Ash.Changeset.force_change_attributes(mark)
    |> state(opts[:status])
    |> Ash.Changeset.after_action(fn _changeset, record ->
      if worker = opts[:worker], do: Skip.skip_jobs(Skip.record_jobs(worker, record.id), mark)
      {:ok, record}
    end)
    |> Ash.Changeset.after_transaction(fn
      changeset, {:ok, record} ->
        Skip.changed(%{
          source: Keyword.fetch!(opts, :source),
          id: record.id,
          site_id: site_id(record, changeset),
          skipped?: true,
          reason: mark.skip_reason,
          actor_id: mark.skipped_by_id
        })

        {:ok, record}

      _changeset, error ->
        error
    end)
  end

  defp state(changeset, {attribute, value}),
    do: Ash.Changeset.force_change_attribute(changeset, attribute, value)

  defp state(changeset, nil), do: changeset

  @doc false
  @spec site_id(map(), Ash.Changeset.t()) :: String.t() | nil
  def site_id(%{site_id: site_id}, _changeset) when is_binary(site_id), do: site_id
  def site_id(_record, %{tenant: tenant}) when is_binary(tenant), do: tenant
  def site_id(%{tenant: tenant}, _changeset) when is_binary(tenant), do: tenant
  def site_id(_record, _changeset), do: nil
end
