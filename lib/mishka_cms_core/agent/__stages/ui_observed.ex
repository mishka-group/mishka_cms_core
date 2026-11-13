# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.UiObserved do
  @moduledoc """
  A LiveView received the operation's broadcast.

  ## What verified means

  A LiveView process that mounts `MishkaCmsCore.Agent.UiObserver` received the Ash broadcast that
  this very operation sent: the notification carries the receipt id, so another operation's
  broadcast never counts. The evidence is the view's module, the topic and the event, never its
  assigns. It usually arrives after the receipt is stored, and is applied when the receipt is read.

  ## What it does not prove

  That the view handled the message well, that its assigns or stream changed, that the browser
  rendered it or that anybody saw it. The observer runs before the view's own `handle_info/2`. A
  check of the page itself belongs to a browser test. With no observing LiveView (an API or agent
  call, nobody on the page) the stage stays unverified (`:no_observer`), which is the honest
  answer, not a failure.
  """
  @behaviour MishkaCmsCore.Agent.Stages

  @impl true
  def layer(_opts), do: :ui

  @impl true
  def verify(_ctx, _opts), do: {:unverified, :no_observer}
end
