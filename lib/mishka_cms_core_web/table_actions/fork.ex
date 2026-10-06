defmodule MishkaCmsCoreWeb.TableActions.Fork do
  @moduledoc """
  A row action that copies a record and leaves the original alone — Gervaz's `ActionType` behaviour
  rather than a custom event.

  Every other control on a drafts row is a built-in: `:destroy` deletes, the row click opens.
  Forking has no built-in equivalent, and the honest way to add one is a type the table understands,
  not an escape hatch that routes around it. Declared like any other:

      row_actions do
        action :fork, type: MishkaCmsCoreWeb.TableActions.Fork
      end

  It pushes Gervaz's own `row_action` event, so the table's before/after hooks, its confirm handling
  and its authorization checks all apply exactly as they do to a built-in. What the fork *means* —
  copy this draft's template under a free name — belongs to the resource's `after_row_action` hook,
  not here; this module only draws the control and names the event.

  See `MishkaGervaz.Table.Behaviours.ActionType` for what may go in the assigns map, and
  `MishkaGervaz.Table.Types.Action.Unarchive` for the shape this follows.
  """

  @behaviour MishkaGervaz.Table.Behaviours.ActionType

  use Phoenix.Component
  use MishkaGervaz.Messages

  import MishkaGervaz.Helpers, only: [dynamic_component: 1, maybe_assign: 3, resolve_label: 1]

  @impl true
  def render(_assigns, action, record, ui, target) do
    assigns =
      %{__changed__: %{}}
      |> assign(:module, ui)
      |> assign(:function, :button)
      |> assign(:variant, :secondary)
      |> assign(:label, resolve_label(action[:ui][:label]) || dgettext("mishka_gervaz", "Copy"))
      |> assign(:icon, action[:ui][:icon] || "hero-document-duplicate")
      |> maybe_assign(:class, action[:ui][:class])
      |> assign(:phx_click, "row_action")
      |> assign(:phx_value_event, "fork")
      |> assign(:phx_value_id, record.id)
      |> assign(:phx_target, target)
      |> maybe_assign(:data_confirm, action[:confirm])

    ~H"""
    <.dynamic_component {assigns} />
    """
  end
end
