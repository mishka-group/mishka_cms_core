defmodule MishkaCmsCore.Builder.Literal do
  @moduledoc """
  Quoted Elixir back into the term it stands for, when it stands for a term and nothing else.

  ## Why not `Code.eval_quoted/1`

  Because every caller here is holding something an author, or a package, or a database row supplied.
  Evaluating it would run it. This walks it instead: a map, a tuple, a list and the three scalar
  kinds resolve, and everything else — a call, a variable, an assign, an interpolation — answers
  `:error` and is left as the source text it always was.

  ## The two directions

  `term/1` is the exact inverse of `Macro.escape/1`, which is what makes `data?/1` a one-liner rather
  than a second allowlist kept in step with the first by hand. A value is data when escaping it and
  unescaping it gives it back — and that property is the same one `MishkaCmsCore.Builder.Command`
  relies on to print a term as source without an `Inspect` of its own.
  """

  @doc """
  The term a source string stands for, or `:error`.

      iex> MishkaCmsCore.Builder.Literal.value(~s|%{"kind" => :info}|)
      {:ok, %{"kind" => :info}}

      iex> MishkaCmsCore.Builder.Literal.value("@assign")
      :error
  """
  @spec value(String.t()) :: {:ok, term()} | :error
  def value(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      # A bare `nil` is an attribute that was written out rather than one carrying a value, and the
      # canvas has always treated the two differently.
      {:ok, nil} -> :error
      {:ok, quoted} -> term(quoted)
      _unparseable -> :error
    end
  end

  def value(_source), do: :error

  @doc """
  The term a quoted expression stands for, or `:error`.

  Quoted Elixir says what a thing is by its shape: a map is `{:%{}, meta, pairs}`, a tuple of any
  size but two is `{:{}, meta, items}`, a two-tuple is itself — and every OTHER three-element tuple
  is a call, a variable or an alias, which is precisely what must not resolve. Listing what is
  allowed rather than what is not is the only way round that stays right when a syntax is added.
  """
  @spec term(Macro.t()) :: {:ok, term()} | :error
  def term({:%{}, _meta, pairs}) when is_list(pairs) do
    # A map's entries are pairs and a map update — `%{map | key: value}` — is not a map literal at
    # all, so what is inside is checked before `Map.new/1` is asked to make sense of it.
    with true <- Enum.all?(pairs, &match?({_key, _value}, &1)),
         {:ok, resolved} <- term(pairs) do
      {:ok, Map.new(resolved)}
    else
      _not_a_map_literal -> :error
    end
  end

  def term({:{}, _meta, items}) when is_list(items) do
    with {:ok, resolved} <- term(items), do: {:ok, List.to_tuple(resolved)}
  end

  def term({left, right}) do
    with {:ok, [a, b]} <- term([left, right]), do: {:ok, {a, b}}
  end

  def term(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case term(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        :error -> {:halt, :error}
      end
    end)
  end

  def term(value) when is_binary(value) or is_number(value) or is_atom(value), do: {:ok, value}

  def term(_other), do: :error

  @doc """
  Whether a term is data a page can carry — no function, no pid, no reference.

  The check a writer needs before printing a term as source, and the trap it is guarding against is
  quiet: a three-element tuple like `{:foo, [], nil}` is a perfectly ordinary term AND a valid quoted
  variable, so printing it unescaped writes `foo` into somebody's page. Escaping first is what makes
  it print as a tuple; this says whether escaping it was enough.

      iex> MishkaCmsCore.Builder.Literal.data?(%{"a" => [1, {:b, "c"}]})
      true

      iex> MishkaCmsCore.Builder.Literal.data?(&String.trim/1)
      false
  """
  @spec data?(term()) :: boolean()
  def data?(value) do
    match?({:ok, ^value}, value |> Macro.escape() |> term())
  rescue
    # A reference is the one term `Macro.escape/1` raises on rather than answering about. It is not
    # data a page can carry either way, and the answer to that question is `false`, not a crash in
    # whatever was holding it.
    ArgumentError -> false
  end
end
