defmodule MishkaCmsCore.Runtime.PageBuilder.CodeFlagsTest do
  @moduledoc """
  The one badge shown beside a handler, message clause or helper.

  Two things have to hold or the badge is worse than nothing: it must not cry wolf, because a warning
  that fires on a comment teaches people to ignore warnings; and it must be one, because a row of
  five labels on a screen that is mostly code is noise.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias MishkaCmsCore.Runtime.PageBuilder.CodeFlags

  describe "what earns a badge" do
    test "calls that reach outside the page" do
      assert CodeFlags.badge(~s|System.cmd("ls", [])|) == "runs a program"
      assert CodeFlags.badge(~s|Elixir.System.cmd("ls", [])|) == "runs a program"
      assert CodeFlags.badge(~s|:os.cmd(~c"ls")|) == "runs a program"
      assert CodeFlags.badge(~s|File.rm_rf!("/tmp/x")|) == "deletes files"
      assert CodeFlags.badge(~s|File.write!("x", "y")|) == "writes files"
      assert CodeFlags.badge(~s|Code.eval_string("1 + 1")|) == "evaluates code"
      assert CodeFlags.badge("Ash.destroy!(record)") == "deletes records"
    end

    # `apply/3` names nothing at all, which is exactly why it is worth pointing at.
    test "a call chosen at runtime" do
      assert CodeFlags.badge("apply(mod, fun, args)") == "calls a function chosen at runtime"
    end

    test "buried inside ordinary code, not only at the top" do
      code = """
      case socket.assigns.mode do
        :sweep -> System.cmd("rm", [])
        _other -> {:noreply, socket}
      end
      """

      assert CodeFlags.badge(code) == "runs a program"
    end

    # The walk used to raise on the first line, so nothing after it was ever read. A chain long
    # enough to outgrow an atom has to be read past as well, or giving up costs the snippet a badge.
    test "sitting next to a call this module cannot name" do
      long_chain = Enum.map_join(1..60, ".", &"Seg#{&1}")

      assert CodeFlags.badge(~s|__MODULE__.Helpers.run(1)\nSystem.cmd("ls", [])|) ==
               "runs a program"

      assert CodeFlags.badge(~s|#{long_chain}.f()\nSystem.cmd("ls", [])|) == "runs a program"
    end
  end

  # A WARNING THAT CRIES WOLF TEACHES PEOPLE TO IGNORE WARNINGS. This is the reason it reads the
  # parsed code rather than the text.
  describe "what does not" do
    test "ordinary handler and helper bodies" do
      assert CodeFlags.badge("{:noreply, assign(socket, :count, 1)}") == nil
      assert CodeFlags.badge("String.upcase(text)") == nil
      assert CodeFlags.badge("cents / 100") == nil
    end

    test "a mention in a comment or a string" do
      assert CodeFlags.badge("# System.cmd is not called here\n:ok") == nil
      assert CodeFlags.badge(~s|"System.cmd"|) == nil
      assert CodeFlags.badge(~s|Logger.info("about to File.rm_rf! nothing")|) == nil
    end

    test "half-typed code says nothing — CodeCheck is what reports that" do
      assert CodeFlags.badge("def do do do") == nil
      assert CodeFlags.badge(~s|"unterminated|) == nil
    end

    # THE LAST LINE OF DEFENCE, AND IT IS REACHABLE — do not read the rescue in `badge/1` as dead
    # code. The parser accepts an alias of 255 characters; `Elixir.` in front of it is past the limit
    # on an atom, so naming it raises.
    test "an alias too long to name" do
      assert CodeFlags.badge(String.duplicate("A", 249) <> ".f()") == nil
    end

    test "nothing at all" do
      assert CodeFlags.badge("") == nil
      assert CodeFlags.badge(nil) == nil
    end

    # A MODULE HELD IN A VARIABLE IS ORDINARY ELIXIR, and the alias chain of `__MODULE__.Helpers.run/1`
    # names no module at all. These raised here once, and the drawer renders this badge inline.
    test "a dotted call whose alias chain starts with a variable or __MODULE__" do
      assert CodeFlags.badge("__MODULE__.Helpers.run(1)") == nil
      assert CodeFlags.badge("mod.Foo.bar()") == nil
      assert CodeFlags.badge("repo.Query.all()") == nil
      assert CodeFlags.badge("@mod.X.y()") == nil
      assert CodeFlags.badge("__MODULE__.fun(1)") == nil
    end
  end

  # ONE badge, not a row of them.
  describe "only one" do
    test "several dangerous calls still give a single answer" do
      code = ~s|System.cmd("a", []); File.write!("b", "c"); Code.eval_string("d")|

      assert CodeFlags.badge(code) == "evaluates code"
    end

    test "and it is the most alarming one, not the first written" do
      assert CodeFlags.badge(~s|File.write!("a", "b"); System.cmd("c", [])|) == "runs a program"
    end
  end
end
