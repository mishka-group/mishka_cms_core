defmodule MishkaCmsCoreWeb.Forms.ContentComponentEvents do
  @moduledoc """
  A Gervaz form's events with one more, `insert_content_component`: a component's marker written at
  the end of one of the form's text areas — what Insert sends from
  `MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker`.

      form do
        events MishkaCmsCoreWeb.Forms.ContentComponentEvents
      end

  The event carries the picker's fields under `content_component`: `name`, `attrs`, `inner` and the
  `field` to write into, which must be a `:textarea` field of this form. The marker is
  `MishkaCmsCore.Runtime.ContentComponents.marker/3`, and it goes through the form's own change, so
  the field shows it, the record is marked changed, and nothing is saved until the author saves.
  The picker is then closed. Every other event is Gervaz's own.
  """

  use MishkaGervaz.Form.Web.Events

  alias MishkaCmsCore.Runtime.ContentComponents
  alias MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker
  alias MishkaGervaz.Form.Web.Events

  @impl true
  def handle("insert_content_component", %{"content_component" => %{} = picked}, socket) do
    state = socket.assigns.form_state

    with %{name: name} <- text_area(state, picked["field"]),
         %Phoenix.HTML.Form{} = form <- state.form,
         marker when is_binary(marker) <-
           ContentComponents.marker(picked["name"], picked["attrs"], picked["inner"]) do
      key = to_string(name)

      written =
        form |> Phoenix.HTML.Form.input_value(name) |> text() |> ContentComponents.append(marker)

      Phoenix.LiveView.send_update(ContentComponentPicker,
        id: ContentComponentPicker.id(state.static.id, key),
        inserted: true
      )

      Events.do_handle(
        "validate",
        %{"form" => %{key => written}, "_target" => ["form", key]},
        state,
        socket
      )
    else
      _nothing_to_write -> {:noreply, socket}
    end
  end

  def handle(event, params, socket), do: super(event, params, socket)

  defp text_area(state, field) when is_binary(field),
    do: Enum.find(state.static.fields, &(&1.type == :textarea and to_string(&1.name) == field))

  defp text_area(_state, _field), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""
end
