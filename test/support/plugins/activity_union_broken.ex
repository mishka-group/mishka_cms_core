# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ActivityUnionBroken do
  @moduledoc """
  Test plugin for `activity:sources`: a union source whose branch raises, so a test can see it
  cost its own rows and no other source's.
  """
  use MishkaCmsCore.ProviderRegistry, event: "activity:sources", priority: 60

  @behaviour MishkaCmsCore.Activity.Behaviours.UnionSource

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def id, do: "broken_probe"

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def union_branch(_read), do: raise(ArgumentError, "this branch is broken on purpose")

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def entry_from_row(_row), do: raise(ArgumentError, "a broken branch has no rows")
end
