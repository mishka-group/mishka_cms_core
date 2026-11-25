# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ThemeSourceTest do
  @moduledoc """
  What a browser-side Tailwind generator is handed (`RuntimePreview.theme_source/1`, which the page
  builder's canvas styles a block with): the site's `@theme` and the variants its compile declares,
  so a `dark:` class reads the page's `data-theme` as the published CSS does, not the author's
  system setting.
  """
  use MishkaCmsCore.DataCase, async: true

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.Stylesheet

  test "the site's theme comes with the compile's own dark variant" do
    site = create_site!()

    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      %{
        name: "own-theme",
        kind: :theme,
        content: "@theme { --color-accent: #5b57d6; }",
        site_id: site.id
      },
      authorize?: false
    )
    |> Ash.create!()

    source = RuntimePreview.theme_source(site.id)

    assert source =~ "--color-accent: #5b57d6"
    assert source =~ "@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *));"
    assert String.starts_with?(source, TailwindCompiler.custom_variants())
  end
end
