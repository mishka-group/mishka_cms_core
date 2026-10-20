# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SocialSignIn.Refused do
  @moduledoc """
  A sign-in with a provider that `MishkaCmsCore.Accounts.SocialSignIn` turned away: `:reason` is
  `:unverified_email` (the provider did not vouch for the email), `:no_account` (no account has it
  and the site makes none this way) or `:no_master` (no master has it). Told to the visitor by the
  sign-in page (see `MishkaCmsCore.Accounts.SocialSignIn.describe/1`).
  """

  use Splode.Error, fields: [:reason], class: :forbidden

  @type t :: %__MODULE__{}

  @impl true
  def message(%{reason: reason}), do: MishkaCmsCore.Accounts.SocialSignIn.describe(reason).title
end
