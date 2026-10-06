defmodule MishkaCmsCore.Runtime.Resources.Embeddeds.Helper do
  @moduledoc """
  Embedded resource for helper function definitions in runtime resources.

  This embedded resource represents helper functions that can be defined within
  Pages, Layouts, Components, and Error Pages. Helpers allow runtime resources
  to include custom Elixir functions that enhance template functionality,
  providing reusable logic for data transformation, formatting, and calculations.

  Each helper consists of a function name, argument list, and the function body
  code. These are compiled into the runtime module as actual Elixir functions,
  making them available for use within templates and event handlers. The embedded
  nature means helpers are stored as JSON within the parent resource's database record.

  Helpers enable dynamic functionality without requiring code deployment, allowing
  CMS users to extend the system's capabilities through the UI. Common use cases
  include date formatting, string manipulation, calculation helpers, and view-specific
  utility functions that simplify template logic.
  """

  use Ash.Resource, data_layer: :embedded

  @derive {Jason.Encoder,
           only: [:name, :args, :code, :attrs, :slots, :discriminators, :signature]}

  attributes do
    attribute :name, :string, allow_nil?: false, public?: true
    # `args` allows nil + defaults to `""` so zero-arg helpers
    # (`def x(), do: ...`) round-trip through the embedded resource.
    # Ash 3's required-string validation rejects empty strings on
    # `allow_nil?: false` attributes, so `allow_nil?: true` is required
    # to permit `""` as a valid value. The downstream compiler emits
    # `def name() do ... end` for empty args — valid Elixir.
    attribute :args, :string, allow_nil?: true, default: "", public?: true
    attribute :code, :string, allow_nil?: false, public?: true

    # Phoenix Component allows `attr/3` and `slot/3` declarations to
    # apply to a helper `defp` (e.g.  `attr :size, :string, default:
    # "small" ; defp toast_dismiss(assigns) do ~H""" ... """ end`).
    # Carry those as nested arrays so the runtime compiler can emit
    # them right before the helper's def — Phoenix associates them
    # with the next def/defp in compilation order, giving the helper
    # its own component contract (defaults, change-tracking).
    attribute :attrs, {:array, :map}, default: [], public?: true
    attribute :slots, {:array, :map}, default: [], public?: true

    # Per-helper axis filter clauses extracted from the kit's `.eex`
    # `<%= if cond %>` chain wrapping each `defp` (see Mishka
    # Chelekom's `HelperConditionIndex` + `HelperDiscriminators`).
    # Shape: `[%{"axis" => "variant", "values" => ["base"]}, …]`,
    # ANDed by the installer for safe selection-based narrowing.
    # Empty list ⇒ helper is unconstrained (always installed).
    attribute :discriminators, {:array, :map}, default: [], public?: true

    # SOMEWHERE TO KEEP THE HMAC. `MishkaCmsCore.Runtime.PageBuilder.CodeSignature` signs each stored
    # snippet so that code which did not come through this application does not run, and `events` and
    # `infos` — plain maps — have carried one since it existed. A helper could not: there was no field
    # for it and `@derive` would have dropped one anyway, so `trusted?/1` answered false for every
    # helper and a deployment that turned signing on compiled all of them inert.
    #
    # `nil` until `mix mishka.resign_code` runs, which is what the log line says to do. With no key
    # configured — the default — nothing is signed and nothing is verified, so an existing database
    # keeps working exactly as it did.
    attribute :signature, :string, allow_nil?: true, public?: true
  end
end
