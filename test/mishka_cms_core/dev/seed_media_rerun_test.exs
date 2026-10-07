defmodule MishkaCmsCore.Dev.SeedMediaRerunTest do
  @moduledoc """
  Installing the set into a library that already has it.

  Reseeding is how a developer picks up the pictures a later version of the set ships without
  dropping the database they have been working in, and until now the second run died on the first
  category it tried to create a second time. Nothing about that is visible from the files alone —
  `MishkaCmsCore.Dev.SeedMediaTest` reads the directory and never touches a library — so the second
  run is driven here, against a real one.

  ## The set these run against is a copy

  A file's presence in the set IS its registration, and under `:test` `SeedMedia.directory/0`
  resolves through Mix's `priv` symlink to the repository's own source. Adding a file there to prove
  that a new one gets picked up would be adding it to what the package ships, one killed VM away
  from a stray picture nothing ignores. So the shipped files are copied into a directory of this
  run's own and `:dev_seed_media_dir` points at that, the way `MishkaCmsCore.Runtime.PageUploadTest`
  points `:page_upload_dir` at one.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Dev.SeedMedia
  alias MishkaCmsCore.Runtime.{Media, MediaCategory}

  require Ash.Query

  # A SEEDED LIBRARY IS FILES, AND THE SANDBOX CANNOT ROLL A FILE BACK. Both directories, because
  # archiving a picture MOVES it: `uploads_archived` is where the one the admin threw away goes, and
  # a run that only took the live directory back left it in the working tree.
  setup do
    site = create_site!()
    set = Path.join(System.tmp_dir!(), "dev_seed_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(set)

    for file <- SeedMedia.files(), do: File.cp!(file.path, Path.join(set, file.filename))

    Application.put_env(:mishka_cms_core, :dev_seed_media_dir, set)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :dev_seed_media_dir)
      File.rm_rf!(set)

      for base <- ["uploads", "uploads_archived"],
          do: File.rm_rf!(Path.join(["priv", "static", base, site.id]))
    end)

    %{site: site, set: set}
  end

  # THE SET THESE RUN AGAINST IS THIS RUN'S OWN, which is the whole reason the directory can be
  # pointed anywhere. Without that, `directory/0` answers the package's shipped set and `add_file!/2`
  # below is adding a picture to the repository — where a file's presence is its registration, so a
  # copy left behind by a killed VM is a shipped seed picture nobody meant to ship.
  test "the set installed from is this run's copy, not the one the package ships", %{set: set} do
    assert SeedMedia.directory() == set
    assert length(SeedMedia.files()) == length(File.ls!(set))
  end

  test "a second install adds no category, no row and no file", %{site: site} do
    first = SeedMedia.install(site.id)

    assert first != []
    before = census(site.id)

    assert SeedMedia.install(site.id) == []
    assert census(site.id) == before
  end

  test "the categories the second run files under are the ones the first run made", %{site: site} do
    SeedMedia.install(site.id)
    categories = MediaCategory |> Ash.read!(tenant: site.id, authorize?: false, page: false)

    SeedMedia.install(site.id)

    assert MapSet.new(ids(MediaCategory, site.id)) == MapSet.new(Enum.map(categories, & &1.id))
  end

  # WHAT RESEEDING IS FOR. A developer who pulls a commit that adds a picture runs the seed again to
  # get it, and what they must not get with it is a second copy of the twenty-three they already had.
  test "a file that appears between runs is added, and only it", %{site: site, set: set} do
    SeedMedia.install(site.id)
    before = census(site.id)

    add_file!(set, "card-added-between-runs.webp")

    assert [row] = SeedMedia.install(site.id)
    assert row.name == "card-added-between-runs"

    after_run = census(site.id)
    assert after_run.categories == before.categories
    assert after_run.media == before.media + 1
    assert after_run.files == before.files + 1
  end

  # ONE FEATURED PICTURE PER SHAPE, AND IT DOES NOT MOVE. `files/0` is sorted by filename, so a
  # picture added later can sort AHEAD of the one a first run featured — `card-added-…` comes before
  # `card-city-grid` — and an index taken over the set handed it `featured: true` while the picture
  # that already held it kept it, leaving the site two featured cards for one shape. Deciding it
  # against what the site holds is what makes the answer stand still.
  test "a picture added ahead of the featured one does not become a second featured one", %{
    site: site,
    set: set
  } do
    SeedMedia.install(site.id)
    featured = featured_names(site.id)

    assert "card-city-grid" in featured

    add_file!(set, "card-aaa-added-first.webp")

    assert [row] = SeedMedia.install(site.id)
    assert row.name == "card-aaa-added-first"
    refute row.featured

    assert featured_names(site.id) == featured
  end

  # NEVER OVERWRITE WHAT AN ADMIN MAY HAVE EDITED. The description and the category a picture sits in
  # are theirs once the library exists; a second run that wrote the seed's own text back over them
  # would be a seed undoing a day's work every time somebody wanted the newest pictures.
  test "a row the admin renamed the description of, and moved, is left alone", %{site: site} do
    SeedMedia.install(site.id)

    [row | _rest] = Ash.read!(Media, tenant: site.id, authorize?: false, page: false)
    elsewhere = create_media_category!(site_id: site.id, name: "Admin's own")

    edited =
      row
      |> Ash.Changeset.for_update(
        :update,
        %{description: "Written by the admin", media_category_id: elsewhere.id},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

    assert SeedMedia.install(site.id) == []

    reread = Ash.get!(Media, edited.id, tenant: site.id, authorize?: false)
    assert reread.description == "Written by the admin"
    assert reread.media_category_id == elsewhere.id
  end

  # A CATEGORY IS ASKED FOR ONLY WHERE THERE IS A FILE TO PUT IN IT. Made unconditionally, the run
  # that has nothing to add still found no live "banners" — an archived one does not count, since a
  # new picture cannot be filed in a category the admin threw away — and made a second empty one,
  # every single run. A folder is archived only once it is empty, so the admin moves the banners
  # out to the top level first.
  test "a category the admin archived is not made again when nothing needs one", %{site: site} do
    SeedMedia.install(site.id)
    before = census(site.id)

    banners =
      MediaCategory
      |> Ash.read!(tenant: site.id, authorize?: false, page: false)
      |> Enum.find(&(&1.name == "banners"))

    Media
    |> Ash.Query.filter(media_category_id == ^banners.id)
    |> Ash.read!(tenant: site.id, authorize?: false, page: false)
    |> Enum.each(&Ash.update!(&1, %{media_category_id: nil}, tenant: site.id, authorize?: false))

    Ash.destroy!(banners, tenant: site.id, authorize?: false)

    assert SeedMedia.install(site.id) == []
    assert census(site.id).categories == before.categories - 1
  end

  # An archived picture is one an admin threw away. A run that wrote it back would be the seed
  # arguing with them — and the partial unique index would let it, because an archived row is not in
  # the index the create is checked against.
  test "a picture the admin archived is not put back", %{site: site} do
    SeedMedia.install(site.id)

    [row | _rest] = Ash.read!(Media, tenant: site.id, authorize?: false, page: false)
    Ash.destroy!(row, tenant: site.id, authorize?: false)

    assert SeedMedia.install(site.id) == []
  end

  # AND IT IS STILL NOT PUT BACK WHEN ANOTHER NAME HAS A HISTORY. That same partial index is what
  # lets one name hold any number of archived rows, so a read sized by the names being asked about
  # can come back full of one name's discarded copies with another name nowhere in it. The name that
  # fell off the page looked absent, and the run wrote a second copy of a picture the admin had
  # thrown away — the duplication the whole check exists to stop.
  test "an archived picture is recognised from behind another name's archived copies", %{
    site: site
  } do
    SeedMedia.install(site.id)

    site.id |> live() |> Enum.find(&(&1.name == "avatar-ada")) |> archive!(site.id)
    crowd!(site.id, "card-city-grid", length(SeedMedia.files()))

    assert SeedMedia.install(site.id) == []
  end

  defp census(site_id) do
    %{
      categories: length(ids(MediaCategory, site_id)),
      media: length(ids(Media, site_id)),
      files:
        ["priv", "static", "uploads", site_id, "**", "*"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.count(&File.regular?/1)
    }
  end

  defp ids(resource, site_id) do
    resource
    |> Ash.read!(tenant: site_id, authorize?: false, page: false)
    |> Enum.map(& &1.id)
  end

  defp live(site_id), do: Ash.read!(Media, tenant: site_id, authorize?: false, page: false)

  defp featured_names(site_id) do
    site_id |> live() |> Enum.filter(& &1.featured) |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp add_file!(set, filename) do
    source = Enum.find(SeedMedia.files(), &(&1.shape == :card))
    File.cp!(source.path, Path.join(set, filename))
  end

  defp archive!(row, site_id), do: Ash.destroy!(row, tenant: site_id, authorize?: false)

  # `count` archived rows under one name, all of them sorting ahead of everything else the read can
  # return. The ids are dictated rather than generated because a paginated read is sorted by primary
  # key and a generated uuid lands wherever it lands: these are the page that a limit sized by the
  # name count hands back, so the test says the same thing on every run instead of on most of them.
  defp crowd!(site_id, name, count) do
    site_id |> live() |> Enum.find(&(&1.name == name)) |> archive!(site_id)

    for index <- 1..count do
      Media
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: name,
          type: :images,
          size: 1_024,
          format: "webp"
        },
        tenant: site_id,
        authorize?: false,
        private_arguments: %{stored_path: "/uploads/#{site_id}/media/crowd-#{index}.webp"}
      )
      |> Ash.Changeset.force_change_attribute(
        :id,
        "00000000-0000-4000-8000-#{String.pad_leading("#{index}", 12, "0")}"
      )
      |> Ash.create!()
      |> archive!(site_id)
    end
  end
end
