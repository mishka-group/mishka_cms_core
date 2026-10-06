defmodule MishkaCmsCore.Builder.Actions.ClassVerb do
  @moduledoc """
  Toggle, add or remove a class — the three actions that compose with the element's own CSS.

  The class lands on the element the click points at, which is the same handle
  `MishkaCmsCore.Runtime.PageBuilder.ElementCss` keys a rule on. One identity, two features: toggle
  `is-open` here and write `&.is-open { … }` in the CSS box, and that is an accordion with no code in
  it.

  All three are client actions: `Phoenix.LiveView.JS` moves the class in the browser with no round
  trip, and the command survives a patch because it is part of what the server rendered.
  """
  use MishkaCmsCore.Builder.Action
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Builder.Action

  @verbs %{
    toggle_class: {gettext_noop("Toggle a class"), 20},
    add_class: {gettext_noop("Add a class"), 21},
    remove_class: {gettext_noop("Remove a class"), 22}
  }

  @names Map.new(@verbs, fn {name, _label_and_priority} -> {Atom.to_string(name), name} end)

  @doc "The three descriptors this module answers for."
  @spec descriptors() :: [map()]
  def descriptors do
    for {name, {label, priority}} <- @verbs,
        do:
          action(
            key: Atom.to_string(name),
            label: label,
            priority: priority,
            description:
              gettext_noop(
                "The class lands on this element, so a rule like &.is-open in Custom CSS is what styles it."
              )
          )
  end

  @impl true
  def needs(_action), do: [text("class", gettext_noop("Class"), placeholder: "is-open")]

  @impl true
  def write(action, context, values) do
    case class(values["class"]) do
      nil -> nil
      class -> {@names[Action.key(action)], [class], [to: Action.aim(context)]}
    end
  end

  @impl true
  def read(action, {name, [class], [to: _target]}) when is_atom(name) and is_binary(class),
    do: matched(Atom.to_string(name) == Action.key(action), class)

  def read(_action, _command), do: :no

  defp matched(true, class), do: {:ok, %{"class" => class}}
  defp matched(false, _class), do: :no

  # AN EMPTY BOX IS THE ONLY THING REFUSED HERE. The quote, the backslash and the hash used to be
  # stripped out of a class name, because the name was being interpolated into source by hand and
  # those three are what ends a string early or opens an interpolation inside one.
  # `MishkaCmsCore.Builder.Command` escapes it now, so the stripping only lost characters an author
  # had deliberately typed. Space-separated names are `Phoenix.LiveView.JS`'s own convention and are
  # passed through as written.
  defp class(nil), do: nil

  defp class(typed) do
    case typed |> to_string() |> String.trim() do
      "" -> nil
      names -> names
    end
  end
end
