defmodule MishkaCmsCore.Builder.Actions.Say do
  @moduledoc """
  Show a message — core's one server action, and the shape a package's should copy.

  ## Why this one is not a `JS` command

  The other six move classes and visibility around, which the browser can do on its own. A message
  cannot be one of them: a flash lives on the socket, `put_flash/3` writes it, the layout or the page
  renders it and `lv:clear-flash` dismisses it. There is no client-side way to add one, and inventing
  a second notification system beside the framework's would mean styling it twice and dismissing it
  twice.

  So it takes the ordinary route a developer would have written by hand — `JS.push/2` out,
  `handle_event/3` and `put_flash/3` back — and the words arrive in whatever flash component that
  site designed. `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` gives a page that carries the
  push the matching clause.

  ## The handler is runtime code, deliberately

  `handler/1` names `MishkaCmsCore.Runtime.PageMessage`, not this module. What it names is compiled
  into every published page that uses the action, and a visitor's page has no business naming
  anything under `MishkaCmsCore.Builder.*`. A package's server action should point at its own runtime
  module for the same reason.
  """
  use MishkaCmsCore.Builder.Action
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageMessage

  @key "say"

  @doc "The descriptor this module answers for."
  @spec descriptor() :: map()
  def descriptor do
    action(
      key: @key,
      label: gettext_noop("Show a message"),
      priority: 10,
      description:
        gettext_noop(
          "Shown where this site shows a flash, and gone a few seconds later. Like a form's own message, it needs the published page — the preview does not run a page's handlers."
        )
    )
  end

  @impl true
  def where(_action), do: :server

  @impl true
  def event(_action), do: PageMessage.event()

  @impl true
  def handler(_action), do: {PageMessage, :say}

  @impl true
  def needs(_action) do
    [
      text("message", gettext_noop("Message"),
        placeholder: gettext_noop("Thanks — we'll be in touch.")
      ),
      select("kind", gettext_noop("Style"), PageMessage.kinds())
    ]
  end

  @impl true
  def write(_action, _context, values) do
    kind = values["kind"]
    said = values |> Map.get("message") |> to_string() |> String.trim()

    case {kind in kinds(), said} do
      {false, _anything} -> nil
      {true, ""} -> nil
      {true, words} -> push(kind, words)
    end
  end

  @impl true
  def read(_action, {:push, [event], [value: %{"kind" => kind, "message" => message}]})
      when is_binary(kind) and is_binary(message),
      do: said(event == PageMessage.event(), kind, message)

  def read(_action, _command), do: :no

  defp said(true, kind, message), do: {:ok, %{"kind" => kind, "message" => message}}
  defp said(false, _kind, _message), do: :no

  defp push(kind, words),
    do: {:push, [PageMessage.event()], [value: %{"kind" => kind, "message" => words}]}

  defp kinds, do: Enum.map(PageMessage.kinds(), &elem(&1, 0))
end
