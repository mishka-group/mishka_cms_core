defmodule MishkaCmsCore.Runtime.PageMessage do
  @moduledoc """
  What a page says to a visitor when something on it is clicked.

  ## Why a flash and not a widget

  Because Phoenix already has this. `put_flash/3` writes it, the layout or the page renders it,
  `lv:clear-flash` dismisses it, and the kit's own `chelekom-flash` is already bound to
  `Phoenix.Flash.get/2` — so a message an author sets in the editor arrives in whatever flash
  component that site designed, styled the way they styled it. A second notification system beside
  the one the framework ships would have to be styled twice and dismissed twice.

  The client half is `Phoenix.LiveView.JS.push/2`, which is what
  `MishkaCmsCore.Runtime.PageBuilder.Interactions` compiles:

      <button phx-click={JS.push("pb:say", value: %{"kind" => "info", "message" => "Saved!"})}>

  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` gives a page that carries one of those the
  matching `handle_event/3`, and nothing else changes: the same two flash kinds, read back by
  `MishkaCmsCore.Runtime.PageForm.announcements/1`, rendered by the same region.

  ## What the params are trusted for

  Nothing but the words. `kind` is matched against the two that exist and anything else is dropped;
  the message is trimmed, capped, and rendered as text, which HEEx escapes.

  It is worth being plain about what that does and does not buy. A visitor with the console open can
  push this event with words of their own — but the flash lands on their own socket, is never
  stored, never broadcast, and is gone on the next navigation. What they can make their own browser
  say, they could already say by editing their own DOM. The check that matters is the one on `kind`,
  because that one picks a branch in somebody's markup.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @event "pb:say"

  @kinds %{"info" => :info, "error" => :error}

  @limit 240

  @doc "The event name a click pushes, and the string the compiler looks for in a template."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The kinds a message may be, as `{value, label}` in panel order."
  @spec kinds() :: [{String.t(), String.t()}]
  def kinds, do: [{"info", gettext("Success")}, {"error", gettext("Problem")}]

  @doc """
  Puts one message on the socket, or leaves it exactly as it was.

  Silence is the answer to anything malformed. A page that flashed "invalid kind" at a visitor would
  be reporting an editor's mistake to the wrong audience.
  """
  @spec say(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def say(socket, %{"kind" => kind, "message" => message}) when is_binary(message) do
    put(socket, Map.get(@kinds, kind), String.trim(message))
  end

  def say(socket, _params), do: socket

  defp put(socket, nil, _message), do: socket
  defp put(socket, _kind, ""), do: socket

  defp put(socket, kind, message),
    do: Phoenix.LiveView.put_flash(socket, kind, String.slice(message, 0, @limit))
end
