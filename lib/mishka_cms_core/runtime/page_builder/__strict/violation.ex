defmodule MishkaCmsCore.Runtime.PageBuilder.Strict.Violation do
  @moduledoc """
  Raised when the editor finds itself in a state that should not be reachable.

  Only ever raised in development and test — see `MishkaCmsCore.Runtime.PageBuilder.Strict`, which
  compiles every check out of a release. Meeting one is a bug in the editor, not a bad document and
  not something a reader did.
  """
  defexception [:message]
end
