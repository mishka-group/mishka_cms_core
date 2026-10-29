# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.Actions.OpenVerb do
  @moduledoc """
  Show, hide or toggle — and the component being aimed at decides what those mean.

  ## Why the component decides

  "Open it" is not one thing. A dialog is `display:none` on the root AND `display:none` again on the
  panel inside it, so revealing the root paints the backdrop over a page and shows no dialog. A
  drawer is fully displayed and held off-screen by `-translate-x-full`. A dropdown is opened by a
  JavaScript hook. A navbar wants one class toggled on the very element being clicked. One generic
  `JS.show` is right for exactly one of those shapes and silently does nothing for the rest — which
  is what it did, and what a full-page grey overlay with no dialog under it looked like.

  So the verb stays the author's and the command becomes the component's:

      <div id={@id} data-pb-open={show_modal(@id)} data-pb-close={hide_modal(@id)}>

  A click aimed at that compiles to `JS.exec("data-pb-open", to: ".pb-xxxxxxxx")`, so what runs is
  the component's own sequence — every transition, the body scroll lock, the focus trap. See
  `MishkaCmsBuilder.PaletteEntry.opens/1`; a package's component joins in by writing one
  attribute, with nothing registered anywhere.

  A component that declares nothing keeps the plain verb it always had.
  """
  use MishkaCmsCore.Builder.Action
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Builder.Action

  @verbs %{
    toggle: {gettext_noop("Show or hide"), 30},
    show: {gettext_noop("Show"), 31},
    hide: {gettext_noop("Hide"), 32}
  }

  @names Map.new(@verbs, fn {name, _label_and_priority} -> {Atom.to_string(name), name} end)

  @openers %{"show" => "data-pb-open", "hide" => "data-pb-close", "toggle" => "data-pb-toggle"}

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
                "The component decides what opening it means — its own transitions and all."
              )
          )
  end

  @doc "The attribute each verb looks for on a component that declares its own open command."
  @spec openers() :: %{String.t() => String.t()}
  def openers, do: @openers

  # A VERB THE TARGET CANNOT HONOUR IS WORSE THAN A MISSING VERB: it writes a command that runs, does
  # something visible, and is not what the author asked for. A component that says how it is opened
  # is taken at its word in BOTH directions — a modal declares open and close and is offered Show and
  # Hide; a navbar declares only a toggle and is offered only "Show or hide". A component that
  # declares nothing is offered all three, because there is no better guess to make.
  @impl true
  def offer?(action, context) do
    case context[:opener] || %{} do
      empty when map_size(empty) == 0 -> true
      opener -> Map.has_key?(opener, Action.key(action))
    end
  end

  @impl true
  def write(action, context, _values) do
    key = Action.key(action)
    opener = context[:opener] || %{}

    cond do
      declared?(opener, key) -> {:exec, [opener[key]], [to: Action.aim(context)]}
      # A TARGET THAT SPEAKS FOR ITSELF IS NOT SECOND-GUESSED. Falling through to the plain verb here
      # is what put a grey overlay over a page and no dialog under it. The panel does not offer the
      # verb; this is the backstop for a form rendered before it knew the target, and refusing is the
      # only honest answer left.
      map_size(opener) > 0 -> nil
      true -> {@names[key], [], [to: Action.aim(context)]}
    end
  end

  # `JS.exec("data-pb-open", …)` reads back as the verb the author picked, not as something
  # hand-written — otherwise setting "Show" on a dialog and reopening the panel said "this element
  # already has a hand-written phx-click" and offered no way to change it.
  @impl true
  def read(action, {:exec, [attribute], [to: _target]}) when is_binary(attribute),
    do: matched(@openers[Action.key(action)] == attribute)

  def read(action, {name, [], [to: _target]}) when is_atom(name),
    do: matched(Atom.to_string(name) == Action.key(action))

  def read(_action, _command), do: :no

  defp matched(true), do: {:ok, %{}}
  defp matched(_other), do: :no

  # ONLY THE ATTRIBUTES THIS MODULE NAMES. The map arrives from a component's own markup, which is
  # admin-authored but not this module's, and the value is about to be written into generated source
  # — so a verb answers only when what it answers with is one of the three declared above.
  defp declared?(opener, key),
    do: is_binary(@openers[key]) and Map.get(opener, key) == @openers[key]
end
