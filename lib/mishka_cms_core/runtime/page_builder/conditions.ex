# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Conditions do
  @moduledoc """
  When an element is on the page at all, without anyone writing Elixir.

  ## What it writes

  HEEx already has the feature: `:if={…}` is how a developer says it, and it is the one attribute
  every template in this project uses for the job. So there is nothing to invent — the panel offers a
  short list of questions a page can answer about itself, and each one writes the expression a
  developer would have written:

      <div :if={assigns[:current_user]}>

  Every kit builder in the field has this under some name; Elementor calls it Display Conditions.
  The difference here is that the answer is ordinary markup, so an author who later learns Elixir
  finds their own condition in Advanced rather than a setting stored somewhere else.

  ## Why `assigns[:key]` and not `@key`

  Because the same document is rendered on surfaces that do not all carry the same assigns. `@flash`
  raises `KeyError` where nothing assigned one, and a layout, an error page, a component preview and
  the canvas are each rendered by a different caller. `assigns[:key]` answers `nil` instead, which is
  the same answer as "no", and is the form the compiled templates in this project already use.

  It is also why a flash is read as `assigns[:flash]["info"]` rather than through `Phoenix.Flash`:
  `nil[key]` is `nil` in Elixir, so the whole chain is safe on a surface that assigned no flash at
  all, and `put_flash/3` stores under exactly those two string keys.

  ## Reading it back

  By matching the expression against what this module writes, never by matching text. Anything else
  — a condition somebody wrote by hand, one piped into something — reads as `:custom` and the panel
  shows it rather than offering to replace something it does not understand. Same contract
  `MishkaCmsCore.Runtime.PageBuilder.Interactions` keeps for a click.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Builder.Events

  @attribute ":if"

  @seed [
    %{
      key: "signed_in",
      label: gettext_noop("Visitor is signed in"),
      source: "assigns[:current_user]"
    },
    %{
      key: "signed_out",
      label: gettext_noop("Visitor is signed out"),
      source: "!assigns[:current_user]"
    },
    %{
      key: "said_ok",
      label: gettext_noop("A success message is showing"),
      source: ~S(assigns[:flash]["info"])
    },
    %{
      key: "said_problem",
      label: gettext_noop("A problem message is showing"),
      source: ~S(assigns[:flash]["error"])
    }
  ]

  @seed_labels Enum.map(@seed, & &1.label)

  @doc "The attribute a condition is written into."
  @spec attribute() :: String.t()
  def attribute, do: @attribute

  @doc "Core's own conditions, in panel order — the seed every plugin appends to."
  @spec seed() :: [map()]
  def seed, do: @seed

  @doc """
  Every condition offered, core's first and a plugin's after them.

  ## Why a plain map and not a behaviour

  Because a condition IS an expression. An action had to grow a module — it decides where it runs,
  what boxes to draw, what to write and how to read it back — and none of that has an answer here:
  a rule is a name and a piece of HEEx. So the entry is what it describes,

      %{key: "is_admin", label: "Visitor is an admin", source: "assigns[:current_user] && …"}

  and `read/1` recognises a contributed rule for free, because it matches the quoted form of
  whatever is in this list rather than a table of its own.

  Registered through `builder:conditions` exactly as every other registry — core seeded first, so a
  plugin adds and never replaces. See `MishkaCmsCore.Builder.Events`.
  """
  @spec registry() :: [map()]
  def registry, do: Events.collect_appended(:conditions, @seed)

  @doc "The conditions offered, as `{value, label}` in panel order."
  @spec rules() :: [{String.t(), String.t()}]
  def rules, do: Enum.map(registry(), &{&1.key, translate(&1.label)})

  defp translate(label) when label in @seed_labels,
    do: Gettext.gettext(MishkaCmsCore.Gettext, label)

  defp translate(label), do: label

  @doc """
  The expression source for one condition, or `nil` when there is nothing to write.

  `nil` for the empty rule — "Always", which is the absence of the attribute rather than an
  expression that is always true — and `nil` for a rule this module does not offer.
  """
  @spec source(String.t() | nil) :: String.t() | nil
  def source(rule) do
    Enum.find_value(registry(), fn
      %{key: ^rule, source: source} -> source
      _other -> nil
    end)
  end

  @doc """
  Reads an attribute value back into `{:ok, rule}`, `:none`, or `:custom`.

  `:custom` is the important one: the element carries a condition somebody wrote, and the panel must
  show it rather than replace it.
  """
  @spec read(term()) :: {:ok, String.t()} | :none | :custom
  def read(nil), do: :none

  def read({:expr, source}) do
    case Enum.find(registry(), &same?(&1.source, source)) do
      %{key: rule} -> {:ok, rule}
      nil -> :custom
    end
  end

  def read(_other), do: :custom

  # BY SHAPE, NOT BY BYTES. A document is parsed, serialized and re-parsed on every save, and a
  # formatter that moved one space would otherwise turn every condition this module wrote into one
  # it refuses to touch. Comparing the quoted forms asks the only question that matters: is this the
  # same expression?
  defp same?(written, source) do
    case {Code.string_to_quoted(written), Code.string_to_quoted(source)} do
      {{:ok, left}, {:ok, right}} -> strip(left) == strip(right)
      _unparseable -> false
    end
  end

  defp strip(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _meta -> [] end))
end
