# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.PageStarter do
  @moduledoc """
  How a blank document begins — the few shapes offered on a page with nothing on it yet.

  ## Why this exists

  A page had to arrive with markup already in it. The "Add Page" form demanded a template before it
  would save, so the only way to reach the visual editor was to first write HEEx by hand — which is
  the one thing the visual editor is for not having to do. `blank/0` is what a page is created with
  instead: one centred container, wide enough to be a target, empty enough to be nothing.

  From there the canvas offers these structures. Picking one inserts it and the author is building.

  ## Why it is not called a layout

  Runtime already has Layouts: templates that wrap a page and declare which components they use.
  Borrowing the word here would mean two unrelated things called the same thing in the same editor.
  A **starter** is the first thing in an empty document and is thrown away the moment it is edited;
  a layout outlives every page that uses it.

  ## Why the structures are plain HTML

  Same reason as `MishkaCmsBuilder.Blocks`: a starter that reached for a kit
  component would fail on an install without that kit. Every structure here is `div` and utility
  classes, so it renders anywhere and every node inside it is an ordinary element the Inspector
  already knows how to style.

  These are deliberately emptier than Blocks. A block is a finished section with real copy in it; a
  starter is scaffolding — columns to drop things into, no words to delete first.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @type structure :: %{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          columns: pos_integer(),
          template: String.t()
        }

  # The container every page starts life with. `max-w-6xl mx-auto` is the "central empty container"
  # a new page needs to be usable as a drop target — a bare `<div></div>` collapses to nothing and
  # there is no way to aim at it.
  #
  # It also has to be at least three characters and non-blank, because `pages.template` is NOT NULL
  # with a `length(template) >= 3` check constraint. A truly empty string would fail at the database
  # rather than at the changeset.
  @blank ~s(<div class="mx-auto w-full max-w-6xl px-6 py-12"></div>)

  # A LAYOUT IS NOT A PAGE WITH NOTHING ON IT. Its whole job is to wrap one, and it does that through
  # `@inner_content` — a layout without it renders its own chrome and swallows every page that uses
  # it, which looks exactly like a broken site rather than an empty one. So the blank layout is the
  # same centred container with the slot already in it: the site renders from the first save, and
  # the author builds their header and footer around a chip that says where the page goes.
  @blank_layout ~s(<div class="mx-auto w-full max-w-6xl px-6 py-12"><%= @inner_content %></div>)

  # WHAT "FROM SCRATCH" LEAVES BEHIND. Not nothing: an empty document has no target to aim at, and
  # the reader who declined the four structures still has to be able to drop the first thing
  # somewhere. One `<main>` tall enough to hit is the smallest honest answer.
  @scratch ~s(<main class="min-h-[200px]"></main>)

  @doc "The one element a page started from scratch begins with."
  @spec scratch() :: String.t()
  def scratch, do: @scratch

  @doc """
  The markup a document is created with when the author gave none.

  One centred container — somewhere to put the first thing, and nothing else. A `:layout` gets the
  same container with `@inner_content` inside it, because a layout that does not render the page it
  wraps is not empty, it is broken.
  """
  @spec blank(:page | :layout) :: String.t()
  def blank(kind \\ :page)
  def blank(:layout), do: @blank_layout
  def blank(_page), do: @blank

  @columns %{
    2 =>
      ~s(<div class="min-h-[120px] rounded-lg border border-dashed border-slate-300 p-6"></div>),
    3 =>
      ~s(<div class="min-h-[120px] rounded-lg border border-dashed border-slate-300 p-6"></div>)
  }

  @structures [
    %{
      id: "single",
      title: gettext_noop("Single column"),
      description: gettext_noop("One wide band down the page."),
      columns: 1,
      template: ~s(<div class="mx-auto w-full max-w-6xl px-6 py-12">
  <div class="min-h-[160px] rounded-lg border border-dashed border-slate-300 p-6"></div>
</div>)
    },
    %{
      id: "two",
      title: gettext_noop("Two columns"),
      description: gettext_noop("A row that splits in half."),
      columns: 2,
      template: ~s(<div class="mx-auto w-full max-w-6xl px-6 py-12">
  <div class="grid grid-cols-2 gap-6 max-md:grid-cols-1">
    #{@columns[2]}
    #{@columns[2]}
  </div>
</div>)
    },
    %{
      id: "three",
      title: gettext_noop("Three columns"),
      description: gettext_noop("A row that splits in thirds."),
      columns: 3,
      template: ~s(<div class="mx-auto w-full max-w-6xl px-6 py-12">
  <div class="grid grid-cols-3 gap-6 max-lg:grid-cols-2 max-sm:grid-cols-1">
    #{@columns[3]}
    #{@columns[3]}
    #{@columns[3]}
  </div>
</div>)
    },
    %{
      id: "hero",
      title: gettext_noop("Hero + content"),
      description: gettext_noop("A band across the top, then the page."),
      columns: 1,
      template: ~s(<div class="w-full">
  <div class="w-full bg-slate-50 px-6 py-20">
    <div class="mx-auto min-h-[120px] w-full max-w-4xl text-center"></div>
  </div>
  <div class="mx-auto w-full max-w-6xl px-6 py-12">
    <div class="min-h-[160px] rounded-lg border border-dashed border-slate-300 p-6"></div>
  </div>
</div>)
    }
  ]

  @doc "Every starter structure, in the order the chooser lists them."
  @spec all() :: [structure()]
  def all, do: Enum.map(@structures, &translated/1)

  @doc "One structure by id, or `nil` — an unknown id is a no-op, never a crash."
  @spec fetch(String.t()) :: structure() | nil
  def fetch(id), do: @structures |> Enum.find(&(&1.id == id)) |> translated()

  defp translated(nil), do: nil

  defp translated(structure) do
    %{
      structure
      | title: Gettext.gettext(MishkaCmsCore.Gettext, structure.title),
        description: Gettext.gettext(MishkaCmsCore.Gettext, structure.description)
    }
  end

  @doc """
  Whether a document is empty enough to be offered a starter.

  Two ways to be empty, and both have to count:

    * nothing at all — a document whose content was removed;
    * ONE container with nothing in it — which is what a page created with no markup arrives as,
      because `pages.template` is NOT NULL with a length check and a truly empty string would fail
      at the database. A page whose only content is the container it was born with has not been
      started, whatever the row says.

  A page with anything else on it is a page someone is already working on, and dropping a chooser
  over it would be an interruption rather than a help.
  """
  @spec empty?(MishkaCmsCore.Runtime.Authoring.Tree.t() | nil) :: boolean()
  def empty?(%{roots: []}), do: true

  def empty?(%{roots: [id], nodes: nodes}) when is_map(nodes) do
    case Map.get(nodes, id) do
      %{kind: :tag, children: children} -> Enum.all?(children, &blank_child?(nodes, &1))
      _other -> false
    end
  end

  def empty?(_tree), do: false

  # Whitespace between tags parses into text nodes, so "no children" is not the same as an empty
  # list. A container holding nothing but the newline it was written with is still holding nothing.
  defp blank_child?(nodes, id) do
    case Map.get(nodes, id) do
      %{kind: :text, text: text} when is_binary(text) -> String.trim(text) == ""
      _other -> false
    end
  end
end
