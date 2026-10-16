# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.CompileFailureState do
  @moduledoc """
  O(1) ETS record of runtime modules that failed to compile, keyed by module atom.

  Lets the compile hot path short-circuit a known-broken module — `failed?/1` is a
  pure `:ets.member` lookup, so a repeatedly-requested broken page is compiled once
  (and caught once) rather than recompiled-and-rescued on every request. A successful
  compile clears the entry; an `:update` recompile bypasses the cache and refreshes it.

  `{module, :offline}` is an Error Page whose `:offline` entry compiled but raised when it was drawn;
  the module stays loaded for its other entries.

  `{MishkaCmsCore.Runtime.JsHook, hook_id, bundle}` is a JS hook left out of a site's JavaScript
  bundle — see `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.left_out/1`.

  Read by `MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler`,
  `MishkaCmsCore.Runtime.RuntimeStatus` and `MishkaCmsWeb.ErrorHTML.offline_page/1`.
  """
  use GenServer

  @table :mishka_compile_failures

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record that `module` failed to compile, with its reason."
  def record(module, reason) do
    if table?(), do: :ets.insert(@table, {module, reason})
    :ok
  end

  @doc "Forget a module's failure (e.g. after it compiles cleanly)."
  def clear(module) do
    if table?(), do: :ets.delete(@table, module)
    :ok
  end

  @doc "Every recorded `{key, reason}` whose key matches `pattern`, an `:ets` match pattern."
  def matching(pattern) do
    case table?() do
      true -> :ets.match_object(@table, {pattern, :_})
      false -> []
    end
  end

  @doc "Forget every failure whose key matches `pattern`, an `:ets` match pattern."
  def clear_matching(pattern) do
    if table?(), do: :ets.match_delete(@table, {pattern, :_})
    :ok
  end

  @doc "Whether `module` is recorded as failed (fast hot-path check)."
  def failed?(module), do: table?() and :ets.member(@table, module)

  @doc "The recorded failure reason for `module`, or `nil`."
  def reason(module) do
    case table?() && :ets.lookup(@table, module) do
      [{^module, reason}] -> reason
      _ -> nil
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
