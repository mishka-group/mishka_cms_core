# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.TestLayouts do
  @moduledoc """
  The outer HTML document for the standalone endpoint.

  A host supplies this — the CMS renders admin pages inside its own root layout, with its asset
  tags and theme attributes. None of that is this library's to own, so the harness provides the
  minimum a LiveView needs to mount: a document, a csrf token, and somewhere to put the page.

  `MishkaCmsCore.Layouts` (in `lib/`) is the *app* layout, which is this library's and is used as-is.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>MishkaCmsCore test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
