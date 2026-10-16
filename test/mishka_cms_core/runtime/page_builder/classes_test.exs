# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.ClassesTest do
  @moduledoc """
  Reusable classes: the half the per-element style panel cannot do.

  What matters here is the CSS that comes out — two decisions in it are load-bearing and neither is
  obvious from the feature's description — and that the stylesheet row survives a round trip, since
  the row IS the record.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Classes
  alias MishkaCmsCore.Runtime.Stylesheet

  require Ash.Query

  setup do
    site = create_site!(name: "classes-test", host: "classes.test", active: true, master: true)
    %{site: site, master: create_user_with_permissions!(["*"])}
  end

  describe "css/1" do
    # `@apply`, because a class has to be written in the same vocabulary as everything else in this
    # editor. The row is `:custom`, which the compiler appends INTO the source Tailwind processes —
    # not after it — so this resolves.
    test "a class is Tailwind utilities, not hand-written CSS" do
      css = Classes.css([%{name: "card-shell", utilities: "rounded-xl bg-white p-6"}])

      assert css =~ "@apply rounded-xl bg-white p-6;"
      assert css =~ ".card-shell {"
    end

    # WITHOUT THE LAYER, source order decides: this row is appended last, so `.card-shell`'s padding
    # would quietly beat the `p-8` an author put on the one card that is meant to be the exception.
    test "it goes in the components layer, so a per-element utility still wins" do
      assert Classes.css([%{name: "a", utilities: "p-2"}]) =~ "@layer components {"
    end

    test "nothing to say means nothing written" do
      assert Classes.css([]) == ""
    end
  end

  describe "put/4 and all/2" do
    test "a class survives the round trip through the stylesheet row", %{
      site: site,
      master: master
    } do
      assert {:ok, _classes} = Classes.put(master, site.id, "card-shell", "rounded-xl p-6")
      assert Classes.all(master, site.id) == [%{name: "card-shell", utilities: "rounded-xl p-6"}]
    end

    test "saving the same name again rewrites it rather than adding a second", %{
      site: site,
      master: master
    } do
      Classes.put(master, site.id, "card-shell", "p-6")
      Classes.put(master, site.id, "card-shell", "p-8")

      assert Classes.all(master, site.id) == [%{name: "card-shell", utilities: "p-8"}]
    end

    test "several live in the one row", %{site: site, master: master} do
      Classes.put(master, site.id, "card-shell", "p-6")
      Classes.put(master, site.id, "lede", "text-lg")

      assert length(Classes.all(master, site.id)) == 2
    end

    # A NAME IS WRITTEN STRAIGHT INTO A STYLESHEET. `.my class` and `.my<script>` are the two ways
    # that goes wrong.
    test "a name that is not a CSS class is refused", %{site: site, master: master} do
      for name <- ["My Class", "my<script>", "", "9lives", "a"] do
        assert {:error, message} = Classes.put(master, site.id, name, "p-6")
        assert is_binary(message)
      end
    end

    test "empty utilities delete the class rather than leaving a rule that does nothing", %{
      site: site,
      master: master
    } do
      Classes.put(master, site.id, "card-shell", "p-6")

      assert {:ok, []} = Classes.put(master, site.id, "card-shell", "  ")
      assert Classes.all(master, site.id) == []
    end

    test "delete/3 removes one and leaves the rest", %{site: site, master: master} do
      Classes.put(master, site.id, "one", "p-1")
      Classes.put(master, site.id, "two", "p-2")

      assert {:ok, _left} = Classes.delete(master, site.id, "one")
      assert Classes.all(master, site.id) == [%{name: "two", utilities: "p-2"}]
    end

    test "a site with none has none", %{site: site, master: master} do
      assert Classes.all(master, site.id) == []
    end
  end

  # A CLASS THAT DOES NOT COMPILE IS NOT A BAD CLASS, IT IS A BROKEN SITE. The row is `:custom`, so
  # the compiler puts it INSIDE the source Tailwind processes, and Tailwind v4 answers `@apply` of a
  # utility it does not know by exiting non-zero — which the compiler raises on. Nothing is stored,
  # for that write and for every later stylesheet, page or component write too, because each
  # recompile reads the same stored row again.
  describe "put/4 refuses utilities the stylesheet cannot survive" do
    test "an unknown utility is refused in Tailwind's own words, and nothing is stored", %{
      site: site,
      master: master
    } do
      assert {:error, message} = Classes.put(master, site.id, "card", "rounde-xl")

      assert message =~ "rounde-xl",
             "the author has to be told WHICH utility, or the box has nothing to say"

      assert Classes.all(master, site.id) == []
    end

    test "a typo does not take the classes already saved with it", %{site: site, master: master} do
      assert {:ok, _classes} = Classes.put(master, site.id, "good", "p-6")
      assert {:error, _message} = Classes.put(master, site.id, "bad", "p6")

      assert Classes.all(master, site.id) == [%{name: "good", utilities: "p-6"}]
    end

    # A `}` CLOSES THE RULE AND EVERYTHING AFTER IT IS THE WHOLE SITE. `bg-white; } body { display:
    # none` is syntactically valid CSS once it is written into `@layer components`, so the compiler
    # would never object — this is the check `ElementCss.valid_body/1` makes for the same reason. The
    # `;` on its own is refused too: it ends the `@apply`, so `parse/1` reads back less than was
    # stored and the next save drops the rest.
    test "a brace or a semicolon is refused before anything is compiled", %{
      site: site,
      master: master
    } do
      for utilities <- ["bg-white; } body { display: none", "bg-white }", "p-6; color: red"] do
        assert {:error, message} = Classes.put(master, site.id, "card", utilities)
        assert is_binary(message)
      end

      assert Classes.all(master, site.id) == []
    end

    test "a paste of a whole stylesheet into the box is refused", %{site: site, master: master} do
      assert {:error, message} =
               Classes.put(master, site.id, "card", String.duplicate("p-6 ", 200))

      assert message =~ "500"
    end

    # NOT `Tokens.sane_value/1`'s reject list. A token value is one CSS value; these are utilities,
    # and the legitimate ones carry brackets, parens, quotes and slashes.
    test "an arbitrary-value utility is a real utility and is accepted", %{
      site: site,
      master: master
    } do
      utilities = "bg-[url('/a.png')] grid-cols-[repeat(2,minmax(0,1fr))] hover:bg-white/50"

      assert {:ok, _classes} = Classes.put(master, site.id, "hero", utilities)
      assert Classes.all(master, site.id) == [%{name: "hero", utilities: utilities}]
    end

    # THE CHECK RUNS THE COMPILER, so it has to run it the way every other compile runs it. The
    # verify input used to omit the `@custom-variant` block and the heroicons `@plugin` that the
    # shared-base, site, preview and static-base inputs all carry, so it refused — in Tailwind's
    # voice, as if the author had made a typo — the two vocabularies this CMS ships: `hero-bell` and
    # `phx-submit-loading:`. Both saved before the check existed.
    test "a variant this app defines is a real utility and is accepted", %{
      site: site,
      master: master
    } do
      assert {:ok, _classes} =
               Classes.put(master, site.id, "busy", "phx-submit-loading:opacity-50 dark:bg-black")

      assert Classes.all(master, site.id) == [
               %{name: "busy", utilities: "phx-submit-loading:opacity-50 dark:bg-black"}
             ]
    end

    # A ROW THAT IS ALREADY BROKEN IS NOT THIS SAVE'S FAULT. Rows holding a typo predate this check
    # and the Stylesheets page invites hand-editing this one, so verifying the whole row would let
    # one bad class veto every unrelated save — and the empty box that is how a class is deleted.
    test "a class already in the row that does not compile blocks nothing", %{
      site: site,
      master: master
    } do
      assert {:ok, _classes} = Classes.put(master, site.id, "good", "p-6")
      hand_edited(master, site.id, [%{name: "card", utilities: "rounde-xl"}])

      assert {:ok, _classes} = Classes.put(master, site.id, "lede", "text-lg")
      assert %{name: "lede", utilities: "text-lg"} in Classes.all(master, site.id)

      assert {:ok, left} = Classes.put(master, site.id, "card", "")
      refute Enum.any?(left, &(&1.name == "card"))
    end
  end

  # What the Stylesheets admin page does, and what every row written before the check existed holds:
  # the row IS the record, so a class typed there by hand is a class here — bad ones included.
  defp hand_edited(master, site_id, classes) do
    Stylesheet
    |> Ash.Query.filter(name == ^Classes.row_name() and site_id == ^site_id)
    |> Ash.Query.for_read(:master_read, %{}, actor: master)
    |> Ash.read!()
    |> Map.fetch!(:results)
    |> hd()
    |> Ash.Changeset.for_update(:master_update, %{content: Classes.css(classes)},
      actor: master,
      tenant: nil
    )
    |> Ash.update!()
  end

  # THE GLOBALS ARE THE CASE WITH TEETH. A class saved while editing a shared document is a
  # `site_id: nil` row, which the compiler folds into the shared base every site's bundle is built
  # on — and a failed shared base is answered with `""`, so one typo on one shared document empties
  # the base for every site on the installation.
  describe "the shared base, compiled for real" do
    @tag :integration
    test "survives a typo, and carries a class that is saved", %{master: master} do
      TailwindCompiler.ensure_installed()

      assert {:error, _message} = Classes.put(master, nil, "shared-card", "rounde-xl")
      assert Classes.all(master, nil) == []

      assert {:ok, _classes} = Classes.put(master, nil, "shared-card", "p-[43px]")
      assert {:ok, base} = TailwindCompiler.compile_shared_base()

      assert base =~ "43px",
             "the class is not in the shared base, so `css/1` is not what the compiler reads"
    end
  end

  # ONE RESERVED NAME, ONE ROW PER SITE. The identity is `[:name, :site_id]`, so `builder-classes`
  # names a row on every site and on the globals, and a read that says only the name has to be told
  # which of them it wants.
  #
  # EVERY TEST HERE USES MORE THAN TWO SCOPES, on purpose. A master's read is paginated, so a cap of
  # one comes back as two rows — the extra is how the page answers "is there more?" — and a pair of
  # sites therefore both fit inside a capped read and prove nothing. Three sites and the globals do
  # not fit, so at least one of them is answered with somebody else's row however the database
  # orders them.
  describe "a site's classes are its own" do
    setup %{site: site} do
      more =
        for index <- 1..2 do
          create_site!(
            name: "classes-test-#{index}",
            host: "classes-#{index}.test",
            active: true
          )
        end

      %{sites: [site | more], tenant: create_user_with_permissions!(["*"], site_id: site.id)}
    end

    test "each site reads back its own row, and so do the globals", %{
      sites: sites,
      master: master
    } do
      for {site, index} <- Enum.with_index(sites) do
        assert {:ok, _classes} = Classes.put(master, site.id, "card-#{index}", "p-#{index}")
      end

      assert {:ok, _classes} = Classes.put(master, nil, "card-shared", "p-9")

      for {site, index} <- Enum.with_index(sites) do
        assert Classes.all(master, site.id) == [%{name: "card-#{index}", utilities: "p-#{index}"}],
               "site #{index} was answered with another scope's row"
      end

      assert Classes.all(master, nil) == [%{name: "card-shared", utilities: "p-9"}]
    end

    # A SITE WHOSE CLASSES READ BACK EMPTY CANNOT SAVE EITHER. The next save believes there is no
    # row to add to, creates one, and meets the row that is already there — which the author sees as
    # the resource's own "Stylesheet name must be unique within a site".
    test "a second save on a site rewrites its row rather than colliding with it", %{
      sites: sites,
      master: master
    } do
      for site <- sites do
        assert {:ok, _classes} = Classes.put(master, site.id, "card", "p-1")
      end

      for {site, index} <- Enum.with_index(sites) do
        assert {:ok, _classes} = Classes.put(master, site.id, "card", "p-2"),
               "the second save on site #{index} did not land on the row it wrote first"
      end

      for site <- sites do
        assert Classes.all(master, site.id) == [%{name: "card", utilities: "p-2"}]
      end
    end

    # A DELETE OFF A ROW NOBODY FOUND IS A WRITE OF NOTHING: `all/2` answers `[]`, the rewrite has
    # no row to rewrite, and the class stays on screen and on the elements wearing it.
    test "delete/3 removes the class rather than writing nothing", %{
      sites: sites,
      master: master
    } do
      for site <- sites do
        assert {:ok, _classes} = Classes.put(master, site.id, "one", "p-1")
        assert {:ok, _classes} = Classes.put(master, site.id, "two", "p-2")
      end

      for {site, index} <- Enum.with_index(sites) do
        assert {:ok, _left} = Classes.delete(master, site.id, "one")

        assert Classes.all(master, site.id) == [%{name: "two", utilities: "p-2"}],
               "the delete on site #{index} wrote nothing"
      end
    end

    # WHERE THE GLOBALS SIT, WHICH IS NOT INSIDE A TENANT'S READ. `global? true` makes the tenant
    # optional; it does not fold the globals in, and Ash scopes a tenant's read to `site_id ==
    # ^tenant` regardless. So a shared class saved on a global layout is a row of its own, read on
    # its own, and the scoping the fix added is for the master's read. This pins that contract — it
    # is not the guard for the defect, which the three-scope tests above are.
    test "a tenant reads its own site's row, and the globals are read separately", %{
      sites: [site | _rest],
      master: master,
      tenant: tenant
    } do
      assert {:ok, _classes} = Classes.put(master, nil, "shared-card", "p-8")
      assert {:ok, _classes} = Classes.put(master, site.id, "site-card", "p-6")

      assert Classes.all(tenant, site.id) == [%{name: "site-card", utilities: "p-6"}]
      assert Classes.all(master, nil) == [%{name: "shared-card", utilities: "p-8"}]
    end
  end
end
