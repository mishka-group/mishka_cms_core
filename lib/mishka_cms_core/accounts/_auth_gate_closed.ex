# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.AuthGate.Closed do
  @moduledoc """
  A way into an account that `MishkaCmsCore.Accounts.AuthGate` keeps closed: `:action` is the
  way — `:sign_in`, `:register`, `:reset` or `:magic_link` — and `:site_id` the site it was closed
  for (`nil` for a master's). Rendered by the JSON:API as a 403 `auth_closed` and by the sign-in
  pages as their own notice (see `MishkaCmsCore.Accounts.AuthGate.describe/1`).
  """

  use Splode.Error, fields: [:action, :site_id], class: :forbidden

  @type t :: %__MODULE__{}

  @impl true
  def message(%{action: action}), do: MishkaCmsCore.Accounts.AuthGate.describe(action).title
end
