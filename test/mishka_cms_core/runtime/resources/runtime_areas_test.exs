# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.RuntimeAreasTest do
  @moduledoc """
  The areas the sites, media and translations data enforce, on each surface.

  Sites are the site area's to read and write; the site a record belongs to still loads for anyone
  under the surface. Media, media categories and translations are content: anyone under the surface
  reads them, and writing takes the area — `admin:<surface>:media` or
  `admin:dashboard:runtime:translation`. Each gate is asked as a holder of that one area and as a holder of
  another.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Runtime.{Media, MediaCategory, Site, Translation}

  require Ash.Query

  @api %{shared: %{admin_surface: :api}}

  setup do
    site = create_site!()
    {:ok, site: site}
  end

  defp holder(names, site_id \\ nil), do: create_user_with_permissions!(names, site_id: site_id)

  defp read(resource, action, actor, tenant, context \\ %{}) do
    resource
    |> Ash.Query.for_read(action, %{}, actor: actor, tenant: tenant, context: context)
    |> Ash.read()
    |> case do
      {:ok, %{results: results}} -> {:ok, results}
      other -> other
    end
  end

  defp ids({:ok, records}), do: Enum.map(records, & &1.id)
  defp ids({:error, _}), do: []

  describe "sites" do
    test "a site's holder of the site area reads its site; a holder of another area does not",
         ctx do
      assert ctx.site.id in ids(
               read(
                 Site,
                 :tenant_read,
                 holder(["admin:dashboard:runtime:site"], ctx.site.id),
                 ctx.site.id
               )
             )

      refute ctx.site.id in ids(
               read(
                 Site,
                 :tenant_read,
                 holder(["admin:dashboard:runtime:media"], ctx.site.id),
                 ctx.site.id
               )
             )
    end

    test "a master of the site area edits a site; a master of another area does not", ctx do
      update = fn actor ->
        ctx.site
        |> Ash.Changeset.for_update(:update, %{priority: 7}, actor: actor)
        |> Ash.update()
      end

      assert {:error, _} = update.(holder(["admin:dashboard:runtime:page"]))
      assert {:ok, %{priority: 7}} = update.(holder(["admin:dashboard:runtime:site"]))
    end

    test "on the API the API's site area reads it, and the dashboard's does not", ctx do
      assert ctx.site.id in ids(
               read(
                 Site,
                 :tenant_read,
                 holder(["admin:api:runtime:site"], ctx.site.id),
                 ctx.site.id,
                 @api
               )
             )

      refute ctx.site.id in ids(
               read(
                 Site,
                 :tenant_read,
                 holder(["admin:dashboard:runtime:site"], ctx.site.id),
                 ctx.site.id,
                 @api
               )
             )
    end

    test "the site a record belongs to loads for anyone under the surface, and nobody else",
         ctx do
      media = create_media!(site_id: ctx.site.id)

      loaded =
        Ash.load!(media, [:site],
          actor: holder(["admin:dashboard:runtime:page"], ctx.site.id),
          tenant: ctx.site.id
        )

      assert loaded.site.id == ctx.site.id

      assert {:error, _} =
               Ash.load(media, [:site],
                 actor: holder(["secret:role"], ctx.site.id),
                 tenant: ctx.site.id
               )
    end
  end

  describe "media" do
    test "anyone under the surface reads the library; nobody else does", ctx do
      media = create_media!(site_id: ctx.site.id)

      assert media.id in ids(
               read(
                 Media,
                 :read,
                 holder(["admin:dashboard:runtime:page"], ctx.site.id),
                 ctx.site.id
               )
             )

      refute media.id in ids(
               read(Media, :read, holder(["secret:role"], ctx.site.id), ctx.site.id)
             )
    end

    test "the media area edits media; another area does not", ctx do
      media = create_media!(site_id: ctx.site.id)

      update = fn actor, context ->
        media
        |> Ash.Changeset.for_update(:update, %{description: "edited"},
          actor: actor,
          tenant: ctx.site.id,
          context: context
        )
        |> Ash.update()
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               update.(holder(["admin:dashboard:runtime:page"], ctx.site.id), %{})

      assert {:ok, %{description: "edited"}} =
               update.(holder(["admin:dashboard:runtime:media"], ctx.site.id), %{})
    end

    test "on the API the API's media area edits media, and the dashboard's does not", ctx do
      media = create_media!(site_id: ctx.site.id)

      update = fn actor ->
        media
        |> Ash.Changeset.for_update(:update, %{description: "over the api"},
          actor: actor,
          tenant: ctx.site.id,
          context: @api
        )
        |> Ash.update()
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               update.(holder(["admin:dashboard:runtime:media"], ctx.site.id))

      assert {:ok, _} = update.(holder(["admin:api:runtime:media"], ctx.site.id))
    end

    test "its versions are read by anyone under the surface", ctx do
      media = create_media!(site_id: ctx.site.id)

      loaded =
        Ash.load!(media, [:version_count],
          actor: holder(["admin:dashboard:runtime:page"], ctx.site.id),
          tenant: ctx.site.id
        )

      assert is_integer(loaded.version_count)

      hidden =
        Ash.load!(media, [:version_count],
          actor: holder(["secret:role"], ctx.site.id),
          tenant: ctx.site.id
        )

      assert %Ash.ForbiddenField{} = hidden.version_count
    end

    test "its version rows are read by anyone under the surface; nobody else", ctx do
      media = create_media!(site_id: ctx.site.id)
      category = create_media_category!(site_id: ctx.site.id)

      rows = fn resource, actor ->
        resource
        |> Ash.Query.for_read(:read_any, %{}, actor: actor)
        |> Ash.read!()
        |> Enum.map(& &1.version_source_id)
      end

      page_admin = holder(["admin:dashboard:runtime:page"], ctx.site.id)
      nobody = holder(["secret:role"], ctx.site.id)

      assert media.id in rows.(Media.Version, page_admin)
      assert category.id in rows.(MediaCategory.Version, page_admin)
      assert {:error, _} = Ash.read(Media.Version, action: :read_any, actor: nobody)
    end

    test "a version is previewed by anyone under the surface", ctx do
      media = create_media!(site_id: ctx.site.id)

      [version | _] =
        Media.Version
        |> Ash.Query.filter(version_source_id == ^media.id)
        |> Ash.read!(authorize?: false)

      preview = fn actor ->
        Media
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{media_id: media.id, version_id: version.id},
          actor: actor,
          tenant: ctx.site.id
        )
        |> Ash.run_action()
      end

      assert {:ok, _} = preview.(holder(["admin:dashboard:runtime:page"], ctx.site.id))
      assert {:error, %Ash.Error.Forbidden{}} = preview.(holder(["secret:role"], ctx.site.id))
    end
  end

  describe "media categories" do
    test "anyone under the surface reads them; the media area edits them; another area does not",
         ctx do
      category = create_media_category!(site_id: ctx.site.id)

      assert category.id in ids(
               read(
                 MediaCategory,
                 :read,
                 holder(["admin:dashboard:runtime:page"], ctx.site.id),
                 ctx.site.id
               )
             )

      update = fn actor ->
        category
        |> Ash.Changeset.for_update(:update, %{description: "edited"},
          actor: actor,
          tenant: ctx.site.id
        )
        |> Ash.update()
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               update.(holder(["admin:dashboard:runtime:page"], ctx.site.id))

      assert {:ok, _} = update.(holder(["admin:dashboard:runtime:media"], ctx.site.id))
    end

    test "on the API the API's media area edits them, and the dashboard's does not", ctx do
      category = create_media_category!(site_id: ctx.site.id)

      update = fn actor ->
        category
        |> Ash.Changeset.for_update(:update, %{description: "over the api"},
          actor: actor,
          tenant: ctx.site.id,
          context: @api
        )
        |> Ash.update()
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               update.(holder(["admin:dashboard:runtime:media"], ctx.site.id))

      assert {:ok, _} = update.(holder(["admin:api:runtime:media"], ctx.site.id))
    end
  end

  describe "translations" do
    defp translate(actor, site, key) do
      Translation
      |> Ash.Changeset.for_create(:create, %{key: key, language: "en", value: "Hello"},
        actor: actor,
        tenant: site.id
      )
      |> Ash.create()
    end

    test "the translation area writes one; another area does not", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               translate(holder(["admin:dashboard:runtime:page"], ctx.site.id), ctx.site, "hello")

      assert {:ok, _} =
               translate(
                 holder(["admin:dashboard:runtime:translation"], ctx.site.id),
                 ctx.site,
                 "hello"
               )
    end

    test "anyone under the surface reads them; nobody else does", ctx do
      {:ok, row} =
        translate(
          holder(["admin:dashboard:runtime:translation"], ctx.site.id),
          ctx.site,
          "greeting"
        )

      assert row.id in ids(
               read(
                 Translation,
                 :tenant_read,
                 holder(["admin:dashboard:runtime:page"], ctx.site.id),
                 ctx.site.id
               )
             )

      refute row.id in ids(
               read(Translation, :tenant_read, holder(["secret:role"], ctx.site.id), ctx.site.id)
             )
    end
  end
end
