# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.ElementCssApplyTest do
  @moduledoc """
  An element's CSS that holds an `@apply` is built by Tailwind for its site before it is taken
  (`ElementCss.place/4`, `put/5` and a draft's `element_css`), and refused in Tailwind's words.

  The parser takes every body here. Tailwind failed every stylesheet a refused one was in: the
  canvas's in-browser build, the draft preview's styles and, on publish, the site's CSS build.

  `async: false`: it runs the Tailwind binary over the site's stylesheet rows.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Authoring.Drafts
  alias MishkaCmsCore.Runtime.Authoring.ElementCss
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Serializer
  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.Helpers
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Stylesheet

  @moduletag :integration

  @scope "pb-11112222"
  @empty "`@apply` names no utility. Write one after it, like `@apply p-4`."

  setup do
    TailwindCompiler.ensure_installed()
    %{site: create_site!(), master: create_user_with_permissions!(["*"])}
  end

  test "an @apply Tailwind cannot build is refused, in its words", %{site: site} do
    for {body, message} <- [
          {"@apply p-4\ncolor: red;", "Cannot apply unknown utility class `color:`"},
          {"@apply not-a-real-class;", "Cannot apply unknown utility class `not-a-real-class`"},
          {"@apply p-4 !important;", "Cannot apply unknown utility class `!important`"},
          {"@apply;", @empty},
          {"@apply ;", @empty}
        ] do
      assert ElementCss.place(%{}, @scope, body) == {:ok, %{@scope => body}}, body
      assert ElementCss.place(%{}, @scope, body, site.id) == {:error, message}, body
    end
  end

  test "an @apply Tailwind builds is kept", %{site: site} do
    for body <- [
          "@apply p-4",
          "padding: 4px;\n@apply p-4",
          "&:hover { @apply p-4 }",
          "@apply hover:underline md:p-8 text-red-500;"
        ] do
      assert ElementCss.place(%{}, @scope, body, site.id) == {:ok, %{@scope => body}}, body
    end
  end

  # `bg-accent` is a utility on this site only: its own theme row defines `--color-accent`.
  test "an @apply is built with the site's own theme", %{site: site} do
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

    assert {:ok, _rules} = ElementCss.place(%{}, @scope, "@apply bg-accent;", site.id)

    assert ElementCss.place(%{}, @scope, "@apply bg-accent;", nil) ==
             {:error, "Cannot apply unknown utility class `bg-accent`"}
  end

  test "the live row and a draft refuse it before anything is written", %{
    site: site,
    master: master
  } do
    body = "@apply not-a-real-class;"
    message = "Cannot apply unknown utility class `not-a-real-class`"

    assert ElementCss.put(master, site.id, "page-apply", @scope, body) == {:error, message}
    assert ElementCss.all(master, site.id, "page-apply") == %{}

    page = create_page!(site_id: site.id)

    assert {:error, error} =
             Drafts.autosave("page", page, "<p>one</p>", master, nil, nil, nil,
               element_css: %{@scope => body}
             )

    assert Exception.message(error) =~ message
  end

  # A SCOPE CLASS IS NEVER A UTILITY. This id hashes to `29496066…`, and Tailwind reads a page that
  # wears `pb-29496066` as asking for 29496066 spacing steps of padding-bottom, which made the
  # element millions of pixels tall on the canvas, in the preview and on the live page.
  test "the site's stylesheet holds the element's rule and no padding for its class", %{
    site: site,
    master: master
  } do
    id = "nh2wv4v6l"
    {:ok, tree} = Tree.parse(~s(<p></p>))
    [root] = tree.roots
    tree = %Tree{nodes: %{id => %{Tree.get(tree, root) | id: id}}, roots: [id]}
    {tree, scope} = Tree.ensure_scope(tree, id)

    BootHandler.create_template_file(site.name, "page", "home", Serializer.serialize(tree))

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn ->
      SiteState.delete(site.id)
      AssetsState.delete("__shared_base__", "css")
      File.rm_rf(Helpers.static_temp_dir(["runtime", site.name]))
    end)

    assert {:ok, _rules} =
             ElementCss.put(master, site.id, "page-scope", scope, "&:hover { @apply p-4 }")

    assert {:ok, css} = TailwindCompiler.compile(site.name)

    assert css =~ ".#{scope}"
    refute css =~ "padding-bottom:calc(var(--spacing)"
  end
end
