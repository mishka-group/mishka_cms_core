defmodule MishkaCmsCore.Activity.Calculations.Tone do
  @moduledoc """
  Ash calculation that exposes `:tone` (atom or `nil`) on a resource carrying an action name — the
  content-change colour the activity timeline tints a create/update/destroy row by, parallel to
  `MishkaCmsCore.Activity.Calculations.Severity`. Delegates to
  `MishkaCmsCore.Activity.Helpers.tone_for/1`, so a create reads `:created`, an update `:updated`, a
  destroy `:destroyed`, and anything else `nil` — a row the timeline then falls back to colouring by
  `:severity`.

  Wire it beside the `:severity` calculation, `:field` naming the attribute holding the action:

      calculate :tone, :atom,
                {MishkaCmsCore.Activity.Calculations.Tone, field: :action}
  """

  use Ash.Resource.Calculation

  alias MishkaCmsCore.Activity.Helpers

  @impl true
  def init(opts), do: {:ok, Keyword.put_new(opts, :field, :version_action_name)}

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, &Helpers.tone_for(Map.get(&1, opts[:field])))
  end
end
