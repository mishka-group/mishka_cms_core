# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SecondFactor.Needed do
  @moduledoc """
  A sign-in `MishkaCmsCore.Accounts.SecondFactor` refused: `:reason` is `:required` (no code was
  given), `:invalid` (the code did not match, or was used already) or `:password` (a way in that
  cannot ask for a code, such as a sign-in link). Rendered by the JSON:API as a 401
  `second_factor_<reason>` and by the sign-in page as its second step or its notice.
  """

  use Splode.Error, fields: [:reason], class: :forbidden

  @type t :: %__MODULE__{}

  @impl true
  def message(%{reason: reason}), do: MishkaCmsCore.Accounts.SecondFactor.describe(reason).title
end
