# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Notifiers.HeadCodes do
  @moduledoc """
  Keeps a written head code entry in `MishkaCmsCore.Runtime.States.SiteState`'s head code index, on
  the node that wrote it: what `MishkaCmsCore.Runtime.HeadCodes` reads instead of the database.

  Notifiers run after the transaction commits, for every action of the resource and in the writing
  process, so the next page that writer opens already carries the entry. A create or an update puts
  the row (`SiteState.put_head_code/1`), which takes it out again when it is a draft or archived; a
  delete takes it out.

  Every other node hears the same write over `Ash.Notifier.PubSub` and applies it in `SiteState`,
  which leaves alone the broadcasts this node sent.
  """
  @behaviour Ash.Notifier

  alias MishkaCmsCore.Runtime.States.SiteState

  @impl true
  def notify(%Ash.Notifier.Notification{action: %{type: :destroy}, data: entry}),
    do: SiteState.delete_head_code(entry)

  def notify(%Ash.Notifier.Notification{data: entry}), do: SiteState.put_head_code(entry)

  # Never require original data: requesting it forces a pre-action load, which makes the action
  # non-atomic. The record in `data` carries everything the index keeps.
  @impl true
  def requires_original_data?(_resource, _action), do: false
end
