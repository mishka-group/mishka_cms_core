defmodule MishkaCmsCore.Runtime.PageBuilder.ElementCssSitesTest do
  @moduledoc """
  Which site's row an element's CSS is read out of.

  `element_css_test.exs` reaches no database, so the read that finds the row is not exercised there
  at all. It is the read `MishkaCmsCore.Runtime.PageBuilder.Classes` makes — one reserved row name,
  an identity of `[:name, :site_id]`, and a master read that bypasses multitenancy — and it broke
  there by asking for ONE row before saying which site it was for.

  A document id is what names the row in the running builder, so two sites do not reach the same one
  by accident today. What these pin is the read itself: `row/3` is handed a site and must answer for
  that site, so the two modules cannot drift apart the next time one of them is touched.

  MORE THAN TWO SCOPES ON PURPOSE. A master's read is paginated, so a cap of one comes back as two
  rows — the extra is how the page answers "is there more?" — and a pair of sites therefore both fit
  inside a capped read and prove nothing.

  `async: false` — a global stylesheet row is visible to every site.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss

  @owner "page-shared"
  @scope "pb-11112222"
  @other "pb-33334444"

  setup do
    sites =
      for index <- 0..2 do
        create_site!(
          name: "element-css-#{index}",
          host: "element-css-#{index}.test",
          active: true,
          master: index == 0
        )
      end

    %{
      sites: sites,
      master: create_user_with_permissions!(["*"]),
      tenant: create_user_with_permissions!(["*"], site_id: hd(sites).id)
    }
  end

  describe "a document's element CSS is its site's" do
    test "each site reads back its own row, and so do the globals", %{
      sites: sites,
      master: master
    } do
      for {site, index} <- Enum.with_index(sites) do
        assert {:ok, _rules} = ElementCss.put(master, site.id, @owner, @scope, "gap: #{index}px;")
      end

      assert {:ok, _rules} = ElementCss.put(master, nil, @owner, @scope, "gap: 9px;")

      for {site, index} <- Enum.with_index(sites) do
        assert ElementCss.all(master, site.id, @owner) == %{@scope => "gap: #{index}px;"},
               "site #{index} was answered with another scope's row"
      end

      assert ElementCss.all(master, nil, @owner) == %{@scope => "gap: 9px;"}
    end

    # A ROW NOBODY FOUND IS A ROW THE NEXT WRITE TRIES TO CREATE, and it meets the one that is
    # already there — which the author sees as "Stylesheet name must be unique within a site".
    test "a second write rewrites the site's row rather than colliding with it", %{
      sites: sites,
      master: master
    } do
      for site <- sites do
        assert {:ok, _rules} = ElementCss.put(master, site.id, @owner, @scope, "gap: 1px;")
      end

      for {site, index} <- Enum.with_index(sites) do
        assert {:ok, _rules} = ElementCss.put(master, site.id, @owner, @scope, "gap: 2px;"),
               "the second write on site #{index} did not land on the row it wrote first"
      end

      for site <- sites do
        assert ElementCss.all(master, site.id, @owner) == %{@scope => "gap: 2px;"}
      end
    end

    # `sync/4` is what prunes a deleted element's rule when the document is saved. Off a row nobody
    # found it writes nothing, so the rule outlives the element and goes on being compiled.
    test "sync/4 rewrites the site's own row", %{sites: sites, master: master} do
      for {site, index} <- Enum.with_index(sites) do
        assert {:ok, _rules} = ElementCss.put(master, site.id, @owner, @scope, "gap: #{index}px;")
        assert {:ok, _rules} = ElementCss.put(master, site.id, @owner, @other, "gap: 9px;")
      end

      for {site, index} <- Enum.with_index(sites) do
        assert {:ok, _rules} =
                 ElementCss.sync(master, site.id, @owner, %{@scope => "gap: #{index}px;"})

        assert ElementCss.all(master, site.id, @owner) == %{@scope => "gap: #{index}px;"},
               "the sync on site #{index} wrote nothing"
      end
    end

    # WHERE THE GLOBALS SIT, WHICH IS NOT INSIDE A TENANT'S READ. `global? true` makes the tenant
    # optional; it does not fold the globals in, and Ash scopes a tenant's read to `site_id ==
    # ^tenant` regardless. So a row written on a global layout is read on its own, and the scoping
    # the fix added is for the master's read. This pins that contract — it is not the guard for the
    # defect, which the three-scope tests above are.
    test "a tenant reads its own site's row, and the globals are read separately", %{
      sites: [site | _rest],
      master: master,
      tenant: tenant
    } do
      assert {:ok, _rules} = ElementCss.put(master, nil, @owner, @scope, "gap: 8px;")
      assert {:ok, _rules} = ElementCss.put(master, site.id, @owner, @scope, "gap: 6px;")

      assert ElementCss.all(tenant, site.id, @owner) == %{@scope => "gap: 6px;"}
      assert ElementCss.all(master, nil, @owner) == %{@scope => "gap: 8px;"}
    end
  end
end
