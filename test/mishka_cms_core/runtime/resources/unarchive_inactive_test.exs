# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.UnarchiveInactiveTest do
  @moduledoc """
  Unarchiving a runtime-compiled resource restores it as INACTIVE, so the runtime
  does not recompile it on unarchive — the user activates it explicitly when ready.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  defp archive_then_unarchive(record, site) do
    record
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
    |> Ash.destroy!(return_destroyed?: true)
    |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
    |> Ash.update!()
  end

  test "component unarchive restores as inactive" do
    site = create_site!()
    record = create_component!(site_id: site.id, active: true)
    assert record.active

    unarchived = archive_then_unarchive(record, site)
    assert is_nil(unarchived.archived_at)
    refute unarchived.active
  end

  test "page unarchive restores as inactive" do
    site = create_site!()
    record = create_page!(site_id: site.id, active: true)
    assert record.active

    unarchived = archive_then_unarchive(record, site)
    assert is_nil(unarchived.archived_at)
    refute unarchived.active
  end

  test "layout unarchive restores as inactive" do
    site = create_site!()
    record = create_layout!(site_id: site.id, active: true)
    assert record.active

    unarchived = archive_then_unarchive(record, site)
    assert is_nil(unarchived.archived_at)
    refute unarchived.active
  end

  test "error_page unarchive restores as inactive" do
    site = create_site!()
    record = create_error_page!(site_id: site.id, active: true)
    assert record.active

    unarchived = archive_then_unarchive(record, site)
    assert is_nil(unarchived.archived_at)
    refute unarchived.active
  end

  test "js_hook unarchive restores as inactive" do
    site = create_site!()
    record = create_js_hook!(site_id: site.id, active: true)
    assert record.active

    unarchived = archive_then_unarchive(record, site)
    assert is_nil(unarchived.archived_at)
    refute unarchived.active
  end
end
