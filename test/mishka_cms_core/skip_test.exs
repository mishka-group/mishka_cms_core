# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.SkipTest do
  @moduledoc """
  `MishkaCmsCore.Skip`'s plain parts: the reason is kept trimmed and short or not at all, a mark
  names its actor, and a failure's key is its source and id. What a skip does to jobs, counts and
  notifications is in `MishkaCmsCoreWeb.Test.ActivitySkipTest`.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Skip

  doctest Skip

  test "a reason is cut to reason_max/0 characters and anything but text is none" do
    assert "x" |> String.duplicate(Skip.reason_max() + 50) |> Skip.reason() |> String.length() ==
             Skip.reason_max()

    assert Skip.reason(nil) == nil
    assert Skip.reason(42) == nil
  end

  test "a mark keeps who skipped, when and why" do
    assert %{skipped_at: %DateTime{}, skipped_by_id: "u-1", skip_reason: "late"} =
             Skip.mark(%{id: "u-1"}, " late ")

    assert %{skipped_by_id: nil, skip_reason: nil} = Skip.mark(nil, "")
    assert Skip.key("core:job", "42") == "core:job:42"
  end
end
