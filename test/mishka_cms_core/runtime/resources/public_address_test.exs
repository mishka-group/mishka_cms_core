defmodule MishkaCmsCore.Runtime.Resources.PublicAddressTest do
  @moduledoc """
  A page is refused when its public address cannot be what it says, or is one another page of its
  site already answers at — compared as the site builds addresses with its first language
  unprefixed, so a site that switches URL modes finds no page hidden behind another.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Settings

  @every_language %{"serves_all_languages" => true}

  setup do
    site = create_site!()
    forget_settings(~w(site.languages site.language_urls), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
    %{site: site, admin: admin}
  end

  defp create(site, attrs) do
    Page
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: "page-#{System.unique_integer([:positive])}",
          title: "A page",
          template: "<div>page</div>",
          language: "en",
          active: true
        },
        attrs
      ),
      tenant: site.id,
      authorize?: false,
      context: %{page_code: :package}
    )
    |> Ash.create()
  end

  defp message({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.map_join(errors, " ", &Exception.message/1)

  describe "a page answering every language" do
    test "is refused on a path that captures no lang", %{site: site} do
      result = create(site, %{path: "/journal", extra: @every_language})

      assert message(result) =~ "Only a path with :lang in it can answer every language"
    end

    test "is written on a path that captures one", %{site: site} do
      assert {:ok, _page} = create(site, %{path: "/:lang/journal", extra: @every_language})
    end
  end

  describe "an address another page answers at" do
    test "is refused under the primary language, with or without its prefix", %{site: site} do
      assert {:ok, _about} = create(site, %{path: "/about", title: "About us"})

      # The editor is told which page holds the address, and where that page is stored.
      assert message(create(site, %{path: "/en/about"})) =~
               "The page “About us” at /about already answers at /about"
    end

    test "is refused in prefix_all too, since switching modes would join the two", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)
      assert {:ok, _about} = create(site, %{path: "/en/about", title: "About"})

      assert message(create(site, %{path: "/about"})) =~
               "The page “About” at /en/about already answers at /about"
    end

    test "is refused where a pattern answers that language", %{site: site} do
      assert {:ok, _guide} =
               create(site, %{path: "/:lang/guide", title: "Guide", extra: @every_language})

      assert message(create(site, %{path: "/fa/guide", language: "fa"})) =~
               "The page “Guide” at /:lang/guide already answers at /fa/guide"

      assert message(create(site, %{path: "/guide"})) =~
               "The page “Guide” at /:lang/guide already answers at /guide"
    end

    test "is not refused where a pattern answers another language alone", %{site: site} do
      assert {:ok, _about} = create(site, %{path: "/:lang/about"})
      assert {:ok, _fa} = create(site, %{path: "/fa/about", language: "fa"})
    end

    test "leaves a pattern with another capture to the resolver's precedence", %{site: site} do
      assert {:ok, _post} = create(site, %{path: "/:lang/post/:slug", extra: @every_language})
      assert {:ok, _new} = create(site, %{path: "/post/new"})
    end

    test "counts only active pages, and is asked again when one is switched on", %{
      site: site,
      admin: admin
    } do
      assert {:ok, _about} = create(site, %{path: "/about"})
      assert {:ok, draft} = create(site, %{path: "/en/about", active: false})

      result =
        draft
        |> Ash.Changeset.for_update(:update, %{active: true}, tenant: site.id, actor: admin)
        |> Ash.update()

      assert message(result) =~ "already answers at /about"
    end

    test "is not a page's own address when it is saved again", %{site: site, admin: admin} do
      assert {:ok, about} = create(site, %{path: "/about"})

      assert {:ok, _saved} =
               about
               |> Ash.Changeset.for_update(:update, %{path: "/en/about"},
                 tenant: site.id,
                 actor: admin
               )
               |> Ash.update()
    end

    test "on another site is no concern of this one", %{site: site} do
      other = create_site!()
      forget_settings(~w(site.languages), [other.id])
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: other.id)

      assert {:ok, _about} = create(site, %{path: "/about"})
      assert {:ok, _elsewhere} = create(other, %{path: "/en/about"})
    end
  end
end
