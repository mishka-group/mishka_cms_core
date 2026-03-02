defmodule MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  describe "classify_compile_error/1 — transient DB errors must never poison the cache" do
    test "DB/pool errors are transient (uncached, so the next request retries)" do
      db_error = struct(DBConnection.ConnectionError, message: "pool timeout")
      pg_error = struct(Postgrex.Error, message: "connection closed")

      assert ModuleCompilerHandler.classify_compile_error(db_error) == :compile_transient
      assert ModuleCompilerHandler.classify_compile_error(pg_error) == :compile_transient
    end

    test "a genuine template/compile error is a cacheable compilation_error" do
      assert ModuleCompilerHandler.classify_compile_error(%RuntimeError{message: "unclosed tag"}) ==
               {:compilation_error, "unclosed tag"}
    end

    test "an unknown exception falls back to cacheable (fail-safe, never transient)" do
      syntax = struct(SyntaxError, description: "syntax error", file: "nofile", line: 1)

      assert {:compilation_error, msg} = ModuleCompilerHandler.classify_compile_error(syntax)
      assert is_binary(msg)
    end
  end

  describe "compiled_result/1 — resolve from shared state, never call the worker" do
    test "a loaded module resolves to {:ok, module}" do
      assert ModuleCompilerHandler.compiled_result(__MODULE__) == {:ok, __MODULE__}
    end

    test "an unloaded module with a recorded failure resolves to that failure" do
      mod = :"Elixir.Mishka.Test.Unloaded.WithFailure#{System.unique_integer([:positive])}"
      CompileFailureState.record(mod, {:compilation_error, "broken"})
      on_exit(fn -> CompileFailureState.clear(mod) end)

      assert ModuleCompilerHandler.compiled_result(mod) ==
               {:error, {:compilation_error, "broken"}}
    end

    test "an unloaded module with no recorded failure resolves to a generic error" do
      mod = :"Elixir.Mishka.Test.Unloaded.NoFailure#{System.unique_integer([:positive])}"

      assert ModuleCompilerHandler.compiled_result(mod) == {:error, :compilation_error}
    end
  end
end
