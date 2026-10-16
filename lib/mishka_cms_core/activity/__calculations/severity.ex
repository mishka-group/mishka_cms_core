# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Calculations.Severity do
  @moduledoc """
  Ash calculation that exposes `:severity` (atom) on a resource carrying an action name — every
  paper-trailed version resource, and the event logs the activity timeline draws. Delegates to
  `MishkaCmsCore.Activity.Helpers.severity_for/1` so the same mapping is used in the live broadcast
  path and in the unified log's SQL.

  Wire it from each PaperTrail mixin's `calculations` block:

      calculate :severity, :atom,
                MishkaCmsCore.Activity.Calculations.Severity

  `:field` names the attribute holding the action, for a resource that calls it something other than
  a version's `:version_action_name`:

      calculate :severity, :atom,
                {MishkaCmsCore.Activity.Calculations.Severity, field: :action}
  """

  use Ash.Resource.Calculation

  alias MishkaCmsCore.Activity.Helpers

  @impl true
  def init(opts), do: {:ok, Keyword.put_new(opts, :field, :version_action_name)}

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, &Helpers.severity_for(Map.get(&1, opts[:field])))
  end
end
