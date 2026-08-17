defmodule MishkaCmsCore.Test.AiBackendStub do
  @moduledoc """
  An assistant backend whose answer the test writes, for exercising the ops seam end to end.

      Application.put_env(:mishka_cms_core, :builder_ai_backend, AiBackendStub)
      AiBackendStub.answer([%{kind: :insert, parent_id: nil, index: 0, template: "<figure></figure>"}])

  The answer lives in application env because `ask/3` runs in the LiveView's process, not the test's;
  a suite using this stub must not be `async: true`. Every call is posted back to the process that
  set the answer, which is how a test sees the `opts` the callback was handed.
  """
  @behaviour MishkaCmsCore.Runtime.PageBuilder.AiBackend

  @impl true
  def name, do: "Stub (test backend)"

  @impl true
  def ask(prompt, scope, opts) do
    answer = Application.fetch_env!(:mishka_cms_core, :test_ai_answer)
    send(Keyword.fetch!(answer, :watcher), {:asked, prompt, opts})

    # AN EDIT THAT LANDS WHILE THE MODEL IS THINKING. The canvas is its own process and does not stop
    # for the rail, so a test asks for one here — through the token `opts` now carries, which is the
    # same handle a backend writing its own ops would use.
    Enum.each(
      Keyword.fetch!(answer, :meanwhile),
      &MishkaCmsCore.Runtime.PageBuilder.EditorSession.apply_op(Keyword.fetch!(opts, :token), &1)
    )

    {:ok,
     %{
       role: :ai,
       text: "Done: #{prompt}",
       plain: "Edited the document.",
       scope: scope[:label],
       ops: Keyword.fetch!(answer, :ops)
     }}
  end

  @doc "The ops the next answer will carry, and the ops that land while it is being written."
  @spec answer([map()], [map()]) :: :ok
  def answer(ops, meanwhile \\ []),
    do:
      Application.put_env(:mishka_cms_core, :test_ai_answer,
        ops: ops,
        meanwhile: meanwhile,
        watcher: self()
      )
end
