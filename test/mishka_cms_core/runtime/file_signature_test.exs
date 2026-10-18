# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.FileSignatureTest do
  @moduledoc """
  A file is what its first bytes say, not what its name or its sender's MIME type say.

  The bytes of each kind below are the smallest header a real file of that kind starts with. The
  files are written to a temporary directory and read back through `FileSignature.sniff/1`, the way
  the media library and a visitor's upload read them.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.FileSignature

  @moduletag :unit

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>>
  @gif <<"GIF89a", 1, 0, 1, 0>>
  @webp <<"RIFF", 24, 0, 0, 0, "WEBPVP8 ">>
  @pdf "%PDF-1.7\n%âãÏÓ\n"
  @mp4 <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0>>
  @webm <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81>>
  @ole2 <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0>>
  @zip <<"PK", 3, 4, 20, 0, 0, 0>>

  @script "<script>alert(document.domain)</script>"
  @svg ~s|<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>|
  @html "<!doctype html><html><body><script>alert(1)</script></body></html>"

  setup do
    dir = Path.join(System.tmp_dir!(), "file_signature_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    write = fn content ->
      path = Path.join(dir, "f#{System.unique_integer([:positive])}")
      File.write!(path, content)
      path
    end

    %{write: write}
  end

  describe "sniff/1" do
    test "names each kind from its first bytes", %{write: write} do
      for {kind, content} <- [
            png: @png,
            jpeg: @jpeg,
            gif: @gif,
            webp: @webp,
            pdf: @pdf,
            iso_media: @mp4,
            matroska: @webm,
            ole2: @ole2,
            zip: @zip,
            text: "name,email\nada,ada@example.com\n"
          ] do
        assert FileSignature.sniff(write.(content)) == {:ok, kind}, "#{kind} was not recognised"
      end
    end

    # TEXT IS ANYTHING THAT READS AS TEXT, so markup is text. It is the extension that decides
    # whether text is wanted: `matches?/2` below refuses it as a picture.
    test "reads markup as text and a script as text", %{write: write} do
      assert FileSignature.sniff(write.(@html)) == {:ok, :text}
      assert FileSignature.sniff(write.(@svg)) == {:ok, :text}
      assert FileSignature.sniff(write.(@script)) == {:ok, :text}
    end

    test "reads an empty file as text", %{write: write} do
      assert FileSignature.sniff(write.("")) == {:ok, :text}
    end

    test "reads text whose first box-like word is at byte four as text", %{write: write} do
      assert FileSignature.sniff(write.("Hi! free software for everybody\n")) == {:ok, :text}
    end

    test "reads a sample cut inside a multi-byte character as text", %{write: write} do
      sample = String.duplicate("é", 3000) <> "é"
      cut = binary_part(sample, 0, byte_size(sample) - 1)

      assert FileSignature.sniff(write.(cut)) == {:ok, :text}
    end

    test "refuses binary it does not know", %{write: write} do
      assert FileSignature.sniff(write.(<<1, 2, 3, 255, 254>>)) == :error
      assert FileSignature.sniff(write.("text with a NUL " <> <<0>> <> " inside")) == :error
      assert FileSignature.sniff(write.("a bell " <> <<7>> <> " rang")) == :error
      assert FileSignature.sniff(write.(<<0xFF, 0xFE, "h", 0, "i", 0>>)) == :error
    end

    test "refuses a path that cannot be read" do
      assert FileSignature.sniff("/no/such/file/anywhere") == :error
      assert FileSignature.sniff(nil) == :error
    end
  end

  describe "kind/1" do
    test "names the kind of an extension, in any case and with or without its dot" do
      assert FileSignature.kind("png") == :png
      assert FileSignature.kind(".PNG") == :png
      assert FileSignature.kind(".jpeg") == :jpeg
      assert FileSignature.kind("docx") == :zip
      assert FileSignature.kind("csv") == :text
    end

    test "has no kind for a type a site must not serve back from its own origin" do
      for extension <- ~w(html htm svg xml js mjs xhtml shtml php exe) do
        assert FileSignature.kind(extension) == nil, "#{extension} must have no kind"
      end

      assert FileSignature.kind(nil) == nil
    end
  end

  describe "matches?/2" do
    test "is true when the bytes are the kind the extension names", %{write: write} do
      assert FileSignature.matches?(write.(@png), ".png")
      assert FileSignature.matches?(write.(@jpeg), "jpg")
      assert FileSignature.matches?(write.(@jpeg), ".JPEG")
      assert FileSignature.matches?(write.(@pdf), ".pdf")
      assert FileSignature.matches?(write.(@zip), ".docx")
      assert FileSignature.matches?(write.("one line\n"), ".txt")
    end

    # THE RENAME. A script written to a file called `x.png` is the whole attack.
    test "is false for a script, a page or an SVG given a picture's extension", %{write: write} do
      for content <- [@script, @svg, @html], extension <- ~w(.png .jpg .gif .webp .pdf .mp4) do
        refute FileSignature.matches?(write.(content), extension),
               "#{inspect(content)} passed as #{extension}"
      end
    end

    test "is false for a real picture named as another kind", %{write: write} do
      refute FileSignature.matches?(write.(@png), ".jpg")
      refute FileSignature.matches?(write.(@png), ".pdf")
      refute FileSignature.matches?(write.(@pdf), ".png")
      refute FileSignature.matches?(write.(@png), ".txt")
    end

    test "is false for an extension with no kind, whatever the bytes are", %{write: write} do
      refute FileSignature.matches?(write.(@png), ".svg")
      refute FileSignature.matches?(write.(@html), ".html")
      refute FileSignature.matches?(write.(@svg), ".svg")
      refute FileSignature.matches?(write.(@script), ".js")
    end
  end
end
