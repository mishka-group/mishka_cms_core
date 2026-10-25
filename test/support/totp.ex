# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Totp do
  @moduledoc """
  An authenticator app's current code, for tests.

  A code is good for its 30-second period only (the strategy keeps no grace period), so one made
  in the last moment of a period has expired by the time the action checks it, and the test fails
  now and then. A code is therefore made with at least two seconds of its period left.
  """

  @period 30
  @margin 2

  @spec code(binary()) :: String.t()
  def code(secret) do
    left = @period - rem(System.os_time(:second), @period)
    if left <= @margin, do: Process.sleep(left * 1000)
    NimbleTOTP.verification_code(secret)
  end
end
