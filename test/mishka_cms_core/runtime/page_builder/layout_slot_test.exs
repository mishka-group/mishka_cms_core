# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.LayoutSlotTest do
  @moduledoc """
  A layout's one obligation, asked of the tree rather than of the text.

  The failure this exists to stop is silent in every direction: a layout with no `@inner_content`
  compiles, saves, previews and looks finished — and every page wrapped in it serves the layout's
  own chrome with the page missing. Nothing in the editor said so, so the question had to be asked
  somewhere, and asked well enough that neither answer is a lie.

  Both halves matter. A `false` that should be `true` refuses a publish the author is entitled to;
  a `true` that should be `false` is the original bug back again. So the cases here are the ones
  where a text search would get it wrong: the assign inside a string, inside a comment, spelled as
  a longer name, and the assign reached through `render_slot/1` or from inside a block.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.LayoutSlot
  alias MishkaCmsCore.Runtime.PageBuilder.Tree

  defp renders?(source), do: source |> Tree.parse!() |> LayoutSlot.renders_inner_content?()

  describe "a layout that renders the page" do
    test "the modern body form" do
      assert renders?("<main>{@inner_content}</main>")
    end

    test "the `<%= %>` form every seeded layout is written with" do
      assert renders?("<main><%= @inner_content %></main>")
    end

    test "reached through render_slot" do
      assert renders?("<main><%= render_slot(@inner_content) %></main>")
    end

    test "buried as deep as the document goes" do
      assert renders?("<body><div><section><p>{@inner_content}</p></section></div></body>")
    end

    # ADR-9 keeps a block atomic — its body is source, not child nodes — so this is the one shape a
    # walk of the tree cannot see on its own.
    test "inside a block, whose body the tree keeps as source" do
      assert renders?("<div><%= if @wrapped do %>{@inner_content}<% end %></div>")
    end

    test "handed to something else as an attribute" do
      assert renders?("<div><.frame body={@inner_content} /></div>")
    end

    test "in an expression that does more than name it" do
      assert renders?("<div>{@inner_content || @fallback}</div>")
    end
  end

  describe "a layout that does not" do
    test "nothing dynamic at all" do
      refute renders?("<body><nav>Site</nav><footer>Bye</footer></body>")
    end

    test "some other assign" do
      refute renders?("<main>{@content}</main>")
    end

    # The three a `String.contains?/2` would have called a pass.
    test "the words, written as words" do
      refute renders?("<p>Put @inner_content where the page should go.</p>")
    end

    test "the words, inside a comment" do
      refute renders?("<div><%!-- {@inner_content} --%></div>")
      refute renders?("<div><!-- {@inner_content} --></div>")
    end

    test "the words, inside a string the page prints" do
      refute renders?("<div>{\"@inner_content\"}</div>")
    end

    test "an assign whose name merely starts the same way" do
      refute renders?("<div>{@inner_content_slot}</div>")
    end

    test "an empty document" do
      refute renders?("")
    end
  end

  describe "a layout that holds it inside an element hidden from visitors" do
    test "does not render it, and still holds it" do
      for source <- [
            "<body><main data-pb-hidden>{@inner_content}</main></body>",
            "<body><div data-pb-hidden><main><%= @inner_content %></main></div></body>"
          ] do
        tree = Tree.parse!(source)

        refute LayoutSlot.renders_inner_content?(tree)
        assert LayoutSlot.holds_inner_content?(tree)
      end
    end

    test "renders it when only something beside it is hidden" do
      assert renders?("<body><nav data-pb-hidden>Site</nav><main>{@inner_content}</main></body>")
    end
  end

  test "the assign it asks about is the one the compiler supplies" do
    assert LayoutSlot.assign() == :inner_content
  end
end
