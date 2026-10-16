# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.PageTranslationsTest do
  @moduledoc """
  The pages table with translated pages in it, driven through the real page.

  A translation is a page row of its own, so a list of rows would show "about" beside "about-fa" —
  the same page twice. The table shows one row per page and a chip for each other language, a search
  lifts that so a Persian title can be found, and a row's "Add translation" makes the next edition
  through the page's own create action. A master's Delete, one row or a bulk selection, is refused
  while a live translation remains, its Delete permanently too, and a translation's Restore is
  refused while its master is archived — each time with the admin told why. A refused Delete comes
  with a button that archives, or deletes for good, those translations at once.

  See `MishkaCmsCore.Runtime.PageEditions` and `MishkaCmsCore.LanguageEditions`.
  """
  use MishkaCmsCore.ConnCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{Page, PageEditions}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCoreWeb.Live.Admin.Components.TranslationsRefusal

  require Ash.Query

  @password "Password123!"
  @url "/admin/dashboard/runtime/pages"
  @await 5_000
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    MishkaCmsCore.DataCase.forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)

    n = System.unique_integer([:positive])
    master = create_page!(site_id: site.id, name: "about-#{n}", path: "/about-#{n}")

    admin = create_admin("translations-#{n}@example.com")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(admin)

    {:ok, conn: conn, site: site, master: master, admin: admin}
  end

  defp translate!(site, master, language, overrides \\ []) do
    create_page!(
      [
        site_id: site.id,
        name: "#{master.name}-#{language}",
        path: "/#{language}#{master.path}",
        language: language,
        language_group_id: master.id
      ] ++ overrides
    )
  end

  defp open_pages(conn) do
    {:ok, view, _html} = live(conn, @url)
    render_async(view, @await)
    view
  end

  # A CHANGE REACHES THE TABLE AS A BROADCAST THE PAGE HANDS ON WITH `send_update/3`, which the page
  # runs after the render that delivered the broadcast — so it is the second render that shows it.
  defp settle(view) do
    render(view)
    render_async(view, @await)
    view
  end

  defp row(page), do: "#pages-table_pages-#{page.id}"
  defp chip(page), do: "#page-edition-#{page.id}"

  defp open_archive(conn) do
    view = open_pages(conn)

    view
    |> element(~s(button[phx-click="archive_filter"][phx-value-status="archived"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  # A page archived before language groups: its group is emptied first, because the database refuses
  # every write to an archived page but its restore.
  defp shelve!(page, site) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE pages SET language_group_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(page.id)]
    )

    page
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
    |> Ash.destroy!()

    Ash.get!(Page, page.id, action: :master_get_archived, authorize?: false)
  end

  # A master and a live Persian edition, made the way a master admin makes them: the full form's
  # `master_create`, the row's "Add translation", then the edit form's `master_update` to put the
  # edition live.
  defp translated!(site, admin) do
    n = System.unique_integer([:positive])

    master =
      Page
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "about-e2e-#{n}",
          title: "About e2e #{n}",
          path: "/en/about-e2e-#{n}",
          template: "<div>about</div>",
          language: "en",
          active: true,
          site_id: site.id
        },
        actor: admin
      )
      |> Ash.create!()

    {:ok, fa} = PageEditions.translate(master, "fa", "/fa/about-e2e-#{n}", admin)

    fa =
      fa
      |> Ash.Changeset.for_update(
        :master_update,
        %{active: true, template: "<div>darbare</div>"},
        actor: admin
      )
      |> Ash.update!()

    {master, fa}
  end

  # An archived master whose translation is still live: what the table's Delete left behind before
  # it was refused, and the state its "Delete permanently" is offered on.
  defp archived_under_live_translation!(site, admin) do
    {master, fa} = translated!(site, admin)

    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE pages SET archived_at = now(), active = false WHERE id = $1",
      [Ecto.UUID.dump!(master.id)]
    )

    {master, fa}
  end

  defp archive!(page, admin),
    do: Ash.destroy!(page, action: :master_destroy, actor: admin, return_destroyed?: true)

  defp live?(page),
    do:
      match?(
        {:ok, %{archived_at: nil}},
        Ash.get(Page, page.id, action: :master_get, authorize?: false)
      )

  defp stored?(page),
    do: match?({:ok, %Page{}}, Ash.get(Page, page.id, action: :master_get, authorize?: false))

  defp select(view, page) do
    view |> element(~s(#{row(page)} input[phx-click="toggle_select"])) |> render_click()
    view
  end

  defp bulk(view, action) do
    view
    |> element(~s(button[phx-click="bulk_action"][phx-value-action="#{action}"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  @alert "#translations-refusal-alert"
  @act "#translations-refusal-act"

  # THE ALERT ARRIVES AS AN UPDATE THE TABLE SENDS THE PAGE, run after the render that delivered the
  # click, and then reads what it shows off the page's process.
  defp refused(view) do
    render(view)
    render_async(view, @await)
    view
  end

  defp act(view) do
    view |> element(@act) |> render_click()
    view
  end

  # A site admin of `site`, signed in where the master admin is.
  defp tenant_conn(site) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> log_in(create_admin("site-#{System.unique_integer([:positive])}@example.com", site.id))
  end

  @refused "This is the original English version. Its Persian translation is still live, so it " <>
             "can't be deleted yet. Archive or delete that translation first, then this one."
  @restore_refused "This is the Persian translation. Its original English version is archived, so " <>
                     "it can't be restored yet. Restore the original first, then this one."

  defp group_of(page),
    do: Ash.get!(Page, page.id, action: :master_get, authorize?: false).language_group_id

  describe "the list" do
    test "shows a page once, with a chip for each other language", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      view = open_pages(conn)

      assert has_element?(view, "#pages-table_pages-#{master.id}")
      assert has_element?(view, "#page-edition-#{fa.id}")

      refute has_element?(view, "#pages-table_pages-#{fa.id}"),
             "the Persian edition took a row of its own beside its master"
    end

    test "lists a translation on its own once searched for", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      {:ok, view, _html} = live(conn, @url <> "?pages_search=#{fa.name}")
      render_async(view, @await)

      assert has_element?(view, "#pages-table_pages-#{fa.id}")
    end

    test "a chip opens that edition", %{conn: conn, site: site, master: master} do
      fa = translate!(site, master, "fa")
      view = open_pages(conn)

      view |> element(chip(fa)) |> render_click()
      render_async(view, @await)

      assert has_element?(
               view,
               ~s(#runtime-preview-modal a[href^="/admin/dashboard/runtime/builder/page/#{fa.id}?"])
             ),
             "the chip did not open the Persian edition"
    end
  end

  # THE TABLE PUTS A CHANGED ROW IN BY READING THAT ONE ROW, never through the hook that keeps the
  # list to one row per page — so each of these arrives while the list is already open.
  describe "the list, as pages change under it" do
    test "a translation added joins its master's row", %{conn: conn, site: site, master: master} do
      view = open_pages(conn)
      fa = translate!(site, master, "fa")
      settle(view)

      refute has_element?(view, row(fa)), "the new translation took a row of its own"
      assert has_element?(view, row(master))
      assert has_element?(view, chip(fa)), "the master's row kept the chips it was drawn with"
    end

    test "a translation activated stays in its master's row", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa", active: false)
      view = open_pages(conn)

      fa
      |> Ash.Changeset.for_update(:update, %{active: true}, tenant: site.id, authorize?: false)
      |> Ash.update!()

      settle(view)

      refute has_element?(view, row(fa))
      assert has_element?(view, chip(fa))
    end

    test "a translation archived leaves its master's chips", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      view = open_pages(conn)
      assert has_element?(view, chip(fa))

      fa
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      settle(view)

      refute has_element?(view, chip(fa))
      assert has_element?(view, row(master))
    end

    # THE MASTER IS REDRAWN THROUGH THE LIST'S OWN READ, filters included: filtered to inactive
    # pages, a change to an active page's translation does not draw that page into the list.
    test "a translation's change draws no master the list's filters leave out", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      n = System.unique_integer([:positive])

      inactive =
        create_page!(site_id: site.id, name: "draft-#{n}", path: "/draft-#{n}", active: false)

      {:ok, view, _html} = live(conn, @url <> "?pages_filter_active=false")
      render_async(view, @await)
      assert has_element?(view, row(inactive))
      refute has_element?(view, row(master))

      fa
      |> Ash.Changeset.for_update(:update, %{title: "Changed"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      settle(view)

      refute has_element?(view, row(master)), "the active master was drawn into an inactive list"
    end

    test "a page of its own still takes a row", %{conn: conn, site: site} do
      view = open_pages(conn)
      page = create_page!(site_id: site.id, path: "/own-#{System.unique_integer([:positive])}")
      settle(view)

      assert has_element?(view, row(page))
    end
  end

  # A MASTER IS ARCHIVED ONLY ONCE ITS TRANSLATIONS ARE, so an archive of masters would hide every
  # archived translation behind a row with no chip for it.
  describe "the archive" do
    test "lists an archived translation on its own row", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")

      fa
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      view = open_archive(conn)

      assert has_element?(view, row(fa))
    end

    test "lists a page archived before language groups, and restores it with one of its own", %{
      conn: conn,
      site: site,
      master: master
    } do
      shelve!(master, site)
      view = open_archive(conn)
      assert has_element?(view, row(master))

      view
      |> element(~s(#{row(master)} button[phx-value-event="unarchive"]))
      |> render_click()

      render_async(view, @await)

      assert group_of(master) == master.id
    end
  end

  # THE TABLE DESTROYS WITH THE RECORD AND NO `authorize?` — `Ash.destroy(record, action: ...)` — and
  # an archive called that way hands its validations `authorize?: false`. Each of these goes through
  # the button an admin presses: the admin is told why nothing happened, in an alert that offers to
  # archive — or delete for good — the translations in the way, and asks first, naming them.
  describe "deleting a page that has translations" do
    test "the row's Delete keeps a master whose translation is live, says why, and archives the translation at once",
         %{conn: conn, site: site, admin: admin} do
      {master, fa} = translated!(site, admin)
      view = open_pages(conn)

      view |> element(~s(#{row(master)} button[phx-click="delete"])) |> render_click()
      refused(view)

      assert live?(master), "the master was archived under its live translation"
      assert live?(fa)
      assert has_element?(view, @alert, @refused)

      refute has_element?(view, "#flash-error"),
             "the alert's reason was repeated as an error flash"

      assert has_element?(view, @act, "Archive the translations")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Persian translation of “#{master.title}”? You can restore it later."])
             )

      act(view)

      refute live?(fa), "the quick action left the translation live"

      assert stored?(fa),
             "the quick action deleted the translation for good instead of archiving it"

      assert live?(master), "the quick action archived the original too"

      assert has_element?(
               view,
               "#translations-refusal-done",
               "The Persian translation of “#{master.title}” is archived. You can delete “#{master.title}” now."
             )

      view |> element(~s(#{row(master)} button[phx-click="delete"])) |> render_click()

      refute live?(master)
      refute has_element?(view, "#flash-error")
    end

    test "the bulk Archive keeps a master whose translations are live, and archives them all at once",
         %{conn: conn, site: site, admin: admin} do
      {master, fa} = translated!(site, admin)
      ar = translate!(site, master, "ar")

      view = conn |> open_pages() |> select(master) |> bulk("archive")
      refused(view)

      assert live?(master), "the bulk archive archived the master under its live translation"

      assert has_element?(
               view,
               @alert,
               "This is the original English version. Its translations in Arabic and Persian are " <>
                 "still live, so it can't be deleted yet. Archive or delete those translations " <>
                 "first, then this one."
             )

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Arabic and Persian translations of “#{master.title}”? You can restore them later."])
             )

      act(view)

      refute live?(fa)
      refute live?(ar)
      assert live?(master)

      bulk(view, "archive")

      refute live?(master)
      refute has_element?(view, "#flash-error")
    end

    test "the bulk Archive says why when the selection holds other pages too", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, _fa} = translated!(site, admin)
      alone = create_page!(site_id: site.id, path: "/alone-#{System.unique_integer([:positive])}")

      view = conn |> open_pages() |> select(alone) |> select(master) |> bulk("archive")
      refused(view)

      assert live?(master)
      assert has_element?(view, @alert, @refused)
      assert has_element?(view, @act)
    end

    test "a master goes once its translation has", %{conn: conn, site: site, admin: admin} do
      {master, fa} = translated!(site, admin)

      {:ok, search, _html} = live(conn, @url <> "?pages_search=#{fa.name}")
      render_async(search, @await)
      search |> element(~s(#{row(fa)} button[phx-click="delete"])) |> render_click()
      refute live?(fa)

      view = open_pages(conn)
      view |> element(~s(#{row(master)} button[phx-click="delete"])) |> render_click()
      refused(view)

      refute live?(master)
      refute has_element?(view, "#flash-error")
      refute has_element?(view, @alert)
    end

    test "Delete permanently keeps an archived master whose translation is live, and deletes the translation for good at once",
         %{conn: conn, site: site, admin: admin} do
      {master, fa} = archived_under_live_translation!(site, admin)
      view = open_archive(conn)

      view
      |> element(~s(#{row(master)} button[phx-value-event="permanent_destroy"]))
      |> render_click()

      refused(view)

      assert stored?(master), "the master was deleted for good under its live translation"
      assert live?(fa)
      assert has_element?(view, @alert, @refused)
      refute has_element?(view, "#flash-error")
      assert has_element?(view, @act, "Delete the translations for good")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Delete the Persian translation of “#{master.title}” for good? This can't be undone."])
             )

      act(view)

      refute stored?(fa), "the quick action left the translation stored"
      assert stored?(master), "the quick action deleted the original too"

      assert has_element?(
               view,
               "#translations-refusal-done",
               "The Persian translation of “#{master.title}” is deleted for good. You can delete " <>
                 "“#{master.title}” for good now."
             )

      view
      |> element(~s(#{row(master)} button[phx-value-event="permanent_destroy"]))
      |> render_click()

      refute stored?(master)
    end

    test "the bulk Delete permanently keeps it too, and offers the same", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = archived_under_live_translation!(site, admin)

      view = conn |> open_archive() |> select(master) |> bulk("permanent_destroy")
      refused(view)

      assert stored?(master)
      assert has_element?(view, @alert, @refused)
      assert has_element?(view, @act, "Delete the translations for good")

      act(view)

      refute stored?(fa)
      assert stored?(master)
    end

    # THE ALERT NAMES WHAT WAS LIVE WHEN THE DELETE WAS REFUSED, and its button takes only those. A
    # translation added in the meantime stays, and the alert says it is still in the way instead of
    # saying the original can go.
    test "a translation added after the alert opened is left alone, and the alert offers it next",
         %{conn: conn, site: site, admin: admin} do
      {master, fa} = translated!(site, admin)
      view = open_pages(conn)

      view |> element(~s(#{row(master)} button[phx-click="delete"])) |> render_click()
      refused(view)

      ar = translate!(site, master, "ar")
      act(view)

      refute live?(fa)
      assert live?(ar), "the quick action archived a translation its confirm did not name"
      assert live?(master)

      assert has_element?(
               view,
               "#translations-refusal-done",
               "The Persian translation of “#{master.title}” is archived."
             )

      refute has_element?(view, "#translations-refusal-done", "You can delete"),
             "the alert said the original can go while its Arabic translation is live"

      assert has_element?(
               view,
               "#translations-refusal-message",
               "This is the original English version. Its Arabic translation is still live, so " <>
                 "it can't be deleted yet. Archive or delete that translation first, then this one."
             )

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Arabic translation of “#{master.title}”? You can restore it later."])
             )

      act(view)

      refute live?(ar)
      assert live?(master)

      assert has_element?(
               view,
               "#translations-refusal-done",
               "The Arabic translation of “#{master.title}” is archived. You can delete “#{master.title}” now."
             )

      refute has_element?(view, @act)

      view |> element(~s(#{row(master)} button[phx-click="delete"])) |> render_click()

      refute live?(master)
    end

    # A REFUSAL MAY NAME SEVERAL ORIGINALS. A table's bulk stops at its first refusal, so this one is
    # handed to the alert the way the table's hook hands it one.
    test "a refusal naming two originals says which can go now, and offers the one still held back",
         %{conn: conn, site: site, admin: admin} do
      {first, first_fa} = translated!(site, admin)
      {second, second_fa} = translated!(site, admin)
      view = open_pages(conn)

      Phoenix.LiveView.send_update(view.pid, TranslationsRefusal,
        id: "translations-refusal",
        refused: %{
          resource: Page,
          refused: [%{id: first.id, message: @refused}, %{id: second.id, message: @refused}]
        }
      )

      refused(view)

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Persian translation of “#{first.title}” and the Persian translation of “#{second.title}”? You can restore them later."])
             )

      second_ar = translate!(site, second, "ar")
      act(view)

      refute live?(first_fa)
      refute live?(second_fa)
      assert live?(second_ar), "the quick action archived a translation its confirm did not name"

      assert has_element?(
               view,
               "#translations-refusal-done",
               "The Persian translation of “#{first.title}” and the Persian translation of " <>
                 "“#{second.title}” are archived. You can delete “#{first.title}” now."
             )

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Arabic translation of “#{second.title}”? You can restore it later."])
             )

      act(view)

      refute live?(second_ar)
      assert live?(first)
      assert live?(second)

      assert has_element?(
               view,
               "#translations-refusal-done",
               "The Arabic translation of “#{second.title}” is archived. You can delete " <>
                 "“#{first.title}” and “#{second.title}” now."
             )
    end

    # A BUG IN READING WHAT THE BUTTON NEEDS crashes that read, off the page's process, and the crash
    # report is logged there. The admin is told the quick action is not coming instead of waiting on
    # it.
    test "says so when what its button needs could not be read", %{conn: conn} do
      view = open_pages(conn)

      capture_log(fn ->
        Phoenix.LiveView.send_update(view.pid, TranslationsRefusal,
          id: "translations-refusal",
          refused: %{resource: String, refused: [%{id: Ecto.UUID.generate(), message: @refused}]}
        )

        refused(view)
      end)

      assert has_element?(view, @alert, @refused)
      refute has_element?(view, @act)

      assert has_element?(
               view,
               "#translations-refusal-failed",
               "The quick action could not be loaded just now. Close this and try the delete again."
             )
    end

    test "the alert closes without touching anything", %{conn: conn, site: site, admin: admin} do
      {master, fa} = translated!(site, admin)
      view = open_pages(conn)

      view |> element(~s(#{row(master)} button[phx-click="delete"])) |> render_click()
      refused(view)
      view |> element("#translations-refusal-dismiss") |> render_click()

      refute has_element?(view, @alert)
      assert live?(fa)
      assert live?(master)
    end

    test "a site admin gets the same offer, and it archives their site's translation", %{
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      view = site |> tenant_conn() |> open_pages()

      view |> element(~s(#{row(master)} button[phx-click="delete"])) |> render_click()
      refused(view)

      assert has_element?(view, @alert, @refused)
      act(view)

      refute live?(fa)
      assert live?(master)
    end

    # THE BUTTON NOT BEING DRAWN IS NOT THE REFUSAL: an event is something a browser can be made to
    # send whatever the page drew. A site admin handed another site's original is told the reason it
    # came with, offered nothing, and acting anyway archives nothing.
    test "an admin who may not act on the translations is told why and offered nothing", %{
      site: site
    } do
      other = create_site!(name: "other-#{System.unique_integer([:positive])}")

      theirs =
        create_page!(site_id: other.id, path: "/theirs-#{System.unique_integer([:positive])}")

      their_fa = translate!(other, theirs, "fa")

      view = site |> tenant_conn() |> open_pages()

      Phoenix.LiveView.send_update(view.pid, TranslationsRefusal,
        id: "translations-refusal",
        refused: %{resource: Page, refused: [%{id: theirs.id, message: @refused}]}
      )

      refused(view)

      assert has_element?(view, @alert, @refused)
      refute has_element?(view, @act)

      view |> with_target("#translations-refusal") |> render_click("act", %{})

      assert live?(their_fa), "another site's translation was archived"
      assert live?(theirs)
    end

    # AN ARCHIVED TRANSLATION IS IN NOBODY'S WAY: what keeps it from outliving its master is its
    # Restore, below. Holding the master back for it would refuse the selection that empties the
    # archive of a whole group — the rows sit side by side there and go one at a time, so whichever
    # of them the read hands over first would decide whether the lot goes.
    test "Delete permanently takes an archived master whose translation is archived too", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      archive!(fa, admin)
      archive!(master, admin)
      view = open_archive(conn)

      view
      |> element(~s(#{row(master)} button[phx-value-event="permanent_destroy"]))
      |> render_click()

      refute stored?(master)
      assert stored?(fa)
      refute has_element?(view, "#flash-error")
    end

    test "the bulk Delete permanently empties whole archived groups", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      {other, other_fa} = translated!(site, admin)
      Enum.each([fa, master, other_fa, other], &archive!(&1, admin))

      view =
        conn
        |> open_archive()
        |> select(master)
        |> select(fa)
        |> select(other)
        |> select(other_fa)
        |> bulk("permanent_destroy")

      refute stored?(master)
      refute stored?(fa)
      refute stored?(other)
      refute stored?(other_fa)
      refute has_element?(view, "#flash-error")
    end

    test "an archived master goes for good once its translation has", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      archive!(fa, admin)
      archive!(master, admin)
      view = open_archive(conn)

      view
      |> element(~s(#{row(fa)} button[phx-value-event="permanent_destroy"]))
      |> render_click()

      view
      |> element(~s(#{row(master)} button[phx-value-event="permanent_destroy"]))
      |> render_click()

      refute stored?(fa)
      refute stored?(master)
      refute has_element?(view, "#flash-error")
    end
  end

  # A TRANSLATION BACK UNDER AN ARCHIVED MASTER is a page with neither a row nor a chip: the list
  # shows masters and hangs the rest off them. The archive shows the whole group side by side, so a
  # selection holding all of it has to come back together — which is why the group is checked once
  # the restore is written and not before it.
  describe "restoring a translation" do
    test "the row's Restore keeps it while its master is archived, and says why", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      archive!(fa, admin)
      archive!(master, admin)
      view = open_archive(conn)

      view |> element(~s(#{row(fa)} button[phx-value-event="unarchive"])) |> render_click()

      refute live?(fa), "the translation came back under its archived master"
      refute live?(master)
      assert has_element?(view, "#flash-error", @restore_refused)
    end

    test "and refuses for good once its master has been deleted", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      archive!(fa, admin)
      archive!(master, admin)

      archive = open_archive(conn)

      archive
      |> element(~s(#{row(master)} button[phx-value-event="permanent_destroy"]))
      |> render_click()

      render_async(archive, @await)
      view = open_archive(conn)
      view |> element(~s(#{row(fa)} button[phx-value-event="unarchive"])) |> render_click()

      refute live?(fa)

      assert has_element?(
               view,
               "#flash-error",
               "This is the Persian translation. Its original version has been deleted for " <>
                 "good, so it can't be restored. It can only be deleted for good."
             )
    end

    test "it goes back once its master has, onto its master's row", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      archive!(fa, admin)
      archive!(master, admin)
      view = open_archive(conn)

      view |> element(~s(#{row(master)} button[phx-value-event="unarchive"])) |> render_click()
      render_async(view, @await)
      view |> element(~s(#{row(fa)} button[phx-value-event="unarchive"])) |> render_click()

      assert live?(master)
      assert live?(fa)
      refute has_element?(view, "#flash-error")

      pages = open_pages(conn)
      assert has_element?(pages, row(master))
      assert has_element?(pages, chip(fa))
    end

    test "the bulk Restore brings a whole archived group back", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      {master, fa} = translated!(site, admin)
      archive!(fa, admin)
      archive!(master, admin)

      view = conn |> open_archive() |> select(fa) |> select(master) |> bulk("unarchive")

      assert live?(master)
      assert live?(fa), "the group came back before its master did"
      refute has_element?(view, "#flash-error")
    end
  end

  describe "Add translation" do
    test "offers the site's other languages, the path already filled in", %{
      conn: conn,
      master: master
    } do
      view = open_pages(conn)

      view
      |> element(~s(#pages-table_pages-#{master.id} button[phx-value-event="add_translation"]))
      |> render_click()

      assert has_element?(view, "#page-translation-form")
      assert has_element?(view, ~s(#page-translation-languages option[value="fa"]))
      assert has_element?(view, ~s(#page-translation-languages option[value="ar"]))
      refute has_element?(view, ~s(#page-translation-language option[value="en"]))
      assert has_element?(view, ~s(#page-translation-path[value="/fa#{master.path}"]))
    end

    test "moves the suggested path with the language, and keeps a typed one", %{
      conn: conn,
      master: master
    } do
      view = open_pages(conn)
      send(view.pid, {:row_action, "add_translation", %{"id" => master.id}})

      view
      |> form("#page-translation-form",
        translation: %{"language" => "ar", "path" => "/fa#{master.path}"}
      )
      |> render_change()

      assert has_element?(view, ~s(#page-translation-path[value="/ar#{master.path}"]))

      view
      |> form("#page-translation-form", translation: %{"language" => "fa", "path" => "/darbare"})
      |> render_change()

      assert has_element?(view, ~s(#page-translation-path[value="/darbare"]))
    end

    test "creates an inactive edition in the page's group and opens it", %{
      conn: conn,
      site: site,
      master: master
    } do
      view = open_pages(conn)
      send(view.pid, {:row_action, "add_translation", %{"id" => master.id}})

      view
      |> form("#page-translation-form",
        translation: %{"language" => "fa", "path" => "/fa#{master.path}"}
      )
      |> render_submit()

      created =
        Page
        |> Ash.Query.filter(path == ^"/fa#{master.path}")
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      assert %{language: "fa", active: false} = created
      assert created.language_group_id == master.id
      assert created.permissions == master.permissions
      refute has_element?(view, "#page-translation-form")

      assert has_element?(
               view,
               "#" <> MishkaGervaz.Resource.Info.Form.component_id(Page) <> "-form-wrapper"
             ),
             "the new edition did not open on the Configuration tab"
    end

    test "of a page restored from before language groups joins that page's row", %{
      conn: conn,
      site: site,
      master: master
    } do
      master
      |> shelve!(site)
      |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
      |> Ash.update!()

      view = open_pages(conn)
      send(view.pid, {:row_action, "add_translation", %{"id" => master.id}})

      view
      |> form("#page-translation-form",
        translation: %{"language" => "fa", "path" => "/fa#{master.path}"}
      )
      |> render_submit()

      settle(view)

      created =
        Page
        |> Ash.Query.filter(path == ^"/fa#{master.path}")
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      refute has_element?(view, row(created)), "the translation took a row of its own"
      assert has_element?(view, chip(created)), "the restored page's row has no chip for it"
    end

    test "keeps the chooser open with the reason a create was refused", %{
      conn: conn,
      site: site,
      master: master
    } do
      taken = create_page!(site_id: site.id, path: "/taken-#{System.unique_integer([:positive])}")
      view = open_pages(conn)
      send(view.pid, {:row_action, "add_translation", %{"id" => master.id}})

      view
      |> form("#page-translation-form", translation: %{"language" => "fa", "path" => taken.path})
      |> render_submit()

      assert view |> element("#page-translation-error") |> render() =~
               "Page path must be unique within a site"

      assert has_element?(view, "#page-translation-form")
    end

    test "says the site's languages are used up, and still takes a code of your own", %{
      conn: conn,
      site: site,
      master: master
    } do
      translate!(site, master, "fa")
      translate!(site, master, "ar")

      view = open_pages(conn)
      send(view.pid, {:row_action, "add_translation", %{"id" => master.id}})

      assert has_element?(view, "#page-translation-none")
      assert has_element?(view, "#page-translation-form")

      # The site lists en, fa and ar and the group holds all three, so nothing is suggested — but the
      # box is a box, not a list, and `de` is a language code like any other. A literal path answers
      # whatever it is written in; `site.languages` only governs a `:lang` capture.
      view
      |> form("#page-translation-form", translation: %{"language" => "de", "path" => "/de/about"})
      |> render_submit()

      assert %{language: "de", path: "/de/about"} =
               Page
               |> Ash.Query.filter(language_group_id == ^master.id and language == "de")
               |> Ash.read_one!(tenant: site.id, authorize?: false)
               |> Map.take([:language, :path])
    end
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp create_admin(email, site_id \\ nil) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!("*").id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
