# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Builder.Paths do
  @moduledoc """
  The visual editor's addresses, spelled in one place.

  The editor owns how its own routes are written; the rest of the admin asks for them through
  `runtime:document:editor_url` (`MishkaCmsCore.Runtime.PageBuilder.Section.editor_url/3`), which
  `MishkaCmsCore.Runtime.PageBuilder.Plugins.EditorUrl` answers from `builder_path/3`. Inside the
  editor — the error page's status strip, a component's own editor opened from a page, the share
  link, a mention's notification — the same function writes every address, and `back_path/2`
  honours only what it writes.
  """

  alias MishkaCmsCore.Runtime.ErrorStatus
  alias MishkaCmsCore.Runtime.PageBuilder.Section

  @builder "/admin/dashboard/runtime/builder/"

  @doc """
  The builder's address for one document, or for making a new one when `id` is `nil`.

  `status` names the error-page entry being edited. Without it an error page reopens on its 404
  entry, which is not the one the author left.

  THE ONE SPELLING. `back_path/2` honours an address by this prefix, so an address written out by
  hand somewhere else is one the two could disagree about.
  """
  @spec builder_path(String.t() | atom(), String.t() | nil, ErrorStatus.t() | nil) :: String.t()
  def builder_path(section, id \\ nil, status \\ nil)

  def builder_path(section, nil, _status), do: @builder <> Section.normalize(section)

  def builder_path(section, id, nil), do: builder_path(section) <> "/" <> id

  def builder_path(section, id, status),
    do: builder_path(section, id) <> "?" <> URI.encode_query(%{"status" => status})

  @doc """
  Where the builder's back link goes: `return_to` when it names another builder, the section's list
  otherwise.

  THE ADDRESS IS SOMETHING A URL SUPPLIED, so it is matched on the builder's own prefix rather than
  trusted. That prefix starts with a single `/`, which is what rules out `//elsewhere.example` and
  `https://elsewhere.example` — a back link that could be pointed off-site is an open redirect with
  the admin's session behind it.
  """
  @spec back_path(String.t(), String.t() | nil) :: String.t()
  def back_path(_section, @builder <> _document = return_to), do: return_to
  def back_path(section, _return_to), do: Section.list_path(section)
end
