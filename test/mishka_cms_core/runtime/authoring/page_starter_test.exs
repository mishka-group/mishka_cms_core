# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.PageStarterTest do
  @moduledoc """
  Creating a page without writing any HEEx, and what an empty one offers when it opens.

  The claim being pinned is a workflow, not a module: **create empty → open editor → build visually**
  used to be impossible because the create actions demanded a template, and the only way to get one
  was to type it. Each half is tested where it lives — the default in the Ash action so every caller
  gets it (form, API, seed), the structures in the vocabulary so the chooser and the tests agree.

  `async: false` — these go through the real create actions against the sandbox.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Authoring.PageStarter
  alias MishkaCmsCore.Runtime.Authoring.Tree

  setup do
    %{site: create_site!()}
  end

  defp create_page(site, attrs) do
    MishkaCmsCore.Runtime.Page
    |> Ash.Changeset.for_create(:create, attrs, tenant: site.id, authorize?: false)
    |> Ash.create()
  end

  describe "the blank document" do
    # A bare `<div></div>` collapses to nothing on screen, so there is nowhere to aim a drop. The
    # container has to have a size to be a target.
    test "is one container the editor can parse and the database will accept" do
      blank = PageStarter.blank()

      assert {:ok, tree} = Tree.parse(blank)
      assert length(tree.roots) == 1
      assert String.length(blank) >= 3, "pages.template has a length(template) >= 3 check"
      refute String.trim(blank) == ""
    end
  end

  describe "creating a page with no markup" do
    test "fills in the empty container rather than refusing", %{site: site} do
      assert {:ok, page} =
               create_page(site, %{name: "blank one", title: "Blank One", path: "/blank-one"})

      assert page.template == PageStarter.blank()
    end

    test "treats whitespace as none given", %{site: site} do
      assert {:ok, page} =
               create_page(site, %{
                 name: "spaces",
                 title: "Spaces",
                 path: "/spaces",
                 template: "   \n "
               })

      assert page.template == PageStarter.blank()
    end

    test "leaves a real template alone", %{site: site} do
      source = ~s(<section class="hero"><h1>Hello</h1></section>)

      assert {:ok, page} =
               create_page(site, %{
                 name: "written",
                 title: "Written",
                 path: "/written",
                 template: source
               })

      assert page.template == source
    end

    # The master action is a different action with its own validations; both had the same demand and
    # both have to have lost it, or a master creating a page is still made to write HEEx.
    test "the master action defaults it too", %{site: site} do
      assert {:ok, page} =
               MishkaCmsCore.Runtime.Page
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{
                   name: "master blank",
                   title: "Master Blank",
                   path: "/master-blank",
                   site_id: site.id
                 },
                 authorize?: false
               )
               |> Ash.create()

      assert page.template == PageStarter.blank()
    end

    # Components are the other document the builder edits, and the Add Component modal has the same
    # button. Nothing about the change is page-specific.
    test "a component with no markup gets the same container", %{site: site} do
      assert {:ok, component} =
               MishkaCmsCore.Runtime.Component
               |> Ash.Changeset.for_create(:create, %{name: "blank-box"},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()

      assert component.template == PageStarter.blank()
    end
  end

  describe "the starter structures" do
    test "every one parses into exactly one root the editor can insert" do
      for structure <- PageStarter.all() do
        assert {:ok, tree} = Tree.parse(structure.template),
               "#{structure.id} does not parse"

        assert length(tree.roots) == 1, "#{structure.id} must insert as one undoable thing"
      end
    end

    test "each is offered under a name and a description a non-developer can read" do
      for structure <- PageStarter.all() do
        refute structure.title == ""
        refute structure.description == ""
        assert structure.columns >= 1
      end
    end

    test "an unknown id is nil rather than a crash" do
      assert PageStarter.fetch("no-such-structure") == nil
      assert PageStarter.fetch("two").id == "two"
    end

    # The word "Layout" is taken: Runtime's Layout is a template that outlives every page using it.
    # Two unrelated things with one name in the same editor is how a word stops meaning anything.
    test "nothing here calls itself a layout" do
      words =
        PageStarter.all()
        |> Enum.flat_map(&[&1.title, &1.description])
        |> Enum.join(" ")
        |> String.downcase()

      refute words =~ "layout"
    end
  end

  describe "empty?/1" do
    test "a document with nothing in it is empty" do
      assert PageStarter.empty?(%Tree{roots: [], nodes: %{}})
    end

    # A page created with no markup arrives holding ONE container, because the column is NOT NULL
    # with a length check and a blank string would fail at the database. It has still not been
    # started, whatever the row says — so the chooser has to be offered there too.
    test "a page holding only its birth container is empty" do
      {:ok, tree} = Tree.parse(PageStarter.blank())
      assert PageStarter.empty?(tree)
    end

    # START FROM SCRATCH IS AN ANSWER TO THE CHOOSER. Read as a page nobody had started, the chooser
    # stayed up over the box the click had just put down, so the click looked like it did nothing.
    test "what Start from scratch leaves is a page someone has started" do
      {:ok, tree} = Tree.parse(PageStarter.scratch())
      refute PageStarter.empty?(tree)
    end

    # It is on the PUBLISHED page too. A `<main class="min-h-[200px]">` was a blank band above
    # everything placed after it, and a second `<main>` inside the layout's own.
    test "and it is one bare box, with nothing on it for the published page to size" do
      {:ok, tree} = Tree.parse(PageStarter.scratch())

      assert [root] = Enum.map(tree.roots, &Tree.get(tree, &1))
      assert root.kind == :tag
      refute root.tag == "main"
      assert root.attrs == []
      assert String.length(PageStarter.scratch()) >= 3, "pages.template has a length check"
    end

    test "an empty box that is not the one a page is born with is not" do
      for source <- [~s(<section></section>), ~s(<div class="grid"></div>), ~s(<main></main>)] do
        {:ok, tree} = Tree.parse(source)
        refute PageStarter.empty?(tree), "#{source} was put there by the author"
      end
    end

    test "anything actually on the page is not" do
      for source <- [
            ~s(<div><h1>Hello</h1></div>),
            ~s(<div></div><div></div>),
            ~s(<div>words</div>)
          ] do
        {:ok, tree} = Tree.parse(source)
        refute PageStarter.empty?(tree), "#{source} has content on it"
      end
    end
  end
end
