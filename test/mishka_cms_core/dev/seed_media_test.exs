defmodule MishkaCmsCore.Dev.SeedMediaTest do
  @moduledoc """
  The set of files the dev seeds ship, checked against the rules the seeds read them by.

  The seed reads a file's SHAPE off the front of its name and its SIZE out of its header, so a file
  that is named something else is silently left out of every seeded library and a file whose header
  cannot be read is registered with no dimensions at all. Neither says anything at the time. These
  read the directory the way the seed does and say it here instead.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Dev.SeedMedia

  # Small enough that the repository carries them without anybody minding. The whole set is under
  # 200 KB; this is the ceiling for one file, not a target.
  @budget 40_000

  @pixels %{cover: {1200, 630}, card: {800, 600}, avatar: {400, 400}}

  test "every file in the directory is one the seed can describe" do
    on_disk =
      SeedMedia.directory()
      |> File.ls!()
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.sort()

    described = SeedMedia.files() |> Enum.map(& &1.filename) |> Enum.sort()

    assert on_disk == described,
           "these ship and are never seeded, because their name starts with no known shape: " <>
             inspect(on_disk -- described)
  end

  # `File.ls/1` answers with directories as well as files, and a name is the whole registration — so
  # a directory called `card-old` read as a picture to copy, and the copy ended the seed run with
  # `:eisdir` before a single row was written. The same goes for a symlink pointing at nothing.
  test "an entry that is not a file is not one of them, whatever it is called" do
    directory = Path.join(SeedMedia.directory(), "card-not-a-file")
    dangling = Path.join(SeedMedia.directory(), "avatar-dangling.webp")

    File.mkdir_p!(directory)
    File.ln_s!(Path.join(SeedMedia.directory(), "no-such-file.webp"), dangling)
    on_exit(fn -> Enum.each([directory, dangling], &File.rm_rf!/1) end)

    named = SeedMedia.files() |> Enum.map(& &1.filename)

    refute "card-not-a-file" in named
    refute "avatar-dangling.webp" in named
  end

  test "the set has something for every shape a seed asks for" do
    counts =
      SeedMedia.files()
      |> Enum.group_by(& &1.shape)
      |> Map.new(fn {shape, files} -> {shape, length(files)} end)

    # A shape with one file in it gives every post the same cover and every blogger the same face.
    for shape <- [:cover, :card, :avatar, :document] do
      assert Map.get(counts, shape, 0) >= 3, "#{shape}: #{inspect(counts)}"
    end
  end

  test "no shipped file is big enough to be worth keeping out of the repository" do
    oversized =
      for file <- SeedMedia.files(),
          size = File.stat!(file.path).size,
          size > @budget,
          do: "#{file.filename} (#{size} B)"

    assert oversized == [], "over #{@budget} B: #{inspect(oversized)}"
  end

  test "an image really is the size its name promises" do
    for file <- SeedMedia.files(), Map.has_key?(@pixels, file.shape) do
      {width, height} = @pixels[file.shape]

      assert SeedMedia.dimensions(file.path) == %{width: width, height: height, unit: "px"},
             "#{file.filename} is #{inspect(SeedMedia.dimensions(file.path))}"
    end
  end

  test "a file whose size cannot be read is registered without dimensions, not with a guess" do
    document = Enum.find(SeedMedia.files(), &(&1.shape == :document))

    assert SeedMedia.dimensions(document.path) == %{}
    assert SeedMedia.dimensions(Path.join(SeedMedia.directory(), "no-such-file.webp")) == %{}
  end

  test "a title is read off the name, with the shape taken away" do
    cover = Enum.find(SeedMedia.files(), &(&1.shape == :cover))

    refute cover.title =~ "cover"
    refute cover.title =~ "-"
    assert cover.title == String.capitalize(cover.title)
  end
end
