# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.SideEffect do
  @moduledoc """
  A named effect the operation declares and checks itself, such as a share card drawn or a
  notification delivered.

      {:side_effect, :share_card, layer: :db, check: &MyExtension.Agent.Checks.share_card/1}

  ## Options

    * `:check` — required: a remote capture or `{module, fun, args}` called with the context
      (`MishkaCmsCore.Agent.Stages`) that answers with evidence.
    * `:layer` — `:app` (default), `:db` or `:ui`: where the check's evidence comes from.

  ## What verified means

  Whatever the declaring extension documents for its check, which must read the effect itself, not
  the action's return value.

  ## What it does not prove

  Anything beyond that check. A check that raises fails the stage (`:raised`); one that is missing
  fails it (`:no_check`).
  """
  @behaviour MishkaCmsCore.Agent.Stages

  alias MishkaCmsCore.Agent.Stages

  @impl true
  def layer(opts), do: Keyword.get(opts, :layer, :app)

  @impl true
  def verify(ctx, opts) do
    case Keyword.fetch(opts, :check) do
      {:ok, check} -> Stages.call(check, ctx)
      :error -> {:error, :no_check}
    end
  end
end
