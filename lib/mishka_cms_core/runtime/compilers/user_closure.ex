# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.UserClosure do
  @moduledoc """
  Whether anything a page or a layout draws can read the signed-in user — the question that decides,
  once at compile time, whether serving that page has to load and verify one at all.

  `MishkaCmsWeb.RuntimeLive` used to be handed a finished `@current_user` on every mount, because
  the live session it is routed in loads one for every LiveView under it. For a signed-in visitor
  that is a token-row read and a user read on every page and every live navigation, and the great
  majority of database pages are brochure pages that never mention a visitor at all.

  So the compiler answers it instead, and the answer is baked into the record's own module:
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.build_assigns/1` writes it into
  `__page_information__/0` and
  `MishkaCmsCore.Runtime.Compilers.LayoutCompiler.build_layout_information/1` into
  `__layout_information__/0`, both under `private.reads_user`. A page whose own answer and whose
  layout's answer are both `false` is served without anything being looked up; every other page is
  served exactly as it was, by the same verification. A page that names permissions is judged by a
  user whatever this says — see `MishkaCmsWeb.RuntimeLive`'s `admit/3`, which asks for one before it
  asks this.

  ## One record at a time, which is what keeps the answer fresh

  A page and its layout are asked SEPARATELY and their answers are put together at request time,
  because a module is only ever rebuilt for its own record: editing a layout rebuilds the layout
  module and no page under it. An answer about somebody else's source, baked here, would go stale
  the moment that source changed — the layout would start reading the visitor and every page already
  compiled would go on saying nobody is signed in.

  Nothing else has to be asked, because a runtime component is handed ONLY the assigns its call site
  writes: `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` builds that map from the tag's own
  attributes, so a component's `assigns` holds `component_name`, `site` and whatever else the tag
  named, and nothing of the page's. A component can therefore reach the visitor in exactly two ways,
  and this module reads both off the record's own source:

    * the tag hands it something naming `current_user`, which is text in this record; or
    * the tag hands it the caller's WHOLE bag — `assigns`, or `@socket`, whose own `assigns` is the
      Phoenix.LiveView.Socket.AssignsNotInSocket struct holding that same map in `__assigns__`,
      and whose `private` holds the visitor's session besides.

  So the question never leaves the record being compiled, and the answer cannot be made wrong by
  editing anything else.

  ## Asked of the text, on purpose

  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.shows_messages?/1` asks its question of the
  PARSED template, because a wrong yes there is a visitor who is told nothing. Here the polarity is
  the other way round: a wrong yes costs two queries on one page, and a wrong no is a signed-in
  visitor shown a page that believes nobody is signed in. So this one looks for the name in every
  piece of source the record can reach and over-approximates deliberately — a page whose prose
  happens to contain `current_user` pays for a user it does not need, and nothing breaks.

  That also makes it indifferent to spelling, which matters here: `@current_user`,
  `assigns[:current_user]` — the form `MishkaCmsCore.Runtime.PageBuilder.Conditions` writes —
  `socket.assigns.current_user` in a handler and `@current_user` inside a helper's `~H` sigil are
  four shapes in three grammars, and the name is the only thing all of them share.

  ## What it reads

  Every field of the record that is markup or Elixir — template, body, helpers, events, infos, and
  the prelude, clauses and module attributes a component keeps in `extra`. The name is looked for in
  all of them, and all of them are scanned for `<.component …/>` tags, because a tag written inside
  a helper's `~H` sigil hands over exactly what one in the template does.

  ## Everything it cannot decide is a yes

  A tag that spreads a map of attributes, a template that cannot be tokenised, a record that is not
  there: each answers `true`. The one thing this must never do is answer `false` for a page that
  turns out to want a user.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.Markup

  @assign "current_user"

  # THE TWO NAMES THAT STAND FOR THE CALLER'S WHOLE ASSIGNS. `assigns` is the map itself, in scope in
  # every template and every `~H`; `@socket` carries the same map in `assigns.__assigns__`, and the
  # visitor's session besides. An argument that mentions either may be handing a component the bag.
  @carriers ["assigns", "socket"]

  # Everything a page, layout or component carries that is markup or Elixir. `extra` is in the list
  # because a component's prelude, extra clauses and module attributes live there and all three are
  # compiled into its module.
  @code_fields [:template, :body, :helpers, :events, :infos, :state, :extra]

  @doc """
  Whether anything `record` — a page or a layout — draws can read the signed-in user.

  `true` for anything it cannot work out, a `nil` record included.
  """
  @spec reads_user?(map() | nil) :: boolean()
  def reads_user?(nil), do: true

  def reads_user?(record) do
    sources = sources(record)

    names_user?(sources) or hands_assigns?(sources)
  end

  defp names_user?(sources), do: Enum.any?(sources, &String.contains?(&1, @assign))

  defp hands_assigns?(sources) do
    Enum.any?(sources, fn source ->
      case Markup.component_arguments(source) do
        {:ok, arguments} -> Enum.any?(arguments, &carries?/1)
        :dynamic -> true
      end
    end)
  end

  defp carries?(argument), do: Enum.any?(@carriers, &String.contains?(argument, &1))

  defp sources(record), do: record |> Map.take(@code_fields) |> strings()

  # Every string under those fields, however deeply it is nested: a helper is an embedded resource,
  # an event is a map, and `extra` is whatever an author or a kit put there.
  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(%_struct{} = value), do: value |> Map.from_struct() |> strings()
  defp strings(%{} = value), do: value |> Map.values() |> strings()
  defp strings(_value), do: []
end
