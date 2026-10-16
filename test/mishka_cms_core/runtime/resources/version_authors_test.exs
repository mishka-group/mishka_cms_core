# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.VersionAuthorsTest do
  @moduledoc """
  Who wrote each version of every runtime record, as its versioned reads load it.

  A site user reads a record's versions through `:get_with_versions` under its own site, a master
  through `:master_get_with_versions`: the reads behind the inspector's Versions tab and "Modified
  By" row, and the `/:id/with-versions` routes. Each version carries its author as that reader may
  see it, and `MishkaCmsCoreWeb.Templates.VersionHistory.author/2` names it. A master reads every
  author's email. A site admin reads its own site's people by email and a master as "Master".
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    JsHook,
    Layout,
    Media,
    MediaCategory,
    Page,
    Stylesheet
  }

  alias MishkaCmsCoreWeb.Templates.VersionHistory

  require Ash.Query

  @resources [Component, ErrorPage, JsHook, Layout, Media, MediaCategory, Page, Stylesheet]

  setup do
    site = create_site!()

    %{
      site: site,
      colleague: create_user_with_permissions!(["*"], site_id: site.id),
      site_admin: create_user_with_permissions!(["*"], site_id: site.id),
      master: create_user_with_permissions!(["*"])
    }
  end

  for resource <- @resources do
    describe "#{inspect(resource)}'s versions" do
      setup %{site: site, colleague: colleague, master: master} do
        record = create(unquote(resource), site)
        edit(record, site, colleague, 1)
        edit(record, site, master, 2)

        %{record: record}
      end

      test "a master reads every author's email", ctx do
        authors = authors(ctx.record, :master_get_with_versions, actor: ctx.master)

        assert authors[ctx.colleague.id] == to_string(ctx.colleague.email)
        assert authors[ctx.master.id] == to_string(ctx.master.email)
      end

      test "a site admin reads its own people's emails and a master as Master", ctx do
        authors =
          authors(ctx.record, :get_with_versions, tenant: ctx.site.id, actor: ctx.site_admin)

        assert authors[ctx.colleague.id] == to_string(ctx.colleague.email)
        assert authors[ctx.master.id] == "Master"
      end
    end
  end

  # Each version's author by its `user_id`, named for the reader of `action`.
  defp authors(%resource{id: id}, action, opts) do
    versions =
      resource
      |> Ash.Query.for_read(action, %{}, opts)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(opts)
      |> Map.fetch!(:sorted_versions)

    masters = VersionHistory.master_ids(versions)
    Map.new(versions, &{&1.user_id, VersionHistory.author(&1, masters)})
  end

  defp create(Component, site), do: create_component!(site_id: site.id)
  defp create(ErrorPage, site), do: create_error_page!(site_id: site.id)
  defp create(JsHook, site), do: create_js_hook!(site_id: site.id)
  defp create(Layout, site), do: create_layout!(site_id: site.id)
  defp create(Media, site), do: create_media!(site_id: site.id)
  defp create(MediaCategory, site), do: create_media_category!(site_id: site.id)
  defp create(Page, site), do: create_page!(site_id: site.id)

  defp create(Stylesheet, site) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :create,
      %{name: "authors-#{System.unique_integer([:positive])}", content: ".a { color: red; }"},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  # One version of `record`, written by `actor`.
  defp edit(%ErrorPage{} = record, site, actor, n),
    do: update(record, site, actor, %{priority: n})

  defp edit(record, site, actor, n),
    do: update(record, site, actor, %{description: "edit #{n}"})

  defp update(record, site, actor, changes) do
    record
    |> Ash.Changeset.for_update(:update, changes,
      tenant: site.id,
      actor: actor,
      authorize?: false
    )
    |> Ash.update!()
  end
end
