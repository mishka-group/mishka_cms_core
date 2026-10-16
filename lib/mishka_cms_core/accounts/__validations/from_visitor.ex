# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Validations.FromVisitor do
  @moduledoc """
  Passes for an action a visitor's request runs, and fails for one run with `authorize?: false` —
  the installer, the seeds, the console. A `where:` condition, so a change meant for visitors leaves
  those alone:

      change AshRateLimiter.BuiltinChanges.rate_limit(...),
        where: [MishkaCmsCore.Accounts.Validations.FromVisitor]
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def validate(_changeset, _opts, %{authorize?: false}),
    do: {:error, message: dgettext_noop("errors", "run with authorize?: false")}

  def validate(_changeset, _opts, _context), do: :ok
end
