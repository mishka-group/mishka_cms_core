defmodule MishkaCmsCore.Runtime.States.RateLimitState do
  @moduledoc """
  Hammer's ETS table that signing in, the password reset request and the magic-link request are
  counted in: one row per key, whose window opens at the key's first hit and closes `per`
  milliseconds later. Start it before anything that can run those actions. See
  `MishkaCmsCore.Accounts.AuthRateLimit`.
  """
  use Hammer, backend: :ets, algorithm: :fix_window_per_key
end
