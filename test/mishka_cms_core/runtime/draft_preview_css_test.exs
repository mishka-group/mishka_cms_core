# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.DraftPreviewCssTest do
  @moduledoc """
  The temporary CSS of `/_preview/:resource/:token`, as `DraftPreviewAssets.css/2` compiles it.

  It is compiled from the record as it is on every call and kept nowhere, and a draft's own element
  CSS — the Custom CSS applied while the editor's stage said Draft — is laid over its page's
  element-CSS row the way the editor's publish writes it, so the preview shows the draft as it will
  be published.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import MishkaCmsCore.Test.Factory
  @moduletag :integration

  alias MishkaCmsCore.Runtime.Authoring.{Drafts, ElementCss}
  alias MishkaCmsCore.Runtime.DraftPreviewAssets
  alias MishkaCmsCore.Runtime.States.AssetsState

  setup do
    on_exit(fn -> AssetsState.delete("__shared_base__", "css") end)

    site = create_site!()
    page = create_page!(site_id: site.id, template: ~s(<h1 class="pb-aaaa1111">Hi</h1>))
    master = create_user_with_permissions!(["*"])
    owner = "page-#{page.id}"

    {:ok, _rules} =
      ElementCss.put(master, site.id, owner, "pb-aaaa1111", "color: red;\npadding: 3px;")

    {:ok, _rules} = ElementCss.put(master, site.id, owner, "pb-bbbb2222", "margin: 5px;")

    {:ok, site: site, page: page, master: master}
  end

  defp draft!(page, master, template, opts \\ []) do
    {:ok, draft} = Drafts.autosave("page", page, template, master, nil, nil, nil, opts)
    draft
  end

  # The preview's stylesheet, one Tailwind run over the site and the record.
  defp built({:ok, css}), do: css

  test "lays the draft's element CSS over its page's row, as the publish will", %{
    site: site,
    page: page,
    master: master
  } do
    draft =
      draft!(page, master, ~s(<h1 class="pb-aaaa1111">Hi</h1><p class="pb-cccc3333">x</p>),
        element_css: %{
          "pb-aaaa1111" => "color: crimson;",
          "pb-bbbb2222" => "",
          "pb-cccc3333" => "&:hover { color: navy; }"
        }
      )

    css = draft |> DraftPreviewAssets.css(site) |> built()

    # Tailwind writes `crimson` as its hex.
    assert css =~ ".pb-aaaa1111{color:#dc143c}"
    refute css =~ "color:red", "the row's older rule was compiled over the draft's"
    refute css =~ "padding:3px", "a declaration the draft took out stayed in the preview"
    refute css =~ ".pb-bbbb2222", "a rule the draft cleared stayed in the preview"
    assert css =~ ".pb-cccc3333:hover{color:navy}"
  end

  test "compiles the saved row as it is for a draft holding no element CSS, and for the page", %{
    site: site,
    page: page,
    master: master
  } do
    draft = draft!(page, master, ~s(<h1 class="pb-aaaa1111">Hi</h1>))

    assert draft |> DraftPreviewAssets.css(site) |> built() =~ "color:red"
    assert page |> DraftPreviewAssets.css(site) |> built() =~ "color:red"
  end

  test "is compiled from the draft as it is now, every time, and kept nowhere", %{
    site: site,
    page: page,
    master: master
  } do
    draft = draft!(page, master, ~s(<h1 class="mt-[31px]">Hi</h1>))
    assert draft |> DraftPreviewAssets.css(site) |> built() =~ ~S(.mt-\[31px\])

    {:ok, written} =
      Drafts.autosave("page", page, ~s(<h1 class="mt-[37px]">Hi</h1>), master, draft.id, nil, nil,
        element_css: %{"pb-dddd4444" => "outline: 1px solid teal;"}
      )

    css = written |> DraftPreviewAssets.css(site) |> built()

    assert css =~ ~S(.mt-\[37px\])
    assert css =~ ".pb-dddd4444{outline:1px solid teal}"
    refute AssetsState.exists?(draft.preview_token, "css")
  end

  # A record's markup is written to a temporary folder named after it for Tailwind to scan, and
  # removed after. Two compiles of one record side by side — the same link opened in two tabs —
  # would have the first remove the folder under the second, whose classes then had no rules.
  test "compiles one record at a time, so two opens at once both get its classes", %{
    site: site,
    page: page,
    master: master
  } do
    draft = draft!(page, master, ~s(<h1 class="mt-[41px]">Hi</h1>))

    [first, second] =
      for _open <- 1..2,
          do: Task.async(fn -> DraftPreviewAssets.css(draft, site) end)

    assert first |> Task.await(:timer.minutes(2)) |> built() =~ ~S(.mt-\[41px\])
    assert second |> Task.await(:timer.minutes(2)) |> built() =~ ~S(.mt-\[41px\])
  end

  test "answers :error for anything with no preview token" do
    assert DraftPreviewAssets.css(%{id: Ecto.UUID.generate()}, nil) == :error
  end
end
