# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.MasterUpdateSiteTest do
  @moduledoc """
  A master's update of a site's record is recorded against that site.

  A master acts with no tenant, and AshPaperTrail writes the version row's `site_id` from the
  tenant alone: the version resource does not accept its multitenancy attribute, so the record's
  own `site_id` is dropped from the row. Every master edit of a site's layout, component, JS hook
  or stylesheet was then a "Global" entry in Activity, and missing from that site's own feed. The
  Studio's design tokens are the everyday case: a master writing a token of `localhost` writes the
  site's `studio-tokens` sheet through `:master_update`.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.VersionHelpers

  alias MishkaCmsCore.Activity.Sources.PaperTrail
  alias MishkaCmsCore.Runtime.{Component, JsHook, Layout, Stylesheet}

  require Ash.Query

  setup do
    %{site: create_site!(), master: create_user_with_permissions!(["*"], site_id: nil)}
  end

  # The record as a master's screen holds it: read back across sites, so it carries no tenant of
  # its own, which is what makes the master's update run with none.
  defp as_read(resource, id) do
    resource
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false, page: false)
  end

  defp master_update!(record, input, master) do
    record
    |> Ash.Changeset.for_update(:master_update, input, actor: master, tenant: nil)
    |> Ash.update!()
  end

  defp stylesheet!(site) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      %{name: "studio-tokens", kind: :theme, content: ":root {\n}\n", site_id: site.id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  test "a master's update of a site's stylesheet is that site's version", context do
    sheet = stylesheet!(context.site)

    Stylesheet
    |> as_read(sheet.id)
    |> master_update!(%{content: ":root {\n  --base-bg-dark: #5b21b6;\n}\n"}, context.master)

    version = latest_version(Stylesheet.Version, sheet.id)
    assert version.version_action_name == :master_update
    assert version.site_id == context.site.id
  end

  test "and Activity files it under that site, not as Global", context do
    sheet = stylesheet!(context.site)

    Stylesheet
    |> as_read(sheet.id)
    |> master_update!(%{content: ":root {\n  --base-bg-dark: #18181b;\n}\n"}, context.master)

    entries =
      %{current_user: context.master, resources: [Stylesheet]}
      |> PaperTrail.initial_fetch(20)
      |> Enum.filter(&(&1.source_id == sheet.id and &1.action == :master_update))

    assert [%{site_id: site_id}] = entries
    assert site_id == context.site.id
  end

  test "the same for a layout, a component and a JS hook", context do
    site = context.site

    for {resource, record, input} <- [
          {Layout, create_layout!(site_id: site.id), %{description: "Edited by a master"}},
          {Component, create_component!(site_id: site.id), %{description: "Edited by a master"}},
          {JsHook, create_js_hook!(site_id: site.id), %{description: "Edited by a master"}}
        ] do
      resource |> as_read(record.id) |> master_update!(input, context.master)

      version = latest_version(Module.concat(resource, Version), record.id)
      assert version.version_action_name == :master_update, inspect(resource)
      assert version.site_id == site.id, "#{inspect(resource)}: recorded as Global"
    end
  end

  # A move is recorded where the record went: the site it names once the update has run.
  test "a stylesheet a master moves is recorded on the site it moved to", context do
    sheet = stylesheet!(context.site)
    other = create_site!()

    moved =
      Stylesheet |> as_read(sheet.id) |> master_update!(%{site_id: other.id}, context.master)

    assert moved.site_id == other.id
    assert latest_version(Stylesheet.Version, sheet.id).site_id == other.id
  end

  test "a shared record stays shared", context do
    sheet =
      Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{name: "shared-theme", kind: :theme, content: ":root {\n}\n"},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    Stylesheet
    |> as_read(sheet.id)
    |> master_update!(%{content: ":root {\n  --x: 1px;\n}\n"}, context.master)

    assert latest_version(Stylesheet.Version, sheet.id).site_id == nil
  end
end
