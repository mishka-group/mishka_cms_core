defmodule MishkaCmsCoreWeb.Forms.SnippetSubmit do
  @moduledoc """
  The submit handler for the Studio's "Save as snippet" box.

  It exists for one reason: to keep a failed save VISIBLE. Gervaz reports a rejected submit by
  assigning the errors onto the form's own state for the template to draw, and this template draws
  none — the box has no error slot in the design, and never had one, because every snippet failure
  has always been a flash. Without this, an author clicking Save on a duplicate name would watch
  nothing happen.

  Everything else is `MishkaGervaz.Form.Web.Events.SubmitHandler.Default`'s work; this only looks at
  what the state holds afterwards and forwards the first real message to the LiveView, which owns
  the flash. `self()` is the LiveView process — a LiveComponent runs inside its parent — so a plain
  `send/2` reaches `MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive.handle_info/2`.

  The blank-name and unparseable-markup cases never reach here: `MishkaCmsCore.Runtime.Snippet`'s
  `before_save` hook halts on those first, so they keep the panel's own wording.
  """

  use MishkaGervaz.Form.Web.Events.SubmitHandler

  def submit(state, params, socket) do
    socket = super(state, params, socket)

    case failure_message(socket.assigns[:form_state]) do
      nil -> socket
      message -> tap(socket, fn _socket -> send(self(), {:snippet_error, message}) end)
    end
  end

  # `errors` is keyed by field, `form_errors` holds the ones that belong to no field. Either way one
  # sentence is what a flash can carry, so the first is the one that gets said.
  defp failure_message(%{errors: errors, form_errors: form_errors}) do
    first_message(form_errors) || errors |> Map.values() |> first_message()
  end

  defp failure_message(_state), do: nil

  defp first_message(messages) when is_list(messages) do
    messages
    |> List.flatten()
    |> Enum.map(&message_text/1)
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp first_message(_messages), do: nil

  defp message_text(message) when is_binary(message), do: message
  defp message_text({message, _opts}) when is_binary(message), do: message
  defp message_text(%{message: message}) when is_binary(message), do: message
  defp message_text(_message), do: nil
end
