# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.TenantSiteChangesTest do
  @moduledoc """
  The two changes that tie a record's `site_id` to the tenant an action runs under, used by the
  create actions of the layout, component, JavaScript hook, stylesheet, setting and notification
  resources, and by the master's update of the first four.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.Resources.Changes.{SiteFromTenant, TenantFromSite}

  @moduletag :unit

  @site "6f1a9d0e-3b1c-4c63-9a55-1d6a0c1b7e10"
  @other "0b7c2e44-8f5d-4f0a-a1de-3f39c2d6a9b2"

  defp changeset, do: Ash.Changeset.new(Layout)

  describe "SiteFromTenant" do
    test "writes the tenant into site_id, over a site that was sent" do
      sent = Ash.Changeset.force_change_attribute(changeset(), :site_id, @other)

      stamped = SiteFromTenant.change(sent, [], %{tenant: @site})

      assert Ash.Changeset.get_attribute(stamped, :site_id) == @site
    end

    test "leaves a master's changeset, which has no tenant, as it is" do
      sent = Ash.Changeset.force_change_attribute(changeset(), :site_id, @other)

      assert SiteFromTenant.change(sent, [], %{tenant: nil}) == sent
      assert Ash.Changeset.get_attribute(sent, :site_id) == @other
    end
  end

  describe "TenantFromSite" do
    test "runs the action under the tenant of the site the record names" do
      named = Ash.Changeset.force_change_attribute(changeset(), :site_id, @site)

      assert TenantFromSite.change(named, [], %{}).tenant == @site
    end

    test "leaves a global record, which names no site, without a tenant" do
      global = changeset()

      assert TenantFromSite.change(global, [], %{}) == global
      assert TenantFromSite.change(global, [], %{}).tenant == nil
    end
  end
end
