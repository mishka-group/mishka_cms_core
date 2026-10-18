# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Files do
  @moduledoc """
  The smallest bytes of each kind of file an upload is checked against.

  The media library and a visitor's upload read a file's first bytes
  (`MishkaCmsCore.Runtime.FileSignature`) and refuse one that is not what its name says, so a test
  that uploads `logo.png` has to write something that is a PNG. `png/0` is a complete 1x1 image;
  the others carry the signature of their kind and nothing else, which is all the check reads.

  `script/0`, `svg/0` and `html/0` are the files a stored-XSS attack uploads.
  """

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="
       )

  @doc "A 1x1 PNG."
  @spec png() :: binary()
  def png, do: @png

  @doc "The start of a JPEG."
  @spec jpeg() :: binary()
  def jpeg, do: <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>

  @doc "A GIF header."
  @spec gif() :: binary()
  def gif, do: <<"GIF89a", 1, 0, 1, 0, 0, 0, 0, 0x3B>>

  @doc "The start of a WebP."
  @spec webp() :: binary()
  def webp, do: <<"RIFF", 12, 0, 0, 0, "WEBPVP8 ", 0, 0, 0, 0>>

  @doc "The start of a PDF."
  @spec pdf() :: binary()
  def pdf, do: "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n"

  @doc "The start of an MP4."
  @spec mp4() :: binary()
  def mp4, do: <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>

  @doc "A page with a script in it."
  @spec html() :: binary()
  def html, do: "<!doctype html><html><body><script>alert(document.domain)</script></body></html>"

  @doc "An SVG that runs a script when it is opened."
  @spec svg() :: binary()
  def svg, do: ~s|<svg xmlns="http://www.w3.org/2000/svg" onload="alert(document.domain)"/>|

  @doc "A script."
  @spec script() :: binary()
  def script, do: "alert(document.domain)"
end
