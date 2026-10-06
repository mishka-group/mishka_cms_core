defmodule MishkaCmsCore.Runtime.States.CompileFailureState do
  @moduledoc """
  O(1) ETS record of runtime modules that failed to compile, keyed by module atom.

  Lets the compile hot path short-circuit a known-broken module — `failed?/1` is a
  pure `:ets.member` lookup, so a repeatedly-requested broken page is compiled once
  (and caught once) rather than recompiled-and-rescued on every request. A successful
  compile clears the entry; an `:update` recompile bypasses the cache and refreshes it.

  `{module, :offline}` is an Error Page whose `:offline` entry compiled but raised when it was drawn;
  the module stays loaded for its other entries.

  Read by `MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler` and
  `MishkaCmsWeb.ErrorHTML.offline_page/1`.
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
