# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.CodeFlags do
  @moduledoc """
  One short warning for a snippet that calls something worth reading twice.

  Drawn as a single badge beside the handler, message clause or helper it belongs to, in the Code
  window the author is already looking at. There is deliberately no second screen for this: the
  editor shows a document's code, so the warning belongs next to the code and not in a report
  somewhere else.

  ## Triage, not a verdict

  A snippet with no badge is **not** thereby safe. Everything matched here can be spelled another way
  — `apply(mod, fun, args)`, a module in a variable — so the badge answers "read this one first",
  never "the rest are fine". The resource's policies and `CodeAccess`'s deployment switch decide who
  may write code at all; this only points.

  ## Read off the parsed code, not the text

  A pattern over the source would flag a mention in a comment or inside a string, which costs somebody
  ten minutes for nothing:

      # System.cmd is not called here     -> no badge
      "System.cmd"                        -> no badge
      System.cmd("ls", [])                -> badge

  One badge per snippet: the most alarming thing it does is the thing that gets someone to look, and
  a row of five labels is noise on a screen that is mostly code.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @runtime_call gettext_noop("calls a function chosen at runtime")

  # Ordered — the first match is the one shown, so the entries read worst-first.
  @watched [
    {{Code, :eval_string}, gettext_noop("evaluates code")},
    {{Code, :eval_quoted}, gettext_noop("evaluates code")},
    {{System, :cmd}, gettext_noop("runs a program")},
    {{System, :shell}, gettext_noop("runs a shell")},
    {{:os, :cmd}, gettext_noop("runs a program")},
    {{:erlang, :halt}, gettext_noop("stops the node")},
    {{Node, :spawn}, gettext_noop("runs code on another node")},
    {{File, :rm_rf!}, gettext_noop("deletes files")},
    {{File, :rm!}, gettext_noop("deletes files")},
    {{Ash, :destroy!}, gettext_noop("deletes records")},
    {{Ash, :bulk_destroy!}, gettext_noop("deletes records")},
    {{File, :write!}, gettext_noop("writes files")},
    {{File, :write}, gettext_noop("writes files")}
  ]

  @doc """
  The one warning for this snippet, or `nil` when there is nothing to say.

  Unparseable code answers `nil` rather than a warning of its own: the author is mid-sentence in a
  box they are typing into, and `CodeCheck` is what tells them the code will not compile.
  """
  @spec badge(String.t() | nil) :: String.t() | nil
  def badge(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> ast |> first_flag() |> translate()
      {:error, _half_typed} -> nil
    end
  rescue
    # TRIAGE, NOT A VERDICT — and the Code drawer renders this inline, twice per entry. Code this
    # module cannot read costs its author a badge; it must never cost them the window they are
    # looking at. The reachable case is an alias the parser accepts and `Module.concat/1` cannot
    # name: `Elixir.` in front of 249 characters is past the limit on an atom.
    _unreadable -> nil
  end

  def badge(_code), do: nil

  # Worst-first, and `apply/3` is on the end of this list rather than in `@watched` — it is not a
  # module-and-function pair, so it has no entry there and would otherwise be found and then never
  # chosen.
  @priority Enum.map(@watched, fn {_call, label} -> label end) ++ [@runtime_call]

  defp translate(nil), do: nil
  defp translate(label), do: Gettext.gettext(MishkaCmsCore.Gettext, label)

  defp first_flag(ast) do
    {_ast, found} = Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ watched(node)} end)

    Enum.find(@priority, &(&1 in found))
  end

  defp watched({{:., _meta, [{:__aliases__, _alias_meta, segments}, fun]}, _call_meta, _args}),
    do: segments |> named() |> label(fun)

  defp watched({{:., _meta, [module, fun]}, _call_meta, _args}) when is_atom(module),
    do: label(module, fun)

  # `apply/3` names nothing at all, which is the point of flagging it.
  defp watched({:apply, _meta, args}) when length(args) in [2, 3],
    do: [@runtime_call]

  defp watched(_node), do: []

  # `__MODULE__.Helpers.run(1)` and `mod.Foo.bar()` quote a variable at the head of the alias chain,
  # so it names no module at all. Every module worth a badge is a single segment, which `Elixir.` may
  # lead; joining a longer chain would only build a name no entry can match, and a long enough one
  # outgrows the atom table. Reading past it leaves a later line the badge it earned.
  defp named([Elixir, segment]), do: named([segment])
  defp named([segment]) when is_atom(segment), do: existing(segment)
  defp named(_segments), do: nil

  # `@watched` holds atoms that exist, so a name with no atom of its own is not one of them and is
  # left alone rather than made.
  defp existing(segment) do
    Module.safe_concat([segment])
  rescue
    ArgumentError -> nil
  end

  defp label(module, fun) do
    case List.keyfind(@watched, {module, fun}, 0) do
      {_call, label} -> [label]
      nil -> []
    end
  end
end
