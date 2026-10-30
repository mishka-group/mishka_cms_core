# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.Command do
  @moduledoc """
  A `Phoenix.LiveView.JS` command as a term, printed to source and read back from it.

  ## Nothing is spelled by hand

  An action says what it wants as a triple — the command's name, its positional arguments, and its
  options — and every step after that belongs to somebody else's code:

    * `Phoenix.LiveView.JS` decides whether the options are legal. The triple is applied to it and
      the `%Phoenix.LiveView.JS{}` it answers with is thrown away; what is kept is that it answered
      at all. So `transition:`, `time:`, `display:` and `blocking:` are supported by this module
      knowing nothing about them, an option a later LiveView adds arrives supported, and the
      message an author sees for a wrong one is LiveView's own.
    * `Macro.escape/1` turns the terms into quoted Elixir, which is what gets a class name
      containing a double quote, a backslash or `\#{` right — the third being the one that is not a
      broken string but interpolation running in somebody's page.
    * The code formatter prints it, at infinite width so that one command is one line.
    * `Code.string_to_quoted/1` parses it back, and `MishkaCmsCore.Builder.Literal` unwraps the
      literals into the terms an action matches on.

  This is what replaced a private table of `~s|JS.\#{verb}("\#{class}", to: "\#{target}")|`. A string
  built that way has to be re-checked after the fact, because building it is where the mistake goes;
  a term printed by the formatter cannot have the mistake in it.

  ## Where the application happens

  In the editor, once, when an author presses Apply — `MishkaCmsCore.Runtime.Authoring.Interactions`
  calls this from the admin LiveView. What reaches a document is the printed source and only that,
  so nothing here is in a visitor's page, in the compiled module, or on the render path.

  ## What a page is allowed to contain

  A command names `JS` and carries data. That is the whole rule, and it is kept by construction
  rather than by inspection: an action hands over terms, `data?/1` refuses anything that is not data
  before it is escaped, and the source is built here. There is no path by which a package's text
  reaches a document.
  """

  alias MishkaCmsCore.Builder.Literal
  alias Phoenix.LiveView.JS

  @typedoc """
  One command: the `Phoenix.LiveView.JS` function name, its positional arguments, and its options.

      {:add_class, ["is-open"], [to: ".pb-7f3a91b2"]}
      {:push, ["pb:say"], [value: %{"kind" => "info", "message" => "Saved"}]}
      {:show, [], [to: ".pb-7f3a91b2", time: 300]}
  """
  @type t :: {atom(), [term()], keyword()}

  @doc """
  The source for one command, or for a pipe of them.

      iex> MishkaCmsCore.Builder.Command.write({:add_class, ["is-open"], [to: ".pb-1"]})
      {:ok, ~s|JS.add_class("is-open", to: ".pb-1")|}

      iex> MishkaCmsCore.Builder.Command.write({:show, [], [to: ".pb-1", speed: "fast"]})
      {:error, "invalid option for show\\nExpected keys to be one of [:to, :transition, :display, :time, :blocking], got: :speed\\n"}
  """
  @spec write(t() | [t()]) :: {:ok, String.t()} | {:error, String.t()}
  def write(commands) do
    case List.wrap(commands) do
      [] -> {:error, "there is no command here"}
      [_ | _] = list -> written(list, Enum.find_value(list, &refusal/1))
    end
  end

  defp written(_commands, why) when is_binary(why), do: {:error, why}

  defp written(commands, nil),
    do: {:ok, commands |> Enum.map(&quoted/1) |> piped() |> printed()}

  defp refusal({name, args, opts}) when is_atom(name) and is_list(args) and is_list(opts) do
    cond do
      # `__struct__/1` is exported, answers a `%JS{}` and is not a command. Nothing under `JS` that
      # a caller has any business naming begins with an underscore.
      String.starts_with?(Atom.to_string(name), "_") ->
        "#{name} is not a Phoenix.LiveView.JS command"

      not Literal.data?(args ++ [opts]) ->
        "#{name} was given something that is not data"

      true ->
        applied(name, args, opts)
    end
  end

  defp refusal(other),
    do: "#{inspect(other)} is not a {command, arguments, options} triple"

  # LIVEVIEW IS THE ONE THAT KNOWS. Every command validates its own option keys, and its message
  # names the ones it takes — so a list of them here would be a copy that goes stale on the next
  # LiveView release, silently, in the direction of refusing what is now legal.
  defp applied(name, args, opts) do
    case apply(JS, name, args ++ [opts]) do
      %JS{} -> nil
      _other -> "#{name} is not a Phoenix.LiveView.JS command"
    end
  rescue
    error -> Exception.message(error)
  end

  defp quoted({name, args, opts}) do
    {{:., [], [{:__aliases__, [], [:JS]}, name]}, [],
     args |> arguments(opts) |> Enum.map(&Macro.escape/1)}
  end

  # `JS.show([])` is what a command with nothing to say about itself would otherwise be printed as.
  defp arguments(args, []), do: args
  defp arguments(args, opts), do: args ++ [opts]

  defp piped([one]), do: one

  defp piped([first | rest]),
    do: Enum.reduce(rest, first, fn call, into -> {:|>, [], [into, call]} end)

  # ONE COMMAND IS ONE LINE. `Macro.to_string/1` is the formatter at its default width, which wraps a
  # command carrying a transition across four lines — correct Elixir, and a document attribute that
  # no longer reads as one expression to anyone opening it.
  defp printed(quoted) do
    quoted
    |> Code.quoted_to_algebra()
    |> Inspect.Algebra.format(:infinity)
    |> IO.iodata_to_binary()
  end

  @doc """
  The commands a source string holds, in the order they run, or `:no`.

  A pipe reads as a list; anything that is not `JS` calls carrying literal data reads as `:no` and
  belongs to whoever hand-wrote it.

      iex> MishkaCmsCore.Builder.Command.read(~s|JS.toggle_class("on", to: ".pb-1")|)
      {:ok, [{:toggle_class, ["on"], [to: ".pb-1"]}]}

      iex> MishkaCmsCore.Builder.Command.read(~s|JS.show(to: some_variable)|)
      :no
  """
  @spec read(String.t()) :: {:ok, [t()]} | :no
  def read(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, quoted} -> chained(quoted, [])
      {:error, _unparseable} -> :no
    end
  end

  def read(_source), do: :no

  # THE PIPED ARGUMENT IS NOT IN THE AST. `a |> JS.b(x)` quotes with `JS.b(x)` on the right and the
  # `%JS{}` inserted at expansion, so each side reads as the command it was written as.
  defp chained({:|>, _meta, [left, right]}, tail) do
    case one(right) do
      {:ok, command} -> chained(left, [command | tail])
      :no -> :no
    end
  end

  defp chained(quoted, tail) do
    case one(quoted) do
      {:ok, command} -> {:ok, [command | tail]}
      :no -> :no
    end
  end

  defp one({{:., _dot, [{:__aliases__, _alias, [:JS]}, name]}, _call, args}) when is_atom(name) do
    case Literal.term(args) do
      {:ok, terms} -> {:ok, split(name, terms)}
      :error -> :no
    end
  end

  defp one(_quoted), do: :no

  # THE OPTIONS ARE THE LAST ARGUMENT WHEN THERE ARE ANY. `JS.add_class("a b")` ends on the class it
  # adds, `JS.dispatch("e", detail: %{})` on a keyword list, and telling them apart is what keeps a
  # positional argument out of the options an action reads.
  defp split(name, terms) do
    case List.last(terms) do
      opts when is_list(opts) -> keyworded(name, terms, opts)
      _positional_or_nothing -> {name, terms, []}
    end
  end

  defp keyworded(name, terms, opts) do
    case Keyword.keyword?(opts) do
      true -> {name, Enum.drop(terms, -1), opts}
      false -> {name, terms, []}
    end
  end
end
