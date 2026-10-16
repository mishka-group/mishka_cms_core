# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.CaptchaCheck.Refused do
  @moduledoc """
  A form sent without the captcha its site asks (`reason: :missing`) or with one that did not pass
  (`reason: :failed`): `:form` is the form — `:sign_in`, `:register`, `:reset_request`,
  `:magic_link`, or an extension's own — and `:site_id` its site (`nil` for a master's). Shown by the sign-in pages and the
  `/api/auth` routes as their own notice; see `MishkaCmsCore.Accounts.CaptchaCheck.describe/1`.
  """

  use Splode.Error, fields: [:reason, :form, :site_id], class: :invalid

  @type t :: %__MODULE__{}

  @impl true
  def message(%{reason: reason}), do: MishkaCmsCore.Accounts.CaptchaCheck.describe(reason).title
end
