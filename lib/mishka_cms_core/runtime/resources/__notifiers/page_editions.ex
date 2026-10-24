# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Notifiers.PageEditions do
  @moduledoc """
  Keeps a written page's row in `MishkaCmsCore.Runtime.States.SiteState`'s editions index, on the
  node that wrote it — what `MishkaCmsCore.Runtime.PageEditions.editions/2` reads instead of the
  database.

  Notifiers run **after the transaction commits**, for every action of a resource that lists this —
  master twins, a draft's publish, a bulk action and an action added later included — and in the
  writing process, so the request that writer makes next is answered with the row as it now is. A
  create or an update puts the row (`SiteState.put_page_edition/1`), which takes it out again when
  it is inactive or archived; an archive or a delete takes it out.

  Every other node hears the same write over `Ash.Notifier.PubSub` and applies it in `SiteState`,
  which leaves alone the broadcasts this node sent.

  No page is compiled again for this. A page reads its group's editions on every render, so a
  sibling added, moved or removed is offered, or no longer offered, without its module changing.
  """
  @behaviour Ash.Notifier

  alias MishkaCmsCore.Runtime.States.SiteState

  @impl true
  def notify(%Ash.Notifier.Notification{action: %{type: :destroy}, data: page}),
    do: SiteState.delete_page_edition(page)

  def notify(%Ash.Notifier.Notification{data: page}), do: SiteState.put_page_edition(page)

  # Never require original data: requesting it forces a pre-action load, which makes the action
  # non-atomic. The record in `data` carries the site, the group and whether it is live.
  @impl true
  def requires_original_data?(_resource, _action), do: false
end
