# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.SeedMedia do
  @moduledoc """
  The files the dev seeds put in a site's media library, and where any other seed gets a picture.

  A media row used to be written with an invented path — `/uploads/images/3.jpg`, which nothing had
  ever written a file to — so every thumbnail in the library fell back to its type glyph, the
  builder's media sheet handed pages an `<img src>` that answered 404, and a blog cover was either
  nothing or one of the marketing site's own photographs. The set under `priv/dev_seed_media` is
  drawn from primitives rather than photographed: nobody's copyright, nothing downloaded, and small
  enough (well under 40 KB each) to live in the repository.

  A FILE'S NAME SAYS WHAT IT IS FOR. `cover-*` is a wide banner, `card-*` a listing picture,
  `avatar-*` a portrait and `doc-*` a document; that prefix is the whole registration, so adding one
  is dropping it in the directory. An entry whose prefix is none of those — or that is not a file at
  all — is left alone rather than guessed at: `files/0` is what the seed writes, and it only names
  what it can describe.

  Storing goes through the resource's own upload path — `Media.validate_and_process_file/1` then
  `Media.save_file_to_storage/3` — so a seeded row lands exactly where an uploaded one does, under
  `/uploads/<site>/media/<category>/<uuid>.<ext>`, and replacing, archiving or deleting it from the
  admin works on it like any other file. The copy is staged through a temporary file first: storing
  removes the source it is given, and the source here is a file the repository ships.

  There are no videos in the set. A real `.mp4` needs an encoder nothing in this toolchain has, and a
  row pointing at one we could not write is the 404 this module exists to remove. That costs the dev
  database the one `:videos` row the old seed invented, so a seeded library no longer has anything
  for the media screen's type filter, its `by_type` read or the film glyph the thumbnail column draws
  in place of a picture — ground the resource's own tests and the stress seed still cover, and that a
  real `.webm` should take back the day something here can write one.
  """

  import Bitwise
  import MishkaCmsCore.Dev.Generator, only: [media: 2, media_category: 2]

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Media, MediaCategory}

  @shapes %{"cover" => :cover, "card" => :card, "avatar" => :avatar, "doc" => :document}

  @category_names %{
    cover: "Banners",
    card: "Images",
    avatar: "Avatars",
    document: "Documents"
  }

  @doc """
  Every shipped file as `%{filename: ..., path: ..., shape: ..., title: ...}`, ordered by name.

  Answers `[]` when the directory is not there — a package that did not ship it seeds a library with
  nothing in it rather than failing the whole run.
  """
  @spec files() :: [%{filename: String.t(), path: String.t(), shape: atom(), title: String.t()}]
  def files do
    case File.ls(directory()) do
      {:ok, entries} -> entries |> Enum.sort() |> Enum.flat_map(&describe/1)
      {:error, _unnamed} -> []
    end
  end

  @doc """
  Writes whatever of the set `site_id` does not have yet into its library, one category per shape
  the set has, and returns the media rows it wrote.

  A file that cannot be stored is reported and skipped: a library short one picture is worth more to
  whoever is seeding than a run that stops on it.

  RUN AGAIN, THIS ADDS ONLY WHAT IS NEW. Reseeding is how a developer gets the pictures a later
  version of this set ships without dropping their database, so a category that is there is reused
  and a file that is there is passed over — which is also what makes dropping one more file into
  `priv/dev_seed_media` and reseeding the way to add it. It never updates: the row an admin renamed,
  re-described or moved to another category is theirs.
  """
  @spec install(String.t()) :: [Media.t()]
  def install(site_id) do
    held = held(site_id, Enum.map(files(), &stored_name(&1.filename)))

    pending =
      files()
      |> Enum.group_by(& &1.shape)
      |> Enum.flat_map(fn {shape, shaped} ->
        case Enum.reject(shaped, &MapSet.member?(held.names, stored_name(&1.filename))) do
          [] -> []
          missing -> [{shape, missing, featured_shape?(shaped, held.featured)}]
        end
      end)

    categories = categories(site_id, Enum.map(pending, &elem(&1, 0)))

    Enum.flat_map(pending, fn {shape, missing, featured?} ->
      category_id = Map.get(categories, shape)

      missing
      |> Enum.with_index()
      |> Enum.flat_map(fn {file, index} ->
        register(file, site_id, category_id, index == 0 and not featured?)
      end)
    end)
  end

  @doc """
  The paths of the images `site_id` already has, grouped by shape — `%{cover: [...], card: [...],
  avatar: [...]}`.

  This is how a seed that needs a picture asks for one: the blog's covers and avatars are rows in
  the library rather than strings pointing at whatever happens to be under `priv/static`. A site
  that has not been media-seeded answers `%{}`, and every caller has to read that as "no picture",
  because that is also what a fresh install looks like.
  """
  @spec images(String.t()) :: %{atom() => [String.t()]}
  def images(site_id) do
    Media
    |> Ash.Query.for_read(:read, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(type == :images)
    |> Ash.Query.sort(:name)
    |> Ash.read!(page: false)
    |> Enum.group_by(&shape(&1.name), & &1.relative_path)
    |> Map.delete(nil)
  end

  @doc """
  The pixel size of `path` in the shape the `dimensions` attribute stores, or `%{}` for a file whose
  header this cannot read.

  Read from the file rather than declared beside it, so a replaced picture cannot leave a row
  describing the one before it. Every picture in the set is a lossy WebP, which keeps its canvas
  size in the first chunk (`VP8 `) 26 bytes in, as two 14-bit values; that is the one header this
  reads. Anything else — a document, or a lossless (`VP8L`) or extended (`VP8X`) WebP somebody adds
  later — answers `%{}` rather than a guess, and the suite says which file it was, so the clause for
  that chunk gets written the day a file needs it.
  """
  @spec dimensions(String.t()) :: map()
  def dimensions(path), do: path |> header(32) |> webp_dimensions()

  @doc """
  Where the shipped files live.

  Configurable, the way `MishkaCmsCore.Runtime.PageUpload.directory/1` is, and for a reason the
  shipped path cannot cover: a file's presence in this directory IS its registration, and under
  `:test` the path below resolves through Mix's `priv` symlink to the repository's own source. A
  suite proving that a file dropped in between two runs is picked up would be dropping it into the
  set the package ships — one killed VM away from a stray picture nothing ignores and `git add -A`
  commits. Pointed somewhere else, it writes where it can afford to.
  """
  @spec directory() :: String.t()
  def directory do
    Application.get_env(:mishka_cms_core, :dev_seed_media_dir) || shipped_directory()
  end

  defp shipped_directory do
    case :code.priv_dir(:mishka_cms_core) do
      {:error, _unnamed} -> Path.join(["priv", "dev_seed_media"])
      priv -> Path.join(to_string(priv), "dev_seed_media")
    end
  end

  # ---------------------------------------------------------------------------
  # Files
  # ---------------------------------------------------------------------------

  # A DIRECTORY IS NOT A FILE, and `File.ls/1` answers with both. The name is the whole
  # registration, so `mkdir card-old` inside the set was a picture to copy, and the copy took the
  # entire seed run down with `:eisdir`. Anything that is not a regular file — a directory, a
  # symlink pointing at nothing — is passed over here, where a name with no shape already is.
  defp describe(filename) do
    path = Path.join(directory(), filename)

    with shape when not is_nil(shape) <- shape(filename),
         true <- File.regular?(path) do
      [%{filename: filename, path: path, shape: shape, title: title(filename)}]
    else
      _unnamed -> []
    end
  end

  # The prefix of the name, which is also the prefix of the name the stored row carries — that is
  # what lets `images/1` group rows by shape without a column to keep it in.
  defp shape(name) when is_binary(name) do
    case String.split(name, "-", parts: 2) do
      [prefix, _rest] -> Map.get(@shapes, prefix)
      _unnamed -> nil
    end
  end

  defp shape(_name), do: nil

  defp title(filename) do
    filename
    |> Path.rootname()
    |> String.split("-")
    |> tl()
    |> Enum.join(" ")
    |> String.capitalize()
  end

  # ---------------------------------------------------------------------------
  # Registering
  # ---------------------------------------------------------------------------

  defp categories(_site_id, []), do: %{}

  # THE NAME IS THE CATEGORY, which `MediaCategory`'s `unique_name_per_parent` is what says for the
  # top level the seed writes to: a second run finds "Banners" already there and puts this run's
  # banners in it rather than dying on a name it cannot have twice. The description an admin
  # rewrote stays theirs — this only ever reads.
  #
  # ONLY THE SHAPES THAT HAVE A FILE TO WRITE, which is why `install/1` works out what is pending
  # before it asks for these. A run with nothing new to store asks for no category at all, so a site
  # whose "Avatars" an admin archived is not handed a fresh empty one every time the seed is run.
  defp categories(site_id, shapes) do
    held = held_categories(site_id)

    Map.new(shapes, fn shape ->
      name = @category_names[shape]

      category =
        Map.get_lazy(held, Slug.slugify(name), fn ->
          [name: name, description: "Dev seed #{shape} files"]
          |> media_category(site_id)
          |> Ash.Generator.generate()
        end)

      {shape, category.id}
    end)
  end

  defp register(file, site_id, category_id, featured?) do
    case store(file, site_id, category_id) do
      {:ok, stored} ->
        [
          stored
          |> Keyword.merge(
            featured: featured?,
            description: "#{file.title} — a dev seed file, drawn rather than photographed.",
            media_category_id: category_id
          )
          |> media(site_id)
          |> Ash.Generator.generate()
        ]

      {:error, reason} ->
        MishkaCmsCore.Dev.Seeds.announce(
          "  !! Could not store #{file.filename}: #{inspect(reason)}"
        )

        []
    end
  end

  # The staged copy is what gets stored: `save_file_to_storage/3` removes the file it is handed once
  # it has copied it, and the file handed over here is one the repository ships. The copy is the
  # first step of the `with` rather than a raise before it, so a source that cannot be read is
  # reported and skipped like every other failure instead of ending the run. Removing the stage
  # again on the failure path, because only the success path removes it.
  defp store(file, site_id, category_id) do
    staged = staged_path(file)

    with :ok <- File.cp(file.path, staged),
         {:ok, upload} <-
           Media.validate_and_process_file(%{
             file: Ash.Type.File.from_path(staged),
             original_filename: file.filename
           }),
         {:ok, relative_path} <- Media.save_file_to_storage(upload, site_id, category_id) do
      {:ok,
       [
         name: upload.name,
         type: upload.type,
         size: upload.size,
         format: upload.format,
         relative_path: relative_path,
         dimensions: dimensions(file.path)
       ]}
    else
      {:error, reason} ->
        File.rm(staged)
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # What the site already has
  # ---------------------------------------------------------------------------

  # THE SITE'S OWN KEY, NOT THE CATEGORY'S. `Media`'s `unique_name_per_site` is on `(name, site_id)`,
  # so a picture an admin dragged from Banners into Images is still, to the database, the row that
  # name belongs to — and a second copy under it is what a create would refuse anyway. Archived rows
  # count too, the rule the rest of the seeds follow: an admin who threw a picture away is not handed
  # it back on the next run.
  #
  # FEATURED IS COUNTED OFF THE LIVE ROWS ALONE, because it is a question about the library as it
  # stands: a featured picture the admin archived is not in it, so its shape has none, and the next
  # picture that shape gains may have it.
  defp held(site_id, names) do
    live = rows(Media, :read, site_id, names)
    archived = rows(Media, :archived, site_id, names)

    %{
      names: MapSet.new(live ++ archived, & &1.name),
      featured: live |> Enum.filter(& &1.featured) |> MapSet.new(& &1.name)
    }
  end

  # ONE FEATURED PICTURE PER SHAPE, AND IT DOES NOT MOVE. The first file of a shape is what a first
  # run features, but "first" is the sorted set's first — so a picture added later whose name sorts
  # ahead of it, `card-added-…` before `card-city-grid`, arrived at index 0 and was written featured
  # beside the one that already was, leaving the site two featured cards for one shape. Asked of the
  # site rather than of the index, the answer cannot drift: a shape that has a featured picture keeps
  # it, and only a shape that has none features whichever of its files is written first. That is
  # also what closes the run whose very first file failed to store — the next run features what it
  # does manage to write, instead of leaving that shape with nothing featured for good.
  defp featured_shape?(shaped, featured) do
    Enum.any?(shaped, &MapSet.member?(featured, stored_name(&1.filename)))
  end

  # LIVE CATEGORIES ONLY, unlike the media above, because this answer is what a NEW row is filed
  # under: a category an admin archived is gone from the library, and putting today's picture in it
  # would hide the picture rather than reuse the category. And TOP-LEVEL ONLY, where the seed makes
  # them: an admin's own "banners" folder inside another one is theirs, not the seed's.
  defp held_categories(site_id) do
    names = @category_names |> Map.values() |> Enum.map(&Slug.slugify/1)

    MediaCategory
    |> rows(:read, site_id, names)
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Map.new(&{&1.name, &1})
  end

  # THE NAME THE ROW WILL CARRY. Two rules make it, and both have to be applied or the question is
  # asked about a row that is not there: `Media.upload_name/1` is what an upload derives from a
  # filename, and `slugify(:name, into: :name)` on every one of that resource's create actions is
  # what stores it. "Banners" is the category that showed it — written by the seed, stored as
  # `banners`, and looked for under the name it was written with, so the second run never found the
  # category it had made and died creating it again.
  defp stored_name(filename), do: filename |> Media.upload_name() |> Slug.slugify()

  # A PAGE IS NOT THE WHOLE ANSWER, and sizing it by the names asked about was the trap. A file's
  # live rows are bounded by that list — its name is unique per site — but `unique_name_per_site` is
  # partial on `archived_at IS NULL`, so one name can have any number of ARCHIVED rows behind it,
  # and enough of them crowded another name off the page. A folder's name is unique only beside its
  # siblings, so even its live rows are not bounded by it. That name then looked absent and was written a second
  # time: the duplication this module exists to stop. So the pages are followed to the end instead,
  # and `page: false` is not the shortcut — these actions require a page.
  defp rows(_resource, _action, _site_id, []), do: []

  defp rows(resource, action, site_id, names) do
    resource
    |> Ash.Query.for_read(action, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(name in ^names)
    |> Ash.read!(authorize?: false, page: [limit: length(names)])
    |> every_page()
  end

  # A PAGE THAT CARRIED SOMETHING is what earns the next one. `Ash.page/2` answers a keyset page with
  # no results with itself, so a page claiming `more?` over nothing would be asked for its successor
  # for ever; this clause cannot match it, and the read stops on whatever it has.
  defp every_page(%{results: [_first | _rest] = found, more?: true} = page),
    do: found ++ every_page(Ash.page!(page, :next))

  defp every_page(%{results: found}), do: found
  defp every_page(found) when is_list(found), do: found

  defp staged_path(file) do
    Path.join(
      System.tmp_dir!(),
      "mishka-seed-#{Ash.UUID.generate()}#{Path.extname(file.filename)}"
    )
  end

  # ---------------------------------------------------------------------------
  # Dimensions
  # ---------------------------------------------------------------------------

  defp header(path, bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        read = IO.binread(io, bytes)
        File.close(io)
        if is_binary(read), do: read, else: ""

      {:error, _unnamed} ->
        ""
    end
  end

  defp webp_dimensions(
         <<"RIFF", _size::32, "WEBP", "VP8 ", _length::32, _frame_tag::binary-size(3), 0x9D, 0x01,
           0x2A, width::little-16, height::little-16, _rest::binary>>
       ),
       do: %{width: width &&& 0x3FFF, height: height &&& 0x3FFF, unit: "px"}

  defp webp_dimensions(_other), do: %{}
end
