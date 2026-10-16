# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.ConditionsTest do
  @moduledoc """
  "Show when" — HEEx's own `:if`, chosen from a list instead of typed.

  ## What is pinned here

  That each choice writes an expression a real template can compile; that it survives the save
  round trip, which is parse → serialize → re-parse and therefore the place a condition would
  quietly stop being recognised; that a hand-written one is never rewritten; and — the one that
  would be silent in production — that every expression is safe on a surface that assigned none of
  the things it asks about.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Conditions
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Test.Plugins.BuilderConditionPlugin
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :unit

  defp values, do: Enum.map(Conditions.rules(), &elem(&1, 0))

  describe "the offered set" do
    test "every rule has a label and a stable order" do
      assert values() == ~w(signed_in signed_out said_ok said_problem)

      assert Enum.all?(Conditions.rules(), fn {_value, label} ->
               is_binary(label) and label != ""
             end)
    end

    test "and it writes into the attribute HEEx already has for the job" do
      assert Conditions.attribute() == ":if"
    end
  end

  describe "what it writes" do
    test "an expression for every rule" do
      for rule <- values() do
        assert is_binary(Conditions.source(rule)), "#{rule} writes nothing"
        assert {:ok, _ast} = Code.string_to_quoted(Conditions.source(rule))
      end
    end

    # "Always" is the attribute being taken off, not an expression that is always true — a template
    # carrying `:if={true}` is noise in somebody's markup and one more thing to explain.
    test "and nothing at all for Always" do
      assert Conditions.source("") == nil
      assert Conditions.source(nil) == nil
    end

    test "a rule nobody offers writes nothing" do
      assert Conditions.source("on_a_tuesday") == nil
      assert Conditions.source("current_user") == nil
    end
  end

  describe "reading it back" do
    test "each rule reads back as itself" do
      for rule <- values() do
        assert Conditions.read({:expr, Conditions.source(rule)}) == {:ok, rule}
      end
    end

    test "no attribute is no condition" do
      assert Conditions.read(nil) == :none
    end

    # THE CONTRACT THAT MATTERS, and the same one the click panel keeps: an expression the panel did
    # not write must be shown, not replaced.
    test "anything hand-written reads as custom" do
      customs = [
        {:expr, "@post.published?"},
        {:expr, "assigns[:current_user] && assigns[:current_user].admin?"},
        {:expr, "!assigns[:current_site]"},
        {:string, "true"},
        {:expr, "("},
        :boolean
      ]

      for value <- customs do
        assert Conditions.read(value) == :custom, "#{inspect(value)} was not treated as custom"
      end
    end

    # A DOCUMENT IS PARSED AND RE-SERIALIZED ON EVERY SAVE. Matching on bytes would mean one moved
    # space turned a condition this module wrote into one it refuses to touch — the panel would show
    # "hand-written" for its own work, and the author could never change their mind.
    test "whitespace is not the test" do
      assert Conditions.read({:expr, "assigns[ :current_user ]"}) == {:ok, "signed_in"}
      assert Conditions.read({:expr, "!  assigns[:current_user]"}) == {:ok, "signed_out"}
    end
  end

  describe "through the document" do
    test "a condition survives the save round trip" do
      for rule <- values() do
        {:ok, tree} = Tree.parse(~s(<div><p>Hi</p></div>))
        node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

        {:ok, tree} =
          Tree.set_attr(tree, node.id, Conditions.attribute(), {:expr, Conditions.source(rule)})

        {:ok, back} = tree |> Serializer.serialize() |> Tree.parse()
        written = back |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

        assert Conditions.read(Node.attr(written, Conditions.attribute())) == {:ok, rule},
               "#{rule} did not survive being saved"
      end
    end

    test "and Always leaves the markup with no trace of one" do
      {:ok, tree} = Tree.parse(~s(<div><p :if={assigns[:current_user]}>Hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      {:ok, tree} = Tree.delete_attr(tree, node.id, Conditions.attribute())

      refute Serializer.serialize(tree) =~ ":if"
    end
  end

  # THE FAILURE THAT WOULD BE SILENT. `@flash` raises `KeyError` where nothing assigned one, and the
  # same document is rendered by a page, a layout, an error page, a component preview and the canvas
  # — five callers, not all of which assign the same things. An author putting "show when signed in"
  # on a layout element would have taken the whole site down with a condition that reads correctly.
  describe "on a surface that assigned nothing" do
    test "every rule renders rather than raising" do
      for rule <- values() do
        html = LiveViewCompiler.render_template(marked(rule), %{})

        assert is_binary(html), "#{rule} did not render with no assigns: #{inspect(html)}"
      end
    end

    # AND ANSWERS NO, which is the answer that keeps a members-only block off a page nobody has
    # signed in to. "Visitor is signed out" is the one that is rightly true here, and it is the
    # reason this is a list rather than a loop over every rule.
    test "and the ones that ask for something answer no" do
      for rule <- ~w(signed_in said_ok said_problem) do
        refute LiveViewCompiler.render_template(marked(rule), %{}) =~ "Members only",
               "#{rule} was true with nothing assigned"
      end

      assert LiveViewCompiler.render_template(marked("signed_out"), %{}) =~ "Members only"
    end

    test "and says yes when the thing it asks about is there" do
      answers = [
        {"signed_in", %{current_user: %{id: "u1"}}},
        {"signed_out", %{}},
        {"said_ok", %{flash: %{"info" => "Saved!"}}},
        {"said_problem", %{flash: %{"error" => "Nope"}}}
      ]

      for {rule, assigns} <- answers do
        assert LiveViewCompiler.render_template(marked(rule), assigns) =~ "Members only",
               "#{rule} was false when it should have been true"
      end
    end
  end

  defp marked(rule), do: ~s(<div><p :if={#{Conditions.source(rule)}}>Members only</p></div>)

  # THE SAME DOOR THE ACTIONS USE, at the size this one needs. A condition is an expression, so a
  # contribution is the map that describes one — and `read/1` recognises it for free, because it
  # matches the quoted form of whatever is in the registry rather than a table of its own.
  describe "a plugin's rule" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BuilderConditionPlugin,
          event: "builder:conditions",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:conditions", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderConditionPlugin, false) end)
      :ok
    end

    test "joins the list the panel draws" do
      offered = Conditions.rules() |> Enum.map(&elem(&1, 0))

      assert "acme_member" in offered
      assert "signed_in" in offered, "core's own were replaced rather than added to"
    end

    test "writes its expression, and reads back as itself" do
      written = Conditions.source("acme_member")

      assert written == BuilderConditionPlugin.rule().source
      assert Conditions.read({:expr, written}) == {:ok, "acme_member"}
    end

    test "and cannot take a core rule, however it orders its answer" do
      assert Conditions.source("signed_in") == "assigns[:current_user]"
      refute Conditions.source("signed_in") == "false"
    end
  end
end
