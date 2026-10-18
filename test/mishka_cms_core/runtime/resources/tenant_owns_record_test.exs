# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.TenantOwnsRecordTest do
  @moduledoc """
  The validation that keeps a site to its own rows on the update and destroy actions of the layout,
  component, JavaScript hook and stylesheet resources.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantOwnsRecord

  @moduletag :unit

  @site "6f1a9d0e-3b1c-4c63-9a55-1d6a0c1b7e10"
  @other "0b7c2e44-8f5d-4f0a-a1de-3f39c2d6a9b2"
  @opts [global: "a global one", foreign: "another site's"]

  defp validate(site_id, tenant) do
    changeset = Ash.Changeset.new(%Layout{site_id: site_id})
    TenantOwnsRecord.validate(changeset, @opts, %{tenant: tenant})
  end

  test "refuses a global row to a site" do
    assert validate(nil, @site) == {:error, message: "a global one"}
  end

  test "refuses the row of another site to a site" do
    assert validate(@other, @site) == {:error, message: "another site's"}
  end

  test "lets a site change a row of its own" do
    assert validate(@site, @site) == :ok
  end

  test "lets a master, which has no tenant, change any row" do
    for site_id <- [nil, @site, @other], do: assert(validate(site_id, nil) == :ok)
  end

  test "is declared with both messages" do
    assert {:ok, [global: "g", foreign: "f"]} = TenantOwnsRecord.init(global: "g", foreign: "f")
    assert {:error, _reason} = TenantOwnsRecord.init(global: "g")
    assert {:error, _reason} = TenantOwnsRecord.init([])
  end
end
