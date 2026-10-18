# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.FileSignature do
  @moduledoc """
  What a file is, read from its first bytes instead of from the name or the type its sender gave it.

  A file name and a MIME type are claims made by whoever uploaded the file. The first bytes are what
  the file is, so every upload that a site serves back from its own origin is checked here before it
  is stored: `MishkaCmsCore.Runtime.Media` for the media library and
  `MishkaCmsCore.Runtime.PageUpload` for a visitor's files.

  ## Kinds

  A kind is a family of formats that share a signature:

  | Kind | Extensions | First bytes |
  |---|---|---|
  | `:png` | `png` | the PNG signature |
  | `:jpeg` | `jpg`, `jpeg` | `FF D8 FF` |
  | `:gif` | `gif` | `GIF87a` or `GIF89a` |
  | `:webp` | `webp` | `RIFF`, four bytes, `WEBP` |
  | `:pdf` | `pdf` | `%PDF-` |
  | `:iso_media` | `mp4`, `mov` | a box size under 16 MB, then an ISO base media box name (`ftyp`, `moov`, `mdat`, ...) |
  | `:matroska` | `webm` | the EBML header `1A 45 DF A3` |
  | `:ole2` | `doc`, `xls`, `ppt` | the OLE2 compound file header |
  | `:zip` | `docx`, `xlsx`, `pptx`, `odt`, `ods`, `zip` | `PK` and a local file header |
  | `:text` | `txt`, `csv` | valid UTF-8 with no NUL byte and no control character but tab and line breaks |

  An extension that is not in the table has no kind, so nothing matches it: `html`, `htm`, `svg`,
  `xml` and `js` are never a kind, and the bytes of a script do not become a picture by being
  named `.png`.
  """

  @head_bytes 4096

  @kinds %{
    "png" => :png,
    "jpg" => :jpeg,
    "jpeg" => :jpeg,
    "gif" => :gif,
    "webp" => :webp,
    "pdf" => :pdf,
    "mp4" => :iso_media,
    "mov" => :iso_media,
    "webm" => :matroska,
    "doc" => :ole2,
    "xls" => :ole2,
    "ppt" => :ole2,
    "docx" => :zip,
    "xlsx" => :zip,
    "pptx" => :zip,
    "odt" => :zip,
    "ods" => :zip,
    "zip" => :zip,
    "txt" => :text,
    "csv" => :text
  }

  @iso_boxes ["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot"]

  @controls for byte <- Enum.to_list(0..8) ++ [11] ++ Enum.to_list(14..31) ++ [127], do: <<byte>>

  @type kind ::
          :png
          | :jpeg
          | :gif
          | :webp
          | :pdf
          | :iso_media
          | :matroska
          | :ole2
          | :zip
          | :text

  @doc """
  The kind an extension belongs to, with or without its dot and in any case, or `nil` for one that
  is not in the table.
  """
  @spec kind(String.t()) :: kind() | nil
  def kind(extension) when is_binary(extension) do
    extension |> String.trim_leading(".") |> String.downcase() |> then(&Map.get(@kinds, &1))
  end

  def kind(_extension), do: nil

  @doc """
  The kind of the file at `path`, read from its first bytes. `:error` when the file cannot be read
  or is none of the kinds in the table.
  """
  @spec sniff(Path.t()) :: {:ok, kind()} | :error
  def sniff(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @head_bytes)) do
      {:ok, head} when is_binary(head) -> classify(head)
      {:ok, :eof} -> classify(<<>>)
      _unreadable -> :error
    end
  end

  def sniff(_path), do: :error

  @doc """
  Whether the file at `path` is what `extension` says: the extension has a kind and the first bytes
  of the file are that kind.
  """
  @spec matches?(Path.t(), String.t()) :: boolean()
  def matches?(path, extension) do
    case {kind(extension), sniff(path)} do
      {nil, _sniffed} -> false
      {kind, {:ok, kind}} -> true
      _other -> false
    end
  end

  defp classify(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: {:ok, :png}
  defp classify(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, :jpeg}
  defp classify(<<"GIF87a", _rest::binary>>), do: {:ok, :gif}
  defp classify(<<"GIF89a", _rest::binary>>), do: {:ok, :gif}
  defp classify(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: {:ok, :webp}
  defp classify(<<"%PDF-", _rest::binary>>), do: {:ok, :pdf}
  defp classify(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: {:ok, :matroska}

  defp classify(<<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, _rest::binary>>),
    do: {:ok, :ole2}

  defp classify(<<"PK", 0x03, 0x04, _rest::binary>>), do: {:ok, :zip}

  defp classify(<<0, _size::binary-size(3), box::binary-size(4), _rest::binary>>)
       when box in @iso_boxes,
       do: {:ok, :iso_media}

  defp classify(head) do
    case text?(head) do
      true -> {:ok, :text}
      false -> :error
    end
  end

  defp text?(head), do: :binary.match(head, @controls) == :nomatch and plain_utf8?(head)

  # A sample cut in the middle of a character is still text; one that is not UTF-8 is not.
  defp plain_utf8?(head) do
    case :unicode.characters_to_binary(head, :utf8) do
      binary when is_binary(binary) -> true
      {:incomplete, _converted, _rest} -> true
      {:error, _converted, _rest} -> false
    end
  end
end
