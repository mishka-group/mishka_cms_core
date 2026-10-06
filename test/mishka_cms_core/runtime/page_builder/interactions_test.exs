defmodule MishkaCmsCore.Runtime.PageBuilder.InteractionsTest do
  @moduledoc """
  What an element does when clicked, expressed as a LiveView JS command rather than a script — and
  read back by matching the expression's shape, so anything hand-written is recognised as such and
  left alone.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions

  # WHATEVER THE VERB NEEDS, so a loop over the whole set asks each one for what it takes: a class
  # for the three that move classes, words for the one that says something, neither for the rest.
  defp everything, do: %{class: "c", kind: "info", message: "Saved!"}

  describe "source/3" do
    test "an action that needs a class gets one" do
      assert Interactions.source("toggle_class", "pb-11112222", %{class: "is-open"}) ==
               ~s|JS.toggle_class("is-open", to: ".pb-11112222")|
    end

    test "an action that does not, does not" do
      assert Interactions.source("hide", "pb-11112222") == ~s|JS.hide(to: ".pb-11112222")|
      assert Interactions.source("toggle", "pb-11112222") == ~s|JS.toggle(to: ".pb-11112222")|
    end

    test "a class-taking action with no class writes nothing rather than a broken command" do
      assert Interactions.source("toggle_class", "pb-11112222", %{class: ""}) == nil
      assert Interactions.source("add_class", "pb-11112222", %{}) == nil
    end

    test "an action nobody offers writes nothing" do
      assert Interactions.source("exec", "pb-11112222") == nil
      assert Interactions.source("push", "pb-11112222", %{class: "x"}) == nil
    end

    test "without a scope there is nothing to point at" do
      assert Interactions.source("hide", nil) == nil
      assert Interactions.source("hide", "") == nil
    end

    # NOT BY TAKING CHARACTERS OUT OF WHAT WAS TYPED. The class used to be interpolated into source
    # here, so the quote and the backslash had to be stripped from an author's box; the source is
    # built from terms now, so the same input is written out whole and read back as itself.
    test "a class that would break out of its own quotes is written as typed, and cannot" do
      class = ~S[a" <> System.halt() <> "]
      source = Interactions.source("add_class", "pb-11112222", %{class: class})

      assert source == ~S|JS.add_class("a\" <> System.halt() <> \"", to: ".pb-11112222")|
      assert Interactions.read({:expr, source}) == {:ok, "add_class", %{"class" => class}}
    end
  end

  describe "read/1" do
    test "what this module wrote, it reads" do
      for {action, class} <- [{"toggle_class", "is-open"}, {"add_class", "on"}] do
        source = Interactions.source(action, "pb-11112222", %{class: class})
        assert Interactions.read({:expr, source}) == {:ok, action, %{"class" => class}}
      end

      for action <- ~w(toggle show hide) do
        source = Interactions.source(action, "pb-11112222")
        assert Interactions.read({:expr, source}) == {:ok, action, %{}}
      end
    end

    test "nothing set reads as nothing" do
      assert Interactions.read(nil) == :none
    end

    # THE CONTRACT THAT MATTERS. An expression the panel did not write must be shown, not rewritten.
    test "anything hand-written reads as custom" do
      customs = [
        {:expr, ~S{JS.toggle_class("a", to: ".x") |> JS.push("save")}},
        {:expr, ~s|JS.dispatch("phx:open")|},
        {:expr, "my_own_thing(@assigns)"},
        {:expr, "JS.exec(\"data-cancel\", to: \".x\")"},
        {:string, "save"},
        {:expr, "("}
      ]

      for value <- customs do
        assert Interactions.read(value) == :custom, "#{inspect(value)} was not treated as custom"
      end
    end

    # A command this module offers, written by hand with a target it did not choose, is still its
    # shape — the panel can show it and the author can change it.
    test "a recognised command aimed elsewhere is still recognised" do
      assert Interactions.read({:expr, ~s|JS.hide(to: "#other")|}) == {:ok, "hide", %{}}
    end
  end

  describe "the offered set" do
    test "every action has a label and a stable order" do
      actions = Interactions.actions()

      assert Enum.map(actions, &elem(&1, 0)) ==
               ~w(say toggle_class add_class remove_class toggle show hide)

      assert Enum.all?(actions, fn {_value, label} -> is_binary(label) and label != "" end)
    end

    test "class?/1 agrees with what source/3 requires" do
      for {action, _label} <- Interactions.actions() do
        written = Interactions.source(action, "pb-11112222", everything())

        assert is_binary(written)
        assert Interactions.class?(action) == String.contains?(written, ~s|"c"|)
      end
    end

    test "server?/1 names the ones that reach the server" do
      for {action, _label} <- Interactions.actions() do
        written = Interactions.source(action, "pb-11112222", everything())

        assert Interactions.server?(action) == String.contains?(written, "JS.push")
      end
    end
  end

  # THE COMMONEST THING ANYBODY WANTS A BUTTON FOR is to open something ELSE, and until this the
  # editor could not express it: `to:` was pinned to the element being clicked, so a button could
  # show and hide itself and nothing beside it. A modal, a drawer and twelve more render their own
  # content closed, which means "open that dialog" was not a sentence an author could say — a
  # developer writes `phx-click={show_modal("id")}` and thinks nothing of it.
  describe "pointing an action at another element" do
    test "writes the target's scope, not the element's own" do
      assert Interactions.source("show", "pb-11112222", %{target: "pb-33334444"}) ==
               ~s|JS.show(to: ".pb-33334444")|

      assert Interactions.source("toggle_class", "pb-11112222", %{
               class: "is-open",
               target: "pb-33334444"
             }) ==
               ~s|JS.toggle_class("is-open", to: ".pb-33334444")|
    end

    # THE OLD CALL HAS TO KEEP MEANING WHAT IT MEANT. Every interaction saved before this one was
    # written by `source/3`, and a fourth argument that changed the three-argument answer would
    # rewrite them all on the next save.
    test "and falls back to the element's own when there is no target" do
      own = Interactions.source("show", "pb-11112222")

      assert own == ~s|JS.show(to: ".pb-11112222")|
      assert Interactions.source("show", "pb-11112222", %{}) == own
      assert Interactions.source("show", "pb-11112222", %{target: ""}) == own
      assert Interactions.source("show", "pb-11112222", %{target: "   "}) == own
    end

    test "reads the target back, so the panel can show what was chosen" do
      written = Interactions.source("show", "pb-11112222", %{target: "pb-33334444"})

      assert Interactions.target({:expr, written}) == "pb-33334444"

      assert Interactions.target({:expr, Interactions.source("show", "pb-11112222")}) ==
               "pb-11112222"

      assert Interactions.target(
               {:expr, Interactions.source("add_class", "pb-1", %{class: "c", target: "pb-2"})}
             ) ==
               "pb-2"
    end

    test "and answers nothing for an expression it did not write" do
      assert Interactions.target(nil) == nil
      assert Interactions.target({:string, "alert('hi')"}) == nil
      assert Interactions.target({:expr, "JS.show(to: \"#some-id\")"}) == nil
      assert Interactions.target({:expr, "something_else(to: \".pb-1\")"}) == nil
      assert Interactions.target({:expr, "this is not elixir ("}) == nil
    end

    # A target changes WHERE the action lands and nothing else, so `read/1` must keep answering the
    # same action and class — the panel reads the two apart and would otherwise call a targeted
    # interaction hand-written and refuse to touch it.
    test "a targeted action still reads back as the action it is" do
      written =
        Interactions.source("toggle_class", "pb-11112222", %{
          class: "is-open",
          target: "pb-33334444"
        })

      assert Interactions.read({:expr, written}) == {:ok, "toggle_class", %{"class" => "is-open"}}
    end

    # EVERY ACTION THAT LANDS ON AN ELEMENT. "Show a message" acts on the page — it puts a flash on
    # the socket — so there is nothing for it to be aimed at, which `target/1` says by answering nil.
    test "every action can be aimed somewhere else" do
      for {action, _label} <- Interactions.actions(), not Interactions.server?(action) do
        written = Interactions.source(action, "pb-11112222", %{class: "c", target: "pb-33334444"})

        assert is_binary(written), "#{action} cannot be aimed"
        assert Interactions.target({:expr, written}) == "pb-33334444"
      end
    end
  end

  # WHAT THIS MODULE WRITES HAS TO BE RENDERABLE WHERE THE AUTHOR LOOKS. `source/3` emits
  # `JS.toggle_class(…)` — a bare alias, which a compiled page has because `use <web module>,
  # :live_view` folds in `alias Phoenix.LiveView.JS`. `LiveViewCompiler.render_template/2` built its
  # environment out of that module's own `__ENV__`, which has every import a page gets and none of
  # its aliases, so the one thing the Interactions panel produces could not be evaluated on the two
  # surfaces that go through it — the component preview and the Examples tab:
  #
  #     ** (UndefinedFunctionError) function JS.toggle_class/2 is undefined (module JS is not
  #        available)
  #
  # The page it was written on rendered it perfectly. Only the places an author checks their work
  # could not.
  describe "what it writes renders where the author checks it" do
    test "every action survives the runtime template renderer" do
      for {action, _label} <- Interactions.actions() do
        source = Interactions.source(action, "pb-11112222", everything())

        html =
          LiveViewCompiler.render_template(~s|<button phx-click={#{source}}>go</button>|, %{})

        assert is_binary(html),
               "#{action} cannot be rendered by the preview: #{inspect(html)}"

        assert html =~ "phx-click", "#{action} rendered without its command: #{html}"
      end
    end
  end
end
