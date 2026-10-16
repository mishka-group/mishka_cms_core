# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.SnippetsTest do
  @moduledoc """
  The Studio's snippet store — the one thing in that sheet holding this install's own content rather
  than a registry's.

  Two rules carry the weight. A snippet is scoped, so a page's snippets do not leak into every other
  page and a site's do not leak into another site's editor. And what the panel shows about a snippet
  — how many blocks, how big — is read off the markup, so it cannot drift from what actually inserts.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.PageBuilder.Snippets

  @source ~S(<section class="hero"><h1>Hello</h1></section>)

  setup do
    site = create_site!()
    docs = %{1 => create_page!(site_id: site.id).id, 2 => create_page!(site_id: site.id).id}

    %{
      site: site,
      other_site: create_site!(),
      docs: docs,
      master: create_user_with_permissions!(["*"]),
      tenant: create_user_with_permissions!(["admin:dashboard:runtime:*"], site_id: site.id)
    }
  end

  # Written by a master, who names the site — `nil` offers it to every site.
  defp save(overrides) do
    %{name: "Hero", source: @source, section: :page, actor: create_user_with_permissions!(["*"])}
    |> Map.merge(Map.new(overrides))
    |> Snippets.save()
  end

  describe "save/1" do
    test "keeps the markup verbatim, so inserting one is an ordinary insert", %{
      site: site,
      master: master
    } do
      assert {:ok, snippet} = save(site_id: site.id)
      assert Snippets.source(snippet.id, master) == @source
    end

    test "a site user saves into their own site, and nobody saves nothing", %{
      site: site,
      tenant: tenant
    } do
      assert {:ok, snippet} = save(site_id: nil, actor: tenant)
      assert Snippets.source(snippet.id, tenant) == @source
      assert {:error, :forbidden} = save(site_id: site.id, actor: nil)
    end

    test "a snippet with no name is refused rather than saved unfindable", %{site: site} do
      assert {:error, :name_required} = save(name: "   ", site_id: site.id)
    end

    # A snippet that cannot be parsed cannot be inserted, and the failure would surface later, on a
    # different page, with nothing pointing back here.
    test "markup that does not parse is refused", %{site: site} do
      assert {:error, :unparseable} = save(source: "<div><span></div>", site_id: site.id)
    end

    test "an empty canvas has nothing to save", %{site: site} do
      assert {:error, :nothing_to_save} = save(source: "   ", site_id: site.id)
    end
  end

  describe "what the panel is told about a snippet" do
    test "blocks counts the top-level nodes, not every descendant", %{site: site} do
      {:ok, snippet} =
        save(source: "<div>one</div><div>two</div><div>three</div>", site_id: site.id)

      assert snippet.blocks == 3
    end

    test "size is the markup's own size", %{site: site} do
      {:ok, snippet} = save(site_id: site.id)

      assert snippet.size == "#{byte_size(@source)} B"
    end

    test "the swatch is stable for a name, so a row keeps its colour", %{site: site} do
      {:ok, first} = save(name: "Hero", site_id: site.id)
      {:ok, second} = save(name: "Hero", section: :layout, site_id: site.id)

      assert first.tint == second.tint
    end
  end

  describe "list/1 scoping" do
    test "another site's snippets are not offered", %{site: site, other_site: other} do
      {:ok, _mine} = save(name: "Mine", site_id: site.id)
      {:ok, _theirs} = save(name: "Theirs", site_id: other.id)

      names = site |> listed() |> Enum.map(& &1.name)

      assert names == ["Mine"]
    end

    # A global snippet is one no site owns, which is exactly what makes it insertable from every
    # site's editor.
    test "a snippet with no site is offered to every site", %{site: site, other_site: other} do
      {:ok, _global} = save(name: "Shared header", site_id: nil)

      assert "Shared header" in Enum.map(listed(site), & &1.name)
      assert "Shared header" in Enum.map(listed(other), & &1.name)
    end

    test "a page-scoped snippet stays beside its own document", %{site: site, docs: docs} do
      {:ok, _here} = save(name: "Here", scope: :page, document_id: docs[1], site_id: site.id)

      assert Enum.map(listed(site, docs[1]), & &1.name) == ["Here"]
      assert listed(site, docs[2]) == []
    end

    test "a shared snippet is offered whatever document is open", %{site: site, docs: docs} do
      {:ok, _anywhere} = save(name: "Anywhere", scope: :shared, site_id: site.id)

      assert Enum.map(listed(site, docs[2]), & &1.name) == ["Anywhere"]
    end

    # A layout's header markup is rarely what an error page wants.
    test "another editor's snippets are not offered", %{site: site} do
      {:ok, _layout} = save(name: "Layout bit", section: :layout, site_id: site.id)

      assert listed(site) == []
    end

    test "the Studio's chips narrow to page or shared", %{site: site, docs: docs} do
      {:ok, _page} = save(name: "Page one", scope: :page, document_id: docs[1], site_id: site.id)
      {:ok, _shared} = save(name: "Shared one", scope: :shared, site_id: site.id)

      assert Enum.map(listed(site, docs[1], "page"), & &1.name) == ["Page one"]
      assert Enum.map(listed(site, docs[1], "global"), & &1.name) == ["Shared one"]
      assert length(listed(site, docs[1], "all")) == 2
    end
  end

  describe "delete/2" do
    test "removes it from the list", %{site: site, master: master} do
      {:ok, snippet} = save(site_id: site.id)

      assert :ok = Snippets.delete(snippet.id, master)
      assert listed(site) == []
    end

    # The panel's delete button and a second tab can both be pointed at the same row.
    test "deleting one that is already gone says so", %{site: site, master: master} do
      {:ok, snippet} = save(site_id: site.id)

      assert :ok = Snippets.delete(snippet.id, master)
      assert {:error, :not_found} = Snippets.delete(snippet.id, master)
    end
  end

  describe "who may delete what" do
    # A site's author deletes their own site's snippets. Not a global one — that would take it from
    # every other site — and not another site's.
    test "a tenant deletes its own site's snippet", %{site: site, tenant: tenant} do
      {:ok, snippet} = save(site_id: site.id)

      assert :ok = Snippets.delete(snippet.id, tenant)
      assert listed(site) == []
    end

    # Another site's snippet is not one the tenant can read, so it is not there to delete.
    test "a tenant cannot delete another site's snippet", %{other_site: other, tenant: tenant} do
      {:ok, snippet} = save(site_id: other.id)

      assert {:error, :not_found} = Snippets.delete(snippet.id, tenant)
      assert [_still_there] = listed(other)
    end

    # Its own refusal, because a global snippet belongs to EVERY site rather than to another one —
    # the panel says so to the reader, and "belongs to another site" would be plainly wrong.
    test "a tenant cannot delete a global snippet", %{site: site, tenant: tenant} do
      {:ok, snippet} = save(site_id: nil)

      assert {:error, :shared_with_every_site} = Snippets.delete(snippet.id, tenant)
      assert [_still_there] = listed(site)
    end

    test "a master deletes any of them", %{site: site, other_site: other, master: master} do
      {:ok, own} = save(site_id: site.id)
      {:ok, elsewhere} = save(site_id: other.id)
      {:ok, global} = save(name: "Global one", site_id: nil)

      assert :ok = Snippets.delete(own.id, master)
      assert :ok = Snippets.delete(elsewhere.id, master)
      assert :ok = Snippets.delete(global.id, master)
    end

    # An id in a `phx-value-id` is not authority: with nobody named, nothing is deletable.
    test "no actor deletes nothing", %{site: site} do
      {:ok, snippet} = save(site_id: site.id)

      assert {:error, :not_found} = Snippets.delete(snippet.id, nil)
      assert [_still_there] = listed(site)
    end

    # The page area does not reach a layout's snippets.
    test "a tenant who may not open that snippet's builder cannot delete it", %{site: site} do
      {:ok, snippet} = save(section: :layout, site_id: site.id)

      page_builder =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert {:error, :not_found} = Snippets.delete(snippet.id, page_builder)
    end
  end

  describe "whose markup may be read" do
    test "a tenant reads its own and the global ones, not another site's", %{
      site: site,
      other_site: other,
      tenant: tenant
    } do
      {:ok, own} = save(site_id: site.id)
      {:ok, global} = save(name: "Global one", site_id: nil)
      {:ok, elsewhere} = save(site_id: other.id)

      assert Snippets.source(own.id, tenant) == @source
      assert Snippets.source(global.id, tenant) == @source
      assert Snippets.source(elsewhere.id, tenant) == nil
    end

    test "a master reads any of them", %{other_site: other, master: master} do
      {:ok, elsewhere} = save(site_id: other.id)

      assert Snippets.source(elsewhere.id, master) == @source
    end
  end

  defp listed(site, document_id \\ nil, filter \\ "all") do
    Snippets.list(%{
      site_id: site.id,
      section: :page,
      document_id: document_id,
      filter: filter,
      actor: create_user_with_permissions!(["*"])
    })
  end
end
