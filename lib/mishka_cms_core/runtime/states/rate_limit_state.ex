# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.RateLimitState do
  @moduledoc """
  Hammer's ETS table that signing in, the password reset request and the magic-link request are
  counted in: one row per key, whose window opens at the key's first hit and closes `per`
  milliseconds later. Start it before anything that can run those actions. See
  `MishkaCmsCore.Accounts.AuthRateLimit`.
  """
  use Hammer, backend: :ets, algorithm: :fix_window_per_key
end
