defmodule MishkaCmsCore.Runtime.PageMessageTest do
  @moduledoc """
  "Show a message" — a click, a real flash, and the region the page already renders.

  ## What it is

  The one thing on the On-click list the client cannot do by itself. Six of the seven verbs are
  `Phoenix.LiveView.JS` commands that move classes and visibility around; a message is Phoenix's
  own flash, so this one takes the ordinary route — `JS.push/2` out, `handle_event/3` and
  `put_flash/3` back — and arrives in whatever flash component that site designed.

  ## What is pinned here

  The source it compiles to and the shape it reads back as, the two ways a forged push is refused,
  and that the generated source cannot be made to run anything.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageMessage

  @moduletag :unit

  @scope "pb-7f3a91b2"

  defp source(opts), do: Interactions.source("say", @scope, opts)

  defp expr(opts), do: {:expr, source(opts)}

  describe "what it writes" do
    test "a push carrying the kind and the words" do
      assert source(%{kind: "info", message: "Saved!"}) ==
               ~s|JS.push("pb:say", value: %{"kind" => "info", "message" => "Saved!"})|
    end

    test "and the other kind" do
      assert source(%{kind: "error", message: "That did not work."}) =~ ~s|"kind" => "error"|
    end

    test "the offered kinds are the ones a flash has" do
      assert PageMessage.kinds() == [{"info", "Success"}, {"error", "Problem"}]
    end

    # CLEARING IS A CHOICE; FAILING TO BUILD ONE IS NOT — the same contract the class actions keep.
    test "nothing to say writes nothing" do
      assert source(%{kind: "info", message: ""}) == nil
      assert source(%{kind: "info", message: "   "}) == nil
      assert source(%{kind: "info"}) == nil
    end

    test "a kind no flash has writes nothing" do
      assert source(%{kind: "warning", message: "Careful"}) == nil
      assert source(%{kind: nil, message: "Careful"}) == nil
    end

    test "it acts on the page, so it needs no target" do
      assert source(%{kind: "info", message: "Hi"}) ==
               Interactions.source("say", "pb-other", %{kind: "info", message: "Hi"})
    end

    test "and is offered whatever the click is aimed at" do
      declared = %{"show" => "data-pb-open"}
      offered = declared |> Interactions.actions() |> Enum.map(&elem(&1, 0))

      assert "say" in offered,
             "a dialog that declares its own opener must still be able to say something"
    end
  end

  # THE WORDS GO INTO GENERATED SOURCE. The attribute is written into the page template, which is
  # then compiled by `Phoenix.LiveView.TagEngine` — so a `#{}` in a message is not a curiosity, it is
  # code in somebody's page. `inspect/1` is what makes the literal, and this is the test that says so.
  describe "the words are data, not code" do
    test "an interpolation is written as characters" do
      said = "Order " <> <<35>> <> "{File.rm!(\"/tmp/x\")} placed"

      assert {:ok, _ast} = Code.string_to_quoted(source(%{kind: "info", message: said}))

      assert Interactions.read(expr(%{kind: "info", message: said})) ==
               {:ok, "say", %{"kind" => "info", "message" => said}}
    end

    test "a quote does not end the string early" do
      said = ~s(She said "yes" — twice)

      assert {:ok, _ast} = Code.string_to_quoted(source(%{kind: "info", message: said}))

      assert Interactions.read(expr(%{kind: "info", message: said})) ==
               {:ok, "say", %{"kind" => "info", "message" => said}}
    end

    test "a backslash survives as one" do
      said = ~S(C:\Users\me)

      assert Interactions.read(expr(%{kind: "error", message: said})) ==
               {:ok, "say", %{"kind" => "error", "message" => said}}
    end
  end

  describe "reading it back" do
    test "as the verb the author picked" do
      assert Interactions.read(expr(%{kind: "info", message: "Saved!"})) ==
               {:ok, "say", %{"kind" => "info", "message" => "Saved!"}}
    end

    test "with the kind and the words beside it" do
      assert Interactions.read(expr(%{kind: "error", message: "Nope"})) ==
               {:ok, "say", %{"kind" => "error", "message" => "Nope"}}
    end

    test "it points at nothing, because it acts on the page" do
      assert Interactions.target(expr(%{kind: "info", message: "Saved!"})) == nil
    end

    test "and anything hand-written stays hand-written" do
      assert Interactions.read({:expr, ~s|JS.push("pb:say", value: some_helper())|}) == :custom

      assert Interactions.read({:expr, ~s|JS.push("other", value: %{"kind" => "info"})|}) ==
               :custom

      assert Interactions.read({:string, "not an expression"}) == :custom
    end
  end

  describe "what the page does with the push" do
    setup do
      {:ok, socket: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}}
    end

    defp flashed(socket), do: socket.assigns.flash

    test "an ordinary message becomes a flash", %{socket: socket} do
      said = PageMessage.say(socket, %{"kind" => "info", "message" => "Saved!"})
      assert flashed(said) == %{"info" => "Saved!"}
    end

    test "and the two kinds are the two the region reads", %{socket: socket} do
      said = PageMessage.say(socket, %{"kind" => "error", "message" => "Nope"})

      assert MishkaCmsCore.Runtime.PageForm.announcements(flashed(said)) == [{:error, "Nope"}]
    end

    # A FORGED PUSH IS A REAL ONE. The words are the visitor's own to see and nobody else's, but the
    # kind picks a branch in somebody's markup, so that one is matched rather than trusted.
    test "a kind that is not a kind says nothing", %{socket: socket} do
      assert flashed(PageMessage.say(socket, %{"kind" => "warning", "message" => "Hi"})) == %{}
      assert flashed(PageMessage.say(socket, %{"kind" => 1, "message" => "Hi"})) == %{}
      assert flashed(PageMessage.say(socket, %{"message" => "Hi"})) == %{}
    end

    test "and neither does an empty one", %{socket: socket} do
      assert flashed(PageMessage.say(socket, %{"kind" => "info", "message" => "  "})) == %{}
      assert flashed(PageMessage.say(socket, %{"kind" => "info", "message" => 42})) == %{}
      assert flashed(PageMessage.say(socket, %{})) == %{}
    end

    test "a very long one is cut rather than refused", %{socket: socket} do
      said = PageMessage.say(socket, %{"kind" => "info", "message" => String.duplicate("a", 500)})

      assert String.length(flashed(said)["info"]) == 240
    end
  end
end
