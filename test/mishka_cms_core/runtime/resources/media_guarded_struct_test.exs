defmodule MishkaCmsCore.Runtime.Resources.MediaGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaCmsCore.Runtime.Media`.

  Media's `:name` is user-supplied display text that AshSlug slugifies on
  insert, and `:relative_path` is set by the upload pipeline (server-side
  trusted code). Both are already laundered by code Ash doesn't see, so GS
  validation there would be either redundant (name) or overreach (path).

  The one field where GS adds genuine value is `:format` — file extensions
  arrive in mixed case and with whitespace from various upload sources, so
  `sanitize(trim, downcase) validate(regex=^[a-z0-9]+$)` normalises to a
  predictable lowercase alphanumeric token before storage.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.Media
  @moduletag :unit

  describe "guardedstruct wiring" do
    test "GS covers every Ash attribute" do
      assert MapSet.new([
               :name,
               :type,
               :size,
               :format,
               :featured,
               :dimensions,
               :relative_path,
               :description
             ]) == Media.__guarded_field_name_set__()
    end
  end

  describe "direct __guarded_change__/1 — format" do
    test "uppercase + whitespace normalised to lowercase extension" do
      assert {:ok, %{format: "png"}} = Media.__guarded_change__(%{format: "  PNG  "})
      assert {:ok, %{format: "mp4"}} = Media.__guarded_change__(%{format: "MP4"})
      assert {:ok, %{format: "jpg"}} = Media.__guarded_change__(%{format: "jpg"})
    end

    test "format with non-alnum chars rejected with explicit error" do
      assert {:error,
              [
                %{
                  field: :format,
                  action: :regex,
                  message: "Invalid format in the format field"
                }
              ]} = Media.__guarded_change__(%{format: "tar.gz"})

      assert {:error,
              [
                %{
                  field: :format,
                  action: :regex,
                  message: "Invalid format in the format field"
                }
              ]} = Media.__guarded_change__(%{format: "image/png"})
    end
  end

  describe "macro pipeline through Ash.create/1" do
    setup do
      site = create_site!()
      %{site_id: site.id}
    end

    test "format trimmed + downcased in DB", %{site_id: site_id} do
      attrs = %{
        name: "photo-album",
        type: :images,
        size: 1024,
        format: "  JPG  "
      }

      assert {:ok, %Media{format: "jpg", name: "photo-album"}} =
               Media
               |> Ash.Changeset.for_create(:create, attrs,
                 tenant: site_id,
                 authorize?: false,
                 private_arguments: %{stored_path: "uploads/img.jpg"}
               )
               |> Ash.create()
    end

    test "bad format string is rejected through Ash", %{site_id: site_id} do
      attrs = %{
        name: "report",
        type: :documents,
        size: 500,
        format: "image/png"
      }

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Media
               |> Ash.Changeset.for_create(:create, attrs,
                 tenant: site_id,
                 authorize?: false,
                 private_arguments: %{stored_path: "uploads/img.png"}
               )
               |> Ash.create()

      assert Enum.any?(errors, fn e ->
               match?(%{field: :format}, e) and e.message =~ "Invalid format"
             end)
    end
  end
end
