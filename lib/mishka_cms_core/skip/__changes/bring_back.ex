# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Skip.Changes.BringBack do
  @moduledoc """
  The `:bring_back` action of a row that can be skipped (`MishkaCmsCore.Skip`): refuses a row that is
  not skipped, clears `skipped_at`, `skipped_by_id` and `skip_reason`, sets the state back to a
  failure, makes the row's jobs the skip cancelled failed jobs again
  (`MishkaCmsCore.Skip.bring_back_jobs/1`) and, once committed, calls `MishkaCmsCore.Skip.changed/1`.
  The row is not tried again by itself.

  Options: `source` (required), `status` (`{attribute, value}` the state goes back to, such as
  `{:status, :failed}`) and `worker`, as `MishkaCmsCore.Skip.Changes.Skip` takes them.

      update :bring_back do
        require_atomic? false
        change {MishkaCmsCore.Skip.Changes.BringBack,
                source: "shop:delivery", status: {:status, :failed}, worker: MyShop.Delivery.Worker}
      end
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Skip
  alias MishkaCmsCore.Skip.Changes.Skip, as: SkipChange

  @impl true
  def change(%{data: %{skipped_at: %DateTime{}}} = changeset, opts, context) do
    changeset
    |> Ash.Changeset.force_change_attributes(Skip.cleared())
    |> state(opts[:status])
    |> Ash.Changeset.after_action(fn _changeset, record ->
      if worker = opts[:worker], do: Skip.bring_back_jobs(Skip.record_jobs(worker, record.id))
      {:ok, record}
    end)
    |> Ash.Changeset.after_transaction(fn
      changeset, {:ok, record} ->
        Skip.changed(%{
          source: Keyword.fetch!(opts, :source),
          id: record.id,
          site_id: SkipChange.site_id(record, changeset),
          skipped?: false,
          actor_id: actor_id(context.actor)
        })

        {:ok, record}

      _changeset, error ->
        error
    end)
  end

  def change(changeset, _opts, _context),
    do:
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: dgettext("errors", "Only a skipped item can be brought back.")
      )

  defp state(changeset, {attribute, value}),
    do: Ash.Changeset.force_change_attribute(changeset, attribute, value)

  defp state(changeset, nil), do: changeset

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_none), do: nil
end
