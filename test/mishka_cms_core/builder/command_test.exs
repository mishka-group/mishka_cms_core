defmodule MishkaCmsCore.Builder.CommandTest do
  @moduledoc """
  A `Phoenix.LiveView.JS` command goes out as terms and comes back as terms, and nobody spells Elixir.

  ## What was wrong

  Every action built its own source by interpolation — `~s|JS.\#{verb}("\#{class}", to: "\#{target}")|`
  — which put the quoting of an author's words in each action's hands, made an option like
  `transition:` something core would have to learn how to spell, and left reading it back a matter of
  matching raw quoted Elixir, `{:%{}, _meta, pairs}` and all.

  ## What is pinned here

  That the writing is `Macro.escape/1` and the formatter, that the reading is
  `Code.string_to_quoted/1` and `MishkaCmsCore.Builder.Literal`, and that the only thing standing
  between the two is LiveView's own opinion of the options it was handed.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.Command
  alias MishkaCmsCore.Builder.Literal

  @moduletag :unit

  describe "write/1" do
    test "prints one command on one line" do
      assert Command.write({:add_class, ["is-open"], [to: ".pb-1"]}) ==
               {:ok, ~s|JS.add_class("is-open", to: ".pb-1")|}
    end

    # A COMMAND WITH NOTHING TO SAY ABOUT ITSELF is not one carrying an empty list.
    test "and leaves the options off when there are none" do
      assert Command.write({:add_class, ["a b"], []}) == {:ok, ~s|JS.add_class("a b")|}
    end

    test "a list of them is a pipe" do
      assert Command.write([
               {:add_class, ["on"], [to: ".pb-1"]},
               {:remove_class, ["off"], [to: ".pb-1"]}
             ]) ==
               {:ok, ~S[JS.add_class("on", to: ".pb-1") |> JS.remove_class("off", to: ".pb-1")]}
    end

    # EVERY OPTION LIVEVIEW TAKES, WITHOUT CORE LEARNING ONE. A transition is a three-tuple of class
    # names and a time is an integer; neither needed a line of code here to become writable.
    test "an option core has never heard of is written because LiveView takes it" do
      command =
        {:show, [],
         [
           to: ".pb-1",
           time: 300,
           transition: {"ease-out duration-300", "opacity-0", "opacity-100"}
         ]}

      assert {:ok, source} = Command.write(command)

      assert source ==
               ~s|JS.show(to: ".pb-1", time: 300, transition: {"ease-out duration-300", "opacity-0", "opacity-100"})|
    end

    # AND LIVEVIEW IS THE ONE THAT SAYS NO, in its own words, naming the keys it does take. A list of
    # them kept here would go stale on the next release, silently, refusing what had become legal.
    test "an option it does not take is refused by LiveView, not by a list kept here" do
      assert {:error, why} = Command.write({:show, [], [to: ".pb-1", speed: "fast"]})

      assert why =~ "invalid option for show"
      assert why =~ "Expected keys to be one of [:to, :transition, :display, :time, :blocking]"
      assert why =~ "got: :speed"
    end

    test "a command that does not exist is refused" do
      assert {:error, why} = Command.write({:rm_rf!, ["/"], []})

      assert why =~ "Phoenix.LiveView.JS.rm_rf!"
    end

    # `__struct__/1` IS EXPORTED AND ANSWERS A `%JS{}`, so "did it give me back a JS struct" is not
    # on its own the whole gate.
    test "and so is the struct callback, which is not a command" do
      assert {:error, why} = Command.write({:__struct__, [], [ops: []]})

      assert why =~ "not a Phoenix.LiveView.JS command"
    end

    test "anything that is not a triple is refused rather than guessed at" do
      assert {:error, _why} = Command.write(~s|JS.show(to: ".pb-1")|)
      assert {:error, _why} = Command.write({:show, [], %{to: ".pb-1"}})
      assert {:error, _why} = Command.write(nil)
      assert {:error, _why} = Command.write([])
    end

    # A FUNCTION IS NOT DATA, and it is the one thing that can reach here now that nobody hands over
    # source: `Macro.escape/1` leaves it as it is and it would print as `#Function<…>`.
    test "and a command carrying something that is not data" do
      assert {:error, why} = Command.write({:push, ["save"], [value: &String.trim/1]})

      assert why =~ "not data"
    end

    # THE TRAP ESCAPING EXISTS FOR. `{:foo, [], nil}` is an ordinary term AND a quoted variable, so
    # printing it unescaped writes `foo` into somebody's page. Escaped, it is a tuple.
    test "a term that looks like a variable is written as the term it is" do
      assert {:ok, source} = Command.write({:push, ["save"], [value: %{"at" => {:foo, [], nil}}]})

      assert source == ~s|JS.push("save", value: %{"at" => {:foo, [], nil}})|

      assert {:ok, [{:push, ["save"], [value: %{"at" => {:foo, [], nil}}]}]} =
               Command.read(source)
    end

    # WHAT AN AUTHOR TYPES IS THEIRS, and the third of these is the one everybody forgets: getting it
    # wrong is not a broken string, it is interpolation running in somebody's page.
    test "a double quote, a backslash and an interpolation all survive being written" do
      said = ~S[she said "hi" \ and #{File.rm_rf!("/")}]

      assert {:ok, source} = Command.write({:push, ["pb:say"], [value: %{"message" => said}]})
      assert {:ok, [{:push, ["pb:say"], [value: %{"message" => ^said}]}]} = Command.read(source)
    end
  end

  describe "read/1" do
    test "what was written is what is read" do
      for command <- [
            {:toggle_class, ["on"], [to: ".pb-1"]},
            {:add_class, ["a b"], []},
            {:hide, [], [to: ".pb-1", transition: "fade-out"]},
            {:exec, ["data-pb-open"], [to: ".pb-1"]},
            {:push, ["pb:say"], [value: %{"kind" => "info", "message" => "Saved"}]},
            {:dispatch, ["acme:scroll"], [to: ".pb-1", detail: %{offset: "80"}]}
          ] do
        assert {:ok, source} = Command.write(command)
        assert Command.read(source) == {:ok, [command]}
      end
    end

    test "a pipe reads as the commands it is made of, in the order they run" do
      source =
        ~S[JS.add_class("on", to: ".pb-1") |> JS.push("pb:say", value: %{"kind" => "info"})]

      assert Command.read(source) ==
               {:ok,
                [
                  {:add_class, ["on"], [to: ".pb-1"]},
                  {:push, ["pb:say"], [value: %{"kind" => "info"}]}
                ]}
    end

    # NOTHING IS EVALUATED TO FIND OUT. Every one of these parses; not one of them carries only data,
    # so not one of them is a command this reads.
    test "anything carrying something that is not data is not a command" do
      for source <- [
            ~s|JS.push("save", value: File.rm_rf!("/tmp/x"))|,
            ~s|JS.show(to: System.cmd("sh", ["-c", "id"]))|,
            ~s|JS.push("a", value: %{"k" => Application.get_env(:x, :y)})|,
            ~s|JS.exec(some_variable, to: ".x")|,
            ~s|JS.show(to: @assign)|
          ] do
        assert Command.read(source) == :no, "#{source} was read as a command"
      end
    end

    test "and neither is anything that is not a JS call at all" do
      for source <- [
            ~s|File.rm_rf!("/")|,
            ~S[JS.show(to: ".x") |> File.rm_rf!("/")],
            ~s|JS.show(to: ".x") ; File.rm_rf!("/")|,
            "my_own_thing(@assigns)",
            "(",
            nil
          ] do
        assert Command.read(source) == :no, "#{inspect(source)} was read as a command"
      end
    end

    # THE OPTIONS ARE THE LAST ARGUMENT WHEN THERE ARE ANY, and a command ending on a positional one
    # must not have it read as options.
    test "a trailing positional argument is not mistaken for options" do
      assert Command.read(~s|JS.add_class("a b")|) == {:ok, [{:add_class, ["a b"], []}]}
      assert Command.read(~s|JS.push("save")|) == {:ok, [{:push, ["save"], []}]}
      assert Command.read("JS.focus_first()") == {:ok, [{:focus_first, [], []}]}
    end
  end

  describe "Literal.data?/1" do
    test "says yes to data and no to everything else" do
      assert Literal.data?(%{"a" => [1, {:b, "c"}, :d]})
      assert Literal.data?({"ease-out", "opacity-0", "opacity-100"})
      assert Literal.data?(to: ".x", time: 300)

      refute Literal.data?(&String.trim/1)
      refute Literal.data?(self())
      refute Literal.data?(make_ref())
    end
  end
end
