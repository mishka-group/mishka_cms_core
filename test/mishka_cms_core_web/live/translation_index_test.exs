defmodule MishkaCmsCoreWeb.Test.TranslationIndexTest do
  @moduledoc """
  The admin's Translations page, driven through the real page: the Gervaz table of the words runtime
  templates ask `t/1` for, and the two buttons above it no row can offer.

  Whose rows the table draws is decided by the actor, never by the page — a master reads every
  site's, a site admin their own and the global ones. **Scan templates** and **Remove unused** are
  held to the same line: each reaches as far as the admin pressing it may, and no further.

  The resource's own actions and policies are covered beside `MishkaCmsCore.Runtime.Translation`;
  this is what an admin standing on the page gets from them.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{Translation, Translations}
  alias MishkaCmsCore.Runtime.States.{SiteState, TranslationsState}
  alias MishkaCmsCoreWeb.Live.Admin.Components.TranslationGroup
  alias MishkaCmsCore.Settings

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/runtime/translations"
  @await 5_000
  @unused_badge ~s(span[title="No template asks for this key any more"])

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    other = create_site!()

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

    MishkaCmsCore.DataCase.forget_settings(~w(site.languages), [site.id, other.id])
    {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
    {:ok, _} = Settings.put("site.languages", ["en"], site_id: other.id)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site, other: other}
  end

  defp permission!(name) do
    Permission
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_permission!(name: name)
      permission -> permission
    end
  end

  # Registered without a tenant and moved onto the site afterwards, as the other admin pages' tests
  # make their site admins: a session token that names a tenant is not one this harness signs in.
  defp admin!(permissions, site_id \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "translations-#{n}@example.com",
          password: @password,
          password_confirmation: @password
        },
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    for name <- permissions do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(name).id)
      |> Ash.create!(authorize?: false)
    end

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp as_master(conn), do: log_in(conn, admin!(["*"]))

  defp as_site_admin(conn, site),
    do: log_in(conn, admin!(["admin:dashboard:*"], site.id))

  defp open(conn) do
    {:ok, view, _html} = live(conn, @path)
    render_async(view, @await)
    view
  end

  # BOTH BUTTONS HAND THE TABLE A REFRESH WITH `send_update/3`, which the page runs after the click's
  # own render — so it is the next render, and the load it starts, that shows the result.
  # A CLICK, THEN EVERYTHING IT SET OFF: the notifications its writes broadcast come back to this
  # view as messages, and each hands the table a row to redraw — `:sys.get_state/1` returns once the
  # view has worked through them, and `render_async/2` once the table has read what they named.
  defp click(view, id) do
    view |> element(id) |> render_click()
    _handled = :sys.get_state(view.pid)
    render_async(view, @await)
    view
  end

  defp unused_row(translation), do: "#translations-unused_translations-#{translation.id}"

  defp row(translation), do: "#translations-table_translations-#{translation.id}"

  defp chips(translation), do: "#translations-table-languages-#{translation.id}"

  defp chip(translation, code, state),
    do: ~s(#{chips(translation)} span[title="#{code} — #{state}"])

  defp group(view), do: :sys.get_state(view.pid).socket.assigns.translation_group

  # A message the page is sent is handled after the event that sent it; this waits for it, and for
  # the form's record read and the table's reload it started.
  defp settle(view) do
    _handled = :sys.get_state(view.pid)
    render_async(view, @await)
    view
  end

  defp key(label), do: "#{label} #{System.unique_integer([:positive])}"

  # Read past every policy, so what the page did is checked against what is stored rather than
  # against what the same actor is allowed to see.
  defp stored(key, site_id) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key == ^key)
    |> then(
      &if(is_nil(site_id),
        do: Ash.Query.filter(&1, is_nil(site_id)),
        else: Ash.Query.filter(&1, site_id == ^site_id)
      )
    )
    |> Ash.Query.sort(language: :asc)
    |> Ash.read!(authorize?: false, page: false)
  end

  defp languages(key, site_id), do: key |> stored(site_id) |> Enum.map(& &1.language)

  # A row nobody asks for: registered straight, with no template behind it.
  defp orphan!(label, site_id) do
    key = key(label)
    :ok = Translations.register(site_id, [key])
    {key, hd(stored(key, site_id))}
  end

  # A row a saved template asks for, registered the way every one is — by the save itself.
  defp asked_for!(label, site_id) do
    key = key(label)
    create_component!(site_id: site_id, template: ~s|<p>{t("#{key}")}</p>|)
    {key, hd(stored(key, site_id))}
  end

  describe "the page" do
    test "draws the Gervaz table under Scan templates, Remove unused and Add translation", %{
      conn: conn
    } do
      view = conn |> as_master() |> open()

      assert has_element?(view, "#translations-table")
      assert has_element?(view, "#translations-sync")
      assert has_element?(view, "#translations-purge-unused")
      assert has_element?(view, "#translations-add")
    end
  end

  describe "whose rows an admin is shown" do
    test "a master is shown every site's rows and the global ones", %{
      conn: conn,
      site: site,
      other: other
    } do
      {_key, own} = orphan!("Own", site.id)
      {_key, elsewhere} = orphan!("Elsewhere", other.id)
      {_key, global} = orphan!("Global", nil)

      view = conn |> as_master() |> open()

      assert has_element?(view, row(own))
      assert has_element?(view, row(elsewhere))
      assert has_element?(view, row(global))
    end

    # The tenant is the actor's own site, and the resource's read policy is a filter on the query —
    # so another site's row is not refused, it is simply never in what the table reads.
    test "a site admin is shown their own site's rows and the global ones, never another site's",
         %{conn: conn, site: site, other: other} do
      {_key, own} = orphan!("Own", site.id)
      {_key, elsewhere} = orphan!("Elsewhere", other.id)
      {_key, global} = orphan!("Global", nil)

      view = conn |> as_site_admin(site) |> open()

      assert has_element?(view, row(own))
      assert has_element?(view, row(global))
      refute has_element?(view, row(elsewhere)), "a site admin was shown another site's words"
    end
  end

  # A MASTER'S FILTERS, as on the other runtime lists: Site picks sites, Global Only the words every
  # site shares. A site admin reads their own site's words and the global ones only, so is offered
  # neither.
  describe "the Site filter" do
    @site_filter "#multi-select-translations-table-site_id"
    @global_only ~s(#translations-table input[name="global_only"])

    test "a master is offered Site and Global Only", %{conn: conn} do
      view = conn |> as_master() |> open()

      assert has_element?(view, @site_filter)
      assert has_element?(view, @global_only)
    end

    test "a site admin is offered neither", %{conn: conn, site: site} do
      view = conn |> as_site_admin(site) |> open()

      refute has_element?(view, @site_filter)
      refute has_element?(view, @global_only)
    end

    test "keeps the picked site's words only", %{conn: conn, site: site, other: other} do
      {_key, own} = orphan!("Own", site.id)
      {_key, elsewhere} = orphan!("Elsewhere", other.id)
      {_key, global} = orphan!("Global", nil)

      view = conn |> as_master() |> open_at("?translations_filter_site_id=#{other.id}")

      assert has_element?(view, row(elsewhere))
      refute has_element?(view, row(own))
      refute has_element?(view, row(global))
      assert shown_total(view) == 1
    end

    test "keeps the words of every site picked", %{conn: conn, site: site, other: other} do
      {_key, own} = orphan!("Own", site.id)
      {_key, elsewhere} = orphan!("Elsewhere", other.id)
      {_key, global} = orphan!("Global", nil)

      view =
        conn |> as_master() |> open_at("?translations_filter_site_id=#{site.id},#{other.id}")

      assert has_element?(view, row(own))
      assert has_element?(view, row(elsewhere))
      refute has_element?(view, row(global))
    end

    test "Global Only keeps the words every site shares", %{
      conn: conn,
      site: site,
      other: other
    } do
      {_key, own} = orphan!("Own", site.id)
      {_key, elsewhere} = orphan!("Elsewhere", other.id)
      {_key, global} = orphan!("Global", nil)

      view = conn |> as_master() |> open_at("?translations_filter_global_only=true")

      assert has_element?(view, row(global))
      refute has_element?(view, row(own))
      refute has_element?(view, row(elsewhere))
    end

    test "a word still shows once, its languages as chips", %{conn: conn, other: other} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: other.id)
      {key, en} = orphan!("Once", other.id)
      [_en, fa] = stored(key, other.id)

      view = conn |> as_master() |> open_at("?translations_filter_site_id=#{other.id}")

      assert has_element?(view, row(en))
      refute has_element?(view, row(fa)), "a word is listed once per language"
      assert has_element?(view, chip(en, "EN", "missing"))
      assert has_element?(view, chip(en, "FA", "missing"))
    end

    test "a word written on another site stays out, one on the picked site comes first", %{
      conn: conn,
      site: site,
      other: other
    } do
      orphan!("Already here", other.id)
      view = conn |> as_master() |> open_at("?translations_filter_site_id=#{other.id}")
      assert shown_total(view) == 1

      :ok = Translations.register(site.id, [key("Not this site")])
      settle(view)

      assert shown_total(view) == 1

      arrived = key("Arrived")
      :ok = Translations.register(other.id, [arrived])
      settle(view)

      [en] = stored(arrived, other.id)
      assert shown_total(view) == 2
      assert first_row_id(view) == "translations-table_translations-#{en.id}"
    end

    # The filters are a master's, but a link a master shared can still carry them.
    test "a site admin given them in the address is shown their usual list", %{
      conn: conn,
      site: site,
      other: other
    } do
      {_key, own} = orphan!("Own", site.id)
      {_key, elsewhere} = orphan!("Elsewhere", other.id)
      {_key, global} = orphan!("Global", nil)

      for query <- [
            "?translations_filter_site_id=#{other.id}",
            "?translations_filter_global_only=true"
          ] do
        view = conn |> as_site_admin(site) |> open_at(query)

        assert has_element?(view, row(own)), "#{query} hid a site admin's own words"
        assert has_element?(view, row(global)), "#{query} hid the global words"
        refute has_element?(view, row(elsewhere)), "a site admin was shown another site's words"
      end
    end
  end

  # A TEMPLATE SAVED BEFORE ITS SITE GAINED A LANGUAGE registered the languages it had then, and
  # nothing saves it again when the list grows — the case the button exists for.
  describe "Scan templates" do
    test "registers a key a saved template asks for in a language it was missing", %{
      conn: conn,
      site: site
    } do
      {key, _en} = asked_for!("Welcome", site.id)
      assert languages(key, site.id) == ["en"], "the save registered the one language it had"

      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      view = conn |> as_master() |> open()

      click(view, "#translations-sync")

      assert languages(key, site.id) == ["en", "fa"]
      assert [%{value: nil}] = Enum.filter(stored(key, site.id), &(&1.language == "fa"))
      assert has_element?(view, chips(hd(stored(key, site.id))), "FA")
    end

    test "leaves a translation somebody already wrote exactly as it was", %{
      conn: conn,
      site: site
    } do
      {key, en} = asked_for!("Categories", site.id)

      # The write is broadcast, and the cache keeps it past this test's rollback unless told not to.
      on_exit(fn -> TranslationsState.put(site.id, "en", key, nil) end)

      en
      |> Ash.Changeset.for_update(:master_update, %{value: "Every category"}, authorize?: false)
      |> Ash.update!()

      view = conn |> as_master() |> open()
      click(view, "#translations-sync")

      assert [%{value: "Every category"}] = stored(key, site.id)
    end

    test "a site admin's scan registers their own site's templates and no other site's", %{
      conn: conn,
      site: site,
      other: other
    } do
      {own, _} = asked_for!("Own", site.id)
      {elsewhere, _} = asked_for!("Elsewhere", other.id)

      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: other.id)

      view = conn |> as_site_admin(site) |> open()
      click(view, "#translations-sync")

      assert languages(own, site.id) == ["en", "fa"]

      assert languages(elsewhere, other.id) == ["en"],
             "a site admin's scan wrote rows onto another site"
    end
  end

  # A MASTER IS A USER WHOSE `site_id` IS NIL, never the absence of a user. The router keeps this
  # page behind a sign-in; the page itself still answers a missing user with nothing, not with every
  # site.
  describe "the buttons with no user behind them" do
    defp userless_socket,
      do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: nil, flash: %{}}}

    test "Scan templates registers no site's templates", %{site: site} do
      {key, _en} = asked_for!("Nobody scans", site.id)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      assert {:noreply, _socket} =
               MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Translation.Index.handle_event(
                 "translations_sync",
                 %{},
                 userless_socket()
               )

      assert languages(key, site.id) == ["en"]
    end

    test "Remove unused lists nothing", %{site: site} do
      orphan!("Nobody lists", site.id)

      assert {:noreply, socket} =
               MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Translation.Index.handle_event(
                 "translations_unused",
                 %{},
                 userless_socket()
               )

      assert socket.assigns.unused_ids == []
    end
  end

  # The admin session here still asks for `admin:dashboard:*`, which holds the translation area, so
  # the page's own mount and buttons are asked for an admin of another area.
  describe "an admin of another area" do
    alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Translation.Index

    defp mounted_for(permissions, site) do
      user = create_user_with_permissions!(permissions, site_id: site.id)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_user: user}
      }

      {:ok, socket} = Index.mount(%{}, %{}, socket)
      socket
    end

    test "is not offered Scan templates, Remove unused or Add; the translation area is", %{
      site: site
    } do
      refute mounted_for(["admin:dashboard:runtime:page"], site).assigns.writable?
      assert mounted_for(["admin:dashboard:runtime:translation"], site).assigns.writable?
    end

    test "scans no template by pressing Scan templates anyway", %{site: site} do
      {key, _en} = asked_for!("Not theirs to scan", site.id)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      assert {:noreply, socket} =
               Index.handle_event(
                 "translations_sync",
                 %{},
                 mounted_for(["admin:dashboard:runtime:page"], site)
               )

      assert socket.assigns.flash["error"] == "You cannot scan the templates."
      assert languages(key, site.id) == ["en"]
    end
  end

  describe "Remove unused" do
    # What the button is about to delete has to be visible before it is pressed.
    test "the Used column marks a row no template asks for, and only that one", %{
      conn: conn,
      site: site
    } do
      {_used, kept} = asked_for!("Kept", site.id)
      {_unused, orphan} = orphan!("Orphan", site.id)

      view = conn |> as_master() |> open()

      assert has_element?(view, "#{row(orphan)} #{@unused_badge}")
      refute has_element?(view, "#{row(kept)} #{@unused_badge}")
    end

    # IT SHOWS BEFORE IT DELETES: the button lists the unused words in the same table, scoped to
    # them, and nothing is deleted until Delete all is pressed in that list.
    test "lists the words no template asks for, and deletes nothing yet", %{
      conn: conn,
      site: site
    } do
      {used, kept} = asked_for!("Kept", site.id)
      {unused, gone} = orphan!("Orphan", site.id)

      view = conn |> as_master() |> open()
      click(view, "#translations-purge-unused")

      assert has_element?(view, unused_row(gone))
      refute has_element?(view, unused_row(kept))
      assert has_element?(view, "#translations-purge-confirm")
      assert [_] = stored(unused, site.id)
      assert [_] = stored(used, site.id)
    end

    # THE LIST IS ITS OWN READ: scoped to the unused words by id, a word still in use that is saved
    # while it is open is not drawn into it.
    test "a word still in use, saved while the list is open, does not join it", %{
      conn: conn,
      site: site
    } do
      {_used, kept} = asked_for!("Kept", site.id)
      {_unused, gone} = orphan!("Orphan", site.id)

      view = conn |> as_master() |> open()
      click(view, "#translations-purge-unused")
      assert has_element?(view, unused_row(gone))

      kept
      |> Ash.Changeset.for_update(:master_update, %{value: "Still asked for"}, authorize?: false)
      |> Ash.update!()

      settle(view)

      refute has_element?(view, unused_row(kept)), "a word in use appeared among the unused"
      assert has_element?(view, unused_row(gone))
    end

    test "Delete all removes them, and the list hears it without a reload", %{
      conn: conn,
      site: site
    } do
      {used, kept} = asked_for!("Kept", site.id)
      {unused, gone} = orphan!("Orphan", site.id)

      view = conn |> as_master() |> open()
      click(view, "#translations-purge-unused")
      click(view, "#translations-purge-confirm")

      assert stored(unused, site.id) == []
      assert [_] = stored(used, site.id)
      refute has_element?(view, row(gone)), "the deleted row is still in the table"
      assert has_element?(view, row(kept))
      assert has_element?(view, "#flash-info", "unused translation(s) removed")
    end

    test "says so when every word is still asked for", %{conn: conn, site: site} do
      asked_for!("Kept", site.id)

      view = conn |> as_site_admin(site) |> open()
      click(view, "#translations-purge-unused")

      assert has_element?(view, "#translations-unused-summary", "Every word is still asked for")
      refute has_element?(view, "#translations-purge-confirm")
    end

    # A global row serves every site, so it is asked for by any template anywhere — and one site's
    # admin pressing this cannot know that, which is why the list never holds a global row for them.
    test "a site admin's list and Delete all reach their own site's rows and nobody else's", %{
      conn: conn,
      site: site,
      other: other
    } do
      {own, own_row} = orphan!("Own", site.id)
      {elsewhere, elsewhere_row} = orphan!("Elsewhere", other.id)
      {global, global_row} = orphan!("Global", nil)

      view = conn |> as_site_admin(site) |> open()
      click(view, "#translations-purge-unused")

      assert has_element?(view, unused_row(own_row))
      refute has_element?(view, unused_row(elsewhere_row))
      refute has_element?(view, unused_row(global_row))

      click(view, "#translations-purge-confirm")

      assert stored(own, site.id) == []
      assert [_ | _] = stored(elsewhere, other.id), "another site's row was deleted"
      assert [_ | _] = stored(global, nil), "a global row was deleted by a site admin"
    end
  end

  # THE FLASH OUTLIVES WHAT IT ANNOUNCES. The table used to be reloaded after Scan, and the reload's
  # address patch replaced the page's flash with an empty one about a second later. Nothing reloads
  # now: the rows Scan writes reach the table as notifications.
  describe "Scan templates, over PubSub" do
    test "the notice is still there once the new rows have arrived", %{conn: conn, site: site} do
      {key, en} = asked_for!("Welcome", site.id)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      view = conn |> as_master() |> open()
      click(view, "#translations-sync")

      assert has_element?(view, chips(en), "FA"), "the new FA row did not reach the table"
      assert has_element?(view, "#flash-info", "Templates scanned")
      assert languages(key, site.id) == ["en", "fa"]
    end

    test "a translation written elsewhere reaches the open list", %{conn: conn, site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {key, en} = orphan!("Elsewhere", site.id)
      [_en, fa] = stored(key, site.id)
      on_exit(fn -> TranslationsState.put(site.id, "fa", key, nil) end)

      view = conn |> as_master() |> open()
      assert has_element?(view, chip(en, "FA", "missing"))

      fa
      |> Ash.Changeset.for_update(:master_update, %{value: "جای دیگر"}, authorize?: false)
      |> Ash.update!()

      _handled = :sys.get_state(view.pid)
      render_async(view, @await)

      assert has_element?(view, chip(en, "FA", "translated"))
    end
  end

  # "SHOWING N" COUNTS WORDS AND FOLLOWS THEM — read again after every change the list hears, so a
  # word arriving in two languages counts once, and a word new to the list comes first, as a new row
  # does in every other realtime list.
  describe "the total and the order, over PubSub" do
    setup %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok
    end

    defp open_at(conn, query) do
      {:ok, view, _html} = live(conn, @path <> query)
      render_async(view, @await)
      view
    end

    defp shown_total(view) do
      [_all, count] =
        Regex.run(~r/Showing (\d+)/, render(element(view, "#translations-table-total")))

      String.to_integer(count)
    end

    defp first_row_id(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([id^="translations-table_translations-"]))
      |> LazyHTML.attribute("id")
      |> Enum.find(&Regex.match?(~r/^translations-table_translations-[0-9a-f-]{36}$/, &1))
    end

    test "a word written elsewhere counts once, whatever languages it arrives in, and comes first",
         %{conn: conn, site: site} do
      orphan!("Already here", site.id)
      view = conn |> as_master() |> open()
      before = shown_total(view)

      key = key("Arrived")
      :ok = Translations.register(site.id, [key])
      settle(view)

      [en, _fa] = stored(key, site.id)
      assert shown_total(view) == before + 1
      assert first_row_id(view) == "translations-table_translations-#{en.id}"
    end

    test "a word deleted in this tab leaves the total once", %{conn: conn, site: site} do
      orphan!("Stays", site.id)
      {_key, en} = orphan!("Goes here", site.id)
      view = conn |> as_master() |> open()
      before = shown_total(view)

      send(view.pid, {:row_action, "delete_translation_key", %{"id" => en.id}})
      settle(view)

      assert shown_total(view) == before - 1
      refute has_element?(view, row(en))
    end

    test "a word deleted elsewhere leaves the total", %{conn: conn, site: site} do
      orphan!("Stays", site.id)
      {_key, en} = orphan!("Goes elsewhere", site.id)
      view = conn |> as_master() |> open()
      before = shown_total(view)

      {:ok, 2} = Translations.delete_key(admin!(["*"]), en.id)
      settle(view)

      assert shown_total(view) == before - 1
    end

    test "a word the search does not match changes nothing", %{conn: conn, site: site} do
      {needle, _en} = orphan!("Needle", site.id)
      view = conn |> as_master() |> open_at("?translations_search=#{URI.encode(needle)}")
      assert shown_total(view) == 1

      :ok = Translations.register(site.id, [key("Haystack")])
      settle(view)

      assert shown_total(view) == 1
    end

    test "the first word matching a search takes the list out of its empty state",
         %{conn: conn, site: site} do
      term = "Nothing yet #{System.unique_integer([:positive])}"
      view = conn |> as_master() |> open_at("?translations_search=#{URI.encode(term)}")
      refute has_element?(view, "#translations-table-total", "Showing 1")

      :ok = Translations.register(site.id, [term])
      settle(view)

      [en, _fa] = stored(term, site.id)
      assert shown_total(view) == 1
      assert has_element?(view, row(en))
    end
  end

  # THE ADD FORM ASKS FOR THE SITE FIRST — Global included — and a site admin, whose words can only
  # be their own site's, is never asked at all.
  describe "the Add translation form" do
    test "a master is asked for the site first, with Global offered", %{conn: conn} do
      view = conn |> as_master() |> open()
      view |> element("#translations-add") |> render_click()
      html = render(view)

      [site_at, key_at] =
        for name <- ~w(_search_site_id form[key]), do: :binary.match(html, name) |> elem(0)

      assert site_at < key_at, "the site field is not above the key"
      assert has_element?(view, "#translation_form-form")
    end

    test "a site admin is not asked for a site", %{conn: conn, site: site} do
      view = conn |> as_site_admin(site) |> open()
      view |> element("#translations-add") |> render_click()

      refute render(view) =~ "_search_site_id"
      assert has_element?(view, ~s(#translation_form-form [name="form[key]"]))
    end
  end

  # ONE MORE LANGUAGE FROM THE MODAL. Held to who may write the word and to the master's bounds.
  describe "Add language in the Translate modal" do
    setup %{conn: conn, site: site} do
      MishkaCmsCore.DataCase.forget_settings(~w(site.allowed_languages site.languages), [
        nil,
        site.id
      ])

      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {key, en} = orphan!("More", site.id)
      %{key: key, en: en, conn: conn}
    end

    defp open_word(view, row) do
      send(view.pid, {:row_action, "edit_translation", %{"id" => row.id}})
      _handled = :sys.get_state(view.pid)
      render_async(view, @await)
      view
    end

    defp add(view, language) do
      view
      |> element("#translation-group-add-language")
      |> render_submit(%{"language" => language})

      _handled = :sys.get_state(view.pid)
      render_async(view, @await)
      view
    end

    test "publishes it on the word's site and picks it", %{
      conn: conn,
      site: site,
      key: key,
      en: en
    } do
      view = conn |> as_master() |> open() |> open_word(en) |> add("FR")

      assert Settings.get("site.languages", nil, site.id) == ["en", "fa", "fr"]
      assert "fr" in languages(key, site.id)
      assert has_element?(view, "#translation-group-language-fr")
      assert has_element?(view, "#translation-group-form", "FR")
      assert has_element?(view, chip(en, "FR", "missing")), "the list did not hear of the new row"
    end

    # THE ROW STANDING FOR A WORD CAN CHANGE HANDS. It is the first by code, and `de` sorts before
    # `en`: the new DE row takes over, and the EN row that stood for the word has to leave the list
    # rather than stay beside it.
    test "a language that sorts first still leaves the word on one row", %{
      conn: conn,
      site: site,
      key: key,
      en: en
    } do
      view = conn |> as_master() |> open() |> open_word(en) |> add("de")
      [de] = key |> stored(site.id) |> Enum.filter(&(&1.language == "de"))

      refute has_element?(view, row(en)), "the old row is still standing beside the new one"
      assert has_element?(view, row(de))

      assert has_element?(
               view,
               ~s(#translations-table-languages-#{de.id} span[title="DE — missing"])
             )
    end

    test "a site admin adds one to their own site's word", %{
      conn: conn,
      site: site,
      key: key,
      en: en
    } do
      conn |> as_site_admin(site) |> open() |> open_word(en) |> add("de")

      assert "de" in Settings.get("site.languages", nil, site.id)
      assert "de" in languages(key, site.id)
    end

    test "a site admin is not offered it on a global word", %{conn: conn, site: site} do
      {_key, global} = orphan!("Shared", nil)

      view = conn |> as_site_admin(site) |> open() |> open_word(global)

      assert has_element?(view, "#translation-group")
      refute has_element?(view, "#translation-group-add-language")
    end

    test "a language the master does not allow is refused", %{conn: conn, site: site, en: en} do
      {:ok, _} = Settings.put("site.allowed_languages", ["en", "fa", "de"])

      view = conn |> as_master() |> open() |> open_word(en) |> add("fr")

      assert has_element?(view, "#flash-error", "FR is not one of the languages")
      assert Settings.get("site.languages", nil, site.id) == ["en", "fa"]
    end

    test "what is not a language code is refused", %{conn: conn, site: site, en: en} do
      view = conn |> as_master() |> open() |> open_word(en) |> add("French")

      assert has_element?(view, "#flash-error", "not a language code")
      assert Settings.get("site.languages", nil, site.id) == ["en", "fa"]
    end

    test "a word deleted while it is open is not brought back", %{
      conn: conn,
      site: site,
      key: key,
      en: en
    } do
      view = conn |> as_master() |> open() |> open_word(en)
      send(view.pid, {:row_action, "delete_translation_key", %{"id" => en.id}})

      add(view, "fr")

      assert has_element?(view, "#flash-error", "no longer there")
      assert stored(key, site.id) == []
      assert Settings.get("site.languages", nil, site.id) == ["en", "fa"]
    end
  end

  # A GLOBAL WORD IS A MASTER'S TO CHANGE. A site admin opening one reads its value; there is no form
  # to type into that the save would refuse.
  describe "Translate on a global word" do
    setup do
      {key, row} = orphan!("Shared", nil)

      row
      |> Ash.Changeset.for_update(:master_update, %{value: "Shared value"}, authorize?: false)
      |> Ash.update!(authorize?: false)

      on_exit(fn -> TranslationsState.put(nil, row.language, key, nil) end)
      %{key: key, row: row}
    end

    defp translate(view, row) do
      send(view.pid, {:row_action, "edit_translation", %{"id" => row.id}})
      settle(view)
    end

    test "a site admin reads the value and is told only a master can change it", %{
      conn: conn,
      site: site,
      row: row
    } do
      view = conn |> as_site_admin(site) |> open() |> translate(row)

      assert has_element?(view, "#translation-group-read-only", "Shared value")

      assert has_element?(
               view,
               "#translation-group-read-only",
               "A global word — only a master can change it."
             )

      refute has_element?(view, "#translation_form-form")
    end

    test "a site admin opening one with no value reads that it is missing", %{
      conn: conn,
      site: site
    } do
      {key, row} = orphan!("Unfilled", nil)
      on_exit(fn -> TranslationsState.put(nil, row.language, key, nil) end)

      view = conn |> as_site_admin(site) |> open() |> translate(row)

      assert has_element?(view, "#translation-group-read-only", "Missing")

      assert has_element?(
               view,
               "#translation-group-read-only",
               "A global word — only a master can change it."
             )
    end

    test "a master is given the form to change it", %{conn: conn, row: row} do
      view = conn |> as_master() |> open() |> translate(row)

      assert has_element?(view, "#translation_form-form textarea[name='form[value]']")
      refute has_element?(view, "#translation-group-read-only")
    end
  end

  # A WORD OF ANOTHER SITE READ BY SOMEONE WHO MAY NOT WRITE IT. No page hands one to a reader outside
  # its site, since `Translations.group/2` reads as the actor, so the component is drawn directly.
  describe "the read-only view of a site's word" do
    test "a word of another site names who can change it" do
      reader = %{site_id: Ash.UUID.generate()}

      group = %{
        key: key("Theirs"),
        site_id: Ash.UUID.generate(),
        picked: "row-en",
        rows: [%{id: "row-en", language: "en", value: "Their value"}]
      }

      read_only =
        render_component(&TranslationGroup.translation_group/1,
          id: "translation-group",
          group: group,
          current_user: reader
        )
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#translation-group-read-only")
        |> LazyHTML.text()

      assert read_only =~ "Their value"
      assert read_only =~ "Only a master or an admin of this word's site can change it."
    end

    test "reads in the reader's language" do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      reader = %{site_id: Ash.UUID.generate()}

      group = %{
        key: key("Global"),
        site_id: nil,
        picked: "row-fa",
        rows: [%{id: "row-fa", language: "fa", value: nil}]
      }

      read_only =
        render_component(&TranslationGroup.translation_group/1,
          id: "translation-group",
          group: group,
          current_user: reader
        )
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#translation-group-read-only")
        |> LazyHTML.text()

      assert read_only =~ "[fa] Missing"
      assert read_only =~ "[fa] A global word — only a master can change it."
      refute read_only =~ ~r/(?<!\[fa\] )Missing/
    end
  end

  # A WORD IS LISTED ONCE, its languages as chips — the page list's shape. Its first language by code
  # is the row that stands for it.
  describe "one row per word" do
    test "the word's first language stands for it, the others are its chips", %{
      conn: conn,
      site: site
    } do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {key, en} = orphan!("Once", site.id)
      [_en, fa] = stored(key, site.id)

      view = conn |> as_master() |> open()

      assert has_element?(view, row(en))
      refute has_element?(view, row(fa)), "a word is listed once per language"
      assert has_element?(view, chip(en, "EN", "missing"))
      assert has_element?(view, chip(en, "FA", "missing"))
    end

    test "past two languages the rest fold behind +N", %{conn: conn, site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "fr", "de"], site_id: site.id)
      {_key, first} = orphan!("Many", site.id)

      view = conn |> as_master() |> open()

      assert has_element?(view, "#{chips(first)} button", "+2")
    end

    # The Site column the other runtime lists draw — one component, not a copy of it.
    test "the Site column reads like the other runtime lists", %{conn: conn, site: site} do
      {_key, own} = orphan!("Own", site.id)
      {_key, global} = orphan!("Global", nil)

      view = conn |> as_master() |> open()

      assert has_element?(view, "#{row(own)} svg + span", "localhost")
      assert has_element?(view, "#{row(global)} svg + span", "Global")
    end
  end

  describe "Translate" do
    setup %{conn: conn, site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {key, en} = orphan!("Hello", site.id)
      [_en, fa] = stored(key, site.id)
      on_exit(fn -> for l <- ~w(en fa), do: TranslationsState.put(site.id, l, key, nil) end)

      view = conn |> as_master() |> open()
      send(view.pid, {:row_action, "edit_translation", %{"id" => en.id}})

      %{view: settle(view), key: key, en: en, fa: fa}
    end

    test "opens the word in every language, the first missing one picked", %{
      view: view,
      key: key,
      en: en
    } do
      assert has_element?(view, "#translation-group-key", key)
      assert has_element?(view, "#translation-group-language-en")
      assert has_element?(view, "#translation-group-language-fa")
      assert group(view).picked == en.id
      assert has_element?(view, "#translation-group-form", "EN")
    end

    test "a save writes, moves on to the next missing one, and the list's chip turns", %{
      view: view,
      site: site,
      key: key,
      en: en,
      fa: fa
    } do
      view |> element("#translation-group-language-fa") |> render_click()
      settle(view)

      view
      |> element("#translation_form-form")
      |> render_submit(%{"form" => %{"value" => "سلام"}})

      settle(view)

      assert [%{value: nil}, %{value: "سلام"}] = stored(key, site.id)
      assert group(view).picked == en.id, "the next missing language is not up"
      assert has_element?(view, "#translation-group-language-fa", "سلام")
      assert fa.id != group(view).picked

      assert has_element?(view, chip(en, "FA", "translated")),
             "the list's row did not hear of the save"
    end

    test "text typed for one language stays with it when another is picked", %{
      view: view,
      site: site,
      key: key
    } do
      view |> element("#translation-group-language-fa") |> render_click()
      settle(view)

      view
      |> element("#translation_form-form")
      |> render_change(%{"_target" => ["form", "value"], "form" => %{"value" => "سلام"}})

      view |> element("#translation-group-language-en") |> render_click()
      settle(view)

      assert has_element?(view, "#translation-group-form", "EN")
      refute render(element(view, "#translation_form-form textarea")) =~ "سلام"

      view
      |> element("#translation_form-form")
      |> render_submit(%{"form" => %{"value" => "Hello there"}})

      settle(view)

      assert [%{language: "en", value: "Hello there"}, %{language: "fa", value: nil}] =
               stored(key, site.id)
    end

    # A SAVE THAT CHANGES NOTHING THE GROUP SHOWS still leaves the picked language open for editing,
    # never the empty "Add translation" form.
    test "a save that leaves the word as it was keeps the picked language open", %{
      conn: conn,
      site: site,
      key: key,
      en: en,
      fa: fa
    } do
      for {row, value} <- [{en, "Hello"}, {fa, "سلام"}] do
        row
        |> Ash.Changeset.for_update(:master_update, %{value: value}, authorize?: false)
        |> Ash.update!(authorize?: false)
      end

      view = conn |> as_master() |> open()
      send(view.pid, {:row_action, "edit_translation", %{"id" => en.id}})
      settle(view)

      assert has_element?(view, "#translation-group-form", "EN")

      view
      |> element("#translation_form-form")
      |> render_submit(%{"form" => %{"value" => "Hello"}})

      settle(view)

      assert [%{value: "Hello"}, %{value: "سلام"}] = stored(key, site.id)
      assert has_element?(view, "#translation-group-form", "EN")
      assert has_element?(view, "#translation_form-form textarea[name='form[value]']")
      refute has_element?(view, "#translation_form-form [name='form[key]']")
      refute has_element?(view, "#translation_form-form [name='form[language]']")

      view
      |> element("#translation_form-form")
      |> render_submit(%{"form" => %{"value" => "Hello again"}})

      settle(view)

      assert [%{value: "Hello again"}, %{value: "سلام"}] = stored(key, site.id)
    end

    test "Delete removes the word in every language", %{view: view, site: site, key: key, en: en} do
      send(view.pid, {:row_action, "delete_translation_key", %{"id" => en.id}})
      settle(view)

      assert stored(key, site.id) == []
      refute has_element?(view, row(en))
    end
  end

  # A NEW WORD IS WRITTEN IN ONE LANGUAGE; the rest are what comes next, so it opens in all of them.
  test "Add translation opens the word it wrote in every language", %{conn: conn} do
    key = key("Written")
    [first | _] = Translations.languages(nil)
    on_exit(fn -> TranslationsState.put(nil, first, key, nil) end)

    view = conn |> as_master() |> open()
    view |> element("#translations-add") |> render_click()
    settle(view)

    view
    |> element("#translation_form-form")
    |> render_submit(%{"form" => %{"key" => key, "language" => first, "value" => "Written"}})

    settle(view)

    assert has_element?(view, "#translation-group-key", key)
    assert Enum.map(stored(key, nil), & &1.language) == Enum.sort(Translations.languages(nil))
  end

  test "the header's actions are drawn apart: Scan tinted, Remove outlined, Add filled", %{
    conn: conn
  } do
    view = conn |> as_master() |> open()

    assert has_element?(view, "#translations-sync.bg-\\[\\#f4f2fd\\] .hero-arrow-path")
    assert has_element?(view, "#translations-purge-unused.bg-white .hero-trash")
    refute has_element?(view, "#translations-add.bg-white")
  end

  describe "who may open it" do
    # A CONTENT LIST: every dashboard admin reads it, whatever area they hold.
    test "an admin of another dashboard area opens the list, with no button that writes", %{
      conn: conn
    } do
      conn = log_in(conn, admin!(["admin:dashboard:runtime:page"]))

      assert {:ok, view, _html} = live(conn, @path)
      render_async(view, @await)

      refute has_element?(view, "#translations-sync")
      refute has_element?(view, "#translations-purge-unused")
      refute has_element?(view, "#translations-add")
    end

    test "a holder of admin:dashboard:runtime:translation gets the buttons that write", %{
      conn: conn
    } do
      conn = log_in(conn, admin!(["admin:dashboard:runtime:translation"]))

      assert {:ok, view, _html} = live(conn, @path)
      render_async(view, @await)

      assert has_element?(view, "#translations-sync")
      assert has_element?(view, "#translations-purge-unused")
      assert has_element?(view, "#translations-add")
    end

    test "an API admin is refused the page, and sent to the site root", %{conn: conn} do
      conn = log_in(conn, admin!(["admin:api:*"]))

      assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, @path)
      assert flash["error"] =~ "permission"
    end

    test "a signed-in user with no admin permission at all is refused the page", %{conn: conn} do
      conn = log_in(conn, admin!([]))

      assert {:error, {:redirect, %{to: to, flash: flash}}} = live(conn, @path)
      refute to == @path
      assert flash["error"] =~ "permission"
    end

    test "a visitor who is not signed in is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth"}}} = live(conn, @path)
    end
  end
end
