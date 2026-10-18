# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.RestoreVersionPreviewTest do
  @moduledoc """
  A version previewed without restoring it (`RestoreVersion.preview/4`, behind every resource's
  `:preview_version` and `:master_preview_version`): the record as the snapshot says it was, built
  from the snapshot's keys without making an atom out of any of them.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory
  import MishkaCmsCore.Test.VersionHelpers

  alias MishkaCmsCore.Runtime.{Layout, Media}
  alias MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion

  @moduletag :unit

  describe "preview/4" do
    test "shows the fields the snapshot holds, and leaves the others as they are" do
      layout = create_layout!(template: "<div>now</div>", description: "now")

      shown = RestoreVersion.preview(layout, Layout, %{"template" => "<div>then</div>"})

      assert shown.template == "<div>then</div>"
      assert shown.description == "now"
    end

    test "casts a field stored as text to the atom its attribute is" do
      layout = create_layout!(format: :heex)

      shown = RestoreVersion.preview(layout, Layout, %{"format" => "markdown"})

      assert shown.format == :markdown
    end

    test "reads a snapshot kept as JSON, and takes none from a snapshot it cannot read" do
      layout = create_layout!(template: "<div>now</div>")

      assert RestoreVersion.preview(layout, Layout, ~s({"template":"<div>json</div>"})).template ==
               "<div>json</div>"

      for unreadable <- [nil, "", "not json", "[1, 2]"] do
        assert RestoreVersion.preview(layout, Layout, unreadable) == layout
      end
    end

    test "leaves out a key the resource does not accept, and makes no atom of it" do
      layout = create_layout!()
      name = "a_snapshot_key_nobody_declared_#{System.unique_integer([:positive])}"

      assert RestoreVersion.preview(layout, Layout, %{name => "x", "id" => "not-an-id"}) ==
               layout

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "leaves out the fields it was not told to show" do
      layout = create_layout!(template: "<div>now</div>", description: "now")

      shown =
        RestoreVersion.preview(
          layout,
          Layout,
          %{"template" => "<div>then</div>", "description" => "then"},
          [:description]
        )

      assert shown.template == "<div>now</div>"
      assert shown.description == "then"
    end
  end

  describe "the preview actions" do
    test "show a version's atom fields as atoms, for a master and for the site" do
      site = create_site!()
      layout = create_layout!(site_id: site.id, format: :heex, template: "<div>v1</div>")

      layout
      |> Ash.Changeset.for_update(:update, %{format: :markdown, template: "<div>v2</div>"},
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      first = first_version(Layout.Version, layout.id, tenant: site.id)

      for {action, opts} <- [
            {:master_preview_version, [authorize?: false]},
            {:preview_version, [tenant: site.id]}
          ] do
        {:ok, shown} =
          Layout
          |> Ash.ActionInput.for_action(
            action,
            %{layout_id: layout.id, version_id: first.id},
            opts
          )
          |> Ash.run_action(authorize?: false)

        assert shown.format == :heex
        assert shown.template == "<div>v1</div>"
      end
    end

    test "show a media version's type as the atom it is" do
      site = create_site!()
      media = create_media!(site_id: site.id, description: "Original")

      media
      |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)
      first = first_version(Media.Version, media.id)

      {:ok, shown} =
        Media
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{media_id: media.id, version_id: first.id},
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert shown.description == "Original"
      assert shown.type == media.type
      assert is_atom(shown.type)
    end
  end
end
