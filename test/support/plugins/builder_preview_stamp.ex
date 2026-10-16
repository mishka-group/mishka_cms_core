# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderPreviewStamp do
  @moduledoc """
  A plugin that puts something of its own inside a preview — a staging banner, a locale marker, a
  measuring grid.

  This is the seam that lets an extension appear in a preview it does not own, and it fires wherever
  a preview document is assembled, so one plugin covers the editor and every runtime modal.
  """
  use MishkaInstaller.Event.Hook, event: "builder:preview:document"

  @marker "<!-- stamped by a plugin -->"

  @doc "What this plugin adds to the document."
  @spec marker() :: String.t()
  def marker, do: @marker

  @impl true
  def call(%{html: html} = payload) when is_binary(html),
    do: {:reply, %{payload | html: html <> @marker}}

  def call(payload), do: {:reply, payload}
end
