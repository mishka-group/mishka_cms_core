# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Calculations.ResourceLabel do
  @moduledoc """
  Ash calculation that exposes `:resource_label` (string) on a paper-trail
  version resource. Each PaperTrail mixin passes a literal label so the
  same name appears in the activity feed and any other Ash consumer
  (API, GraphQL) without that consumer having to inspect the source
  module name.

  Wire it from each PaperTrail mixin's `calculations` block, passing the
  label as an option:

      calculate :resource_label,
                :string,
                {MishkaCmsCore.Activity.Calculations.ResourceLabel,
                 label: "Page"}
  """

  use Ash.Resource.Calculation

  alias MishkaCmsCore.Activity.Helpers

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :label) do
      {:ok, label} when is_binary(label) and label != "" -> {:ok, opts}
      _ -> {:error, "ResourceLabelCalculation requires a non-empty :label option"}
    end
  end

  @impl true
  def calculate(records, opts, _context) do
    label = Helpers.translate(opts[:label])
    Enum.map(records, fn _ -> label end)
  end
end
