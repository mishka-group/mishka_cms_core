# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.ObanMigration do
  @moduledoc """
  Creates Oban's tables for the standalone test database.

  Oban's schema is not an Ash resource, so `mix ash.codegen` never emits it — and the migrations this
  extension does generate are a build artifact that is deliberately not committed. Rather than
  hand-write a migration into `priv/`, the harness runs this one at boot (`MishkaCmsCore.Test.Boot`),
  which keeps the generated-only rule intact and leaves nothing to check in.

  A host application supplies these tables itself; this exists only so the runtime workers this
  library owns have somewhere to enqueue while they are being tested on their own.
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end
