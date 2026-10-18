# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.ActsOnRecordSiteTest do
  @moduledoc """
  The validation that keeps a version restore to the site whose record it restores, used by the
  layout, component and JavaScript hook resources.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.Resources.Validations.ActsOnRecordSite

  @moduletag :unit

  @site "6f1a9d0e-3b1c-4c63-9a55-1d6a0c1b7e10"
  @other "0b7c2e44-8f5d-4f0a-a1de-3f39c2d6a9b2"
  @opts [message: "not this site's"]

  defp validate(site_id, context) do
    changeset = Ash.Changeset.new(%Layout{site_id: site_id})
    ActsOnRecordSite.validate(changeset, @opts, context)
  end

  test "lets the system, which has no tenant, restore any record" do
    system = %{tenant: nil, actor: nil, authorize?: false}

    for site_id <- [nil, @site], do: assert(validate(site_id, system) == :ok)
  end

  test "refuses a call with no tenant and no actor that is not the system" do
    assert validate(nil, %{tenant: nil, actor: nil, authorize?: true}) ==
             {:error, message: "not this site's"}
  end

  test "lets the system restore a record of the site it names, and no other" do
    system = %{tenant: @site, actor: nil, authorize?: false}

    assert validate(@site, system) == :ok
    assert validate(@other, system) == {:error, message: "not this site's"}
    assert validate(nil, system) == {:error, message: "not this site's"}
  end

  test "is declared with its message" do
    assert {:ok, [message: "m"]} = ActsOnRecordSite.init(message: "m")
    assert {:error, _reason} = ActsOnRecordSite.init([])
  end
end
