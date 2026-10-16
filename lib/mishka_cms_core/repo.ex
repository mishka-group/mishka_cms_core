# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Repo do
  @moduledoc """
  The repo this library uses when it is developed and tested on its own.

  In a real deployment the host owns the database — the CMS points every resource at `MishkaCms.Repo`
  through `config :mishka_cms_core, repo: …`, and each extension does the same with its own. This
  module is what that setting points at when nothing else is around, so the suite has somewhere to
  write.

  `citext` is not optional: a user's `email` column is that type, so a repo without the extension
  cannot hold the accounts tables.
  """

  use AshPostgres.Repo, otp_app: :mishka_cms_core

  def min_pg_version, do: %Version{major: 16, minor: 9, patch: 0}

  def prefer_transaction?, do: false

  def installed_extensions, do: ["ash-functions", "citext"]
end
