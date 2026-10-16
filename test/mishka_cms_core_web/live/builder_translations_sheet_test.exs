# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderTranslationsSheetTest do
  @moduledoc """
  The visual editor's Translations sheet, driven through the real `BuilderLive`.

  The sheet is where an author translates the words a document asks `t/1` for without leaving the
  editor: the More menu opens it, it reads the keys off the tree AS IT STANDS — a `t("…")` typed a
  moment ago included — registers them in every language the site publishes in, and shows them in
  the same Gervaz table and form the Translations admin page uses. Proved here:

    * the menu offers it and choosing it opens the sheet;
    * a document with `t/1` calls lists exactly its own words and registers the missing rows —
      a new language, a word not yet saved — without touching a translation already written;
    * a document with none says how to ask for one and mounts no table;
    * the table lists a word once, its languages as chips; Translate opens it in every language,
      the first missing one picked, and Save writes the value (Persian ZWNJ intact) and moves on to
      the next missing one; Cancel and All words go back to the list, and Delete removes the word
      in every language;
    * who registers what: a site admin registers under their own site and never mints a global
      row, a master opening a global component registers global rows, and a site admin's table
      shows their own rows and the global ones — never another site's.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{Translation, Translations}
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.States.{SiteState, TranslationsState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @password "Password123!"
  @plain ~s(<section id="hero"><h1>Contact Us</h1><p>Reach out any time.</p></section>)

  # "دسته‌بندی‌ها" spelled out, so the two zero-width non-joiners it is written with are visible in
  # this file rather than trusted to survive an editor.
  @categories_fa "دسته\u200Cبندی\u200Cها"

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
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    n = System.unique_integer([:positive])

    {:ok,
     conn: log_in(on_host(conn), admin!("master-#{n}@example.com")),
     tenant_conn:
       log_in(on_host(Phoenix.ConnTest.build_conn()), admin!("tenant-#{n}@example.com", site.id)),
     site: site,
     n: n}
  end

  defp on_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp permission! do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp admin!(email, site_id \\ nil) do
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
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open(conn, section, record) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/#{section}/#{record.id}")
    render_async(view)
    view
  end

  # THE TABLE LOADS ITS PAGE THROUGH `start_async`, after the click that opened the sheet has already
  # been answered — so the rows are in the HTML only once `render_async/1` has waited for it.
  defp open_translations(view) do
    render_click(view, "open_sheet", %{"sheet" => "translations"})
    render_async(view)
    view
  end

  # A MESSAGE THE VIEW IS SENT IS HANDLED AFTER THE EVENT THAT SENT IT HAS BEEN ANSWERED — a Gervaz
  # row action, a form's `{:form_saved, …}` — so a plain `render/1` straight after can still be
  # holding the HTML from before it. `:sys.get_state/1` returns once the view has worked through
  # everything already in its mailbox; `render_async/1` then waits for what that started, such as the
  # form reading its record or the table reloading its page.
  defp settle(view) do
    _handled = :sys.get_state(view.pid)
    render_async(view)
  end

  defp page_asking(site, keys) do
    words = Enum.map_join(keys, &~s|<p>{t("#{&1}")}</p>|)
    create_page!(site_id: site.id, template: ~s|<section id="hero">#{words}</section>|)
  end

  # Every row for `key`, whatever its site — read the way the cache reads, past every policy, so what
  # comes back is what is in the table and not what some actor may see of it.
  defp rows(key) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key == ^key)
    |> Ash.read!(authorize?: false, page: false)
  end

  defp row!(key, site_id, language),
    do: Enum.find(rows(key), &(&1.site_id == site_id and &1.language == language))

  defp languages(rows), do: rows |> Enum.map(& &1.language) |> Enum.sort()

  # SAVING A TEMPLATE REGISTERS ITS KEYS, so a fixture created with `t("…")` in it already has its
  # rows. A test about what the SHEET registers has to start from none of them.
  defp forget_rows!(key),
    do: Enum.each(rows(key), &Ash.destroy!(&1, action: :master_destroy, authorize?: false))

  # A written translation reaches `TranslationsState` over PubSub, and that ETS table outlives the
  # sandbox — so the entry goes when the test does.
  defp translate!(row, value) do
    on_exit(fn -> TranslationsState.put(row.site_id, row.language, row.key, nil) end)
    Ash.update!(row, %{value: value}, action: :master_update, authorize?: false)
  end

  defp row_selector(row), do: "#pb-translations_translations-#{row.id}"

  # THE LIST SHOWS A WORD ONCE: its first language by code stands for the rest, whose chips it wears.
  defp word_row!(key, site_id),
    do: rows(key) |> Enum.filter(&(&1.site_id == site_id)) |> Enum.min_by(& &1.language)

  defp chips(row), do: "#pb-translations-languages-#{row.id}"

  defp group(view), do: :sys.get_state(view.pid).socket.assigns.translation_group

  defp open_word(view, row) do
    send(view.pid, {:row_action, "edit_translation", %{"id" => row.id}})
    settle(view)
    view
  end

  defp pick(view, language) do
    view |> element("#pb-translation-group-language-#{language}") |> render_click()
    settle(view)
    view
  end

  # Open the word, pick the row's language, then the form's own Save under the params Gervaz names
  # it with. The cache entry the save puts in `TranslationsState` outlives the sandbox, so it goes
  # with the test.
  defp save!(view, row, value) do
    on_exit(fn -> TranslationsState.put(row.site_id, row.language, row.key, nil) end)

    view |> open_word(row) |> pick(row.language)

    view
    |> element("#translation_form-form")
    |> render_submit(%{"form" => %{"value" => value}})

    settle(view)
  end

  defp expression(view, text) do
    {:ok, editor} = EditorSession.fetch(:sys.get_state(view.pid).socket.assigns.token)
    Enum.find(Tree.walk(editor.tree), &(&1.kind == :eex and &1.text == text))
  end

  describe "the More menu" do
    test "offers Translations", %{conn: conn, site: site} do
      view = open(conn, "page", create_page!(site_id: site.id, template: @plain))

      assert has_element?(view, "#pb-more-translations")
    end

    test "opens the Translations sheet when it is chosen", %{conn: conn, site: site} do
      view = open(conn, "page", create_page!(site_id: site.id, template: @plain))
      refute has_element?(view, "#pb-translations-sheet")

      view |> element("#pb-more-translations") |> render_click()

      assert has_element?(view, "#pb-translations-sheet")
    end
  end

  describe "a document that asks for no words" do
    test "says how to ask for one and mounts no table", %{conn: conn, site: site} do
      view =
        conn
        |> open("page", create_page!(site_id: site.id, template: @plain))
        |> open_translations()

      assert has_element?(view, "#pb-translations-sheet")
      assert has_element?(view, "#pb-translations-empty")
      refute has_element?(view, "#pb-translations")
    end
  end

  # `t/1` IS IMPORTED INTO THE CODE TOO, so a word only a handler or a helper asks for is on the
  # document as much as one its markup asks for.
  describe "a document whose code asks t/1 for words" do
    test "lists and registers them beside the template's", %{conn: conn, site: site, n: n} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s|<section id="hero"><p>{t("Shown #{n}")}</p></section>|,
          events: [
            %{name: "save", code: ~s|{:noreply, put_flash(socket, :info, t("Saved #{n}"))}|}
          ],
          helpers: [%{name: "label", args: "", code: ~s|t("Labelled #{n}")|}]
        )

      keys = ["Shown #{n}", "Saved #{n}", "Labelled #{n}"]
      Enum.each(keys, &forget_rows!/1)

      view = conn |> open("page", page) |> open_translations()

      for key <- keys do
        assert languages(rows(key)) == ["en", "fa"], "#{key} was not registered"
        assert has_element?(view, row_selector(word_row!(key, site.id))), "#{key} is not listed"
      end
    end
  end

  describe "a document whose template asks t/1 for words" do
    test "lists its own words in the table and not another document's", %{
      conn: conn,
      site: site,
      n: n
    } do
      page = page_asking(site, ["Welcome #{n}", "Read more #{n}"])
      _elsewhere = page_asking(site, ["Elsewhere #{n}"])

      view = conn |> open("page", page) |> open_translations()

      assert has_element?(view, "#pb-translations")
      refute has_element?(view, "#pb-translations-empty")

      for key <- ["Welcome #{n}", "Read more #{n}"] do
        word = word_row!(key, site.id)
        assert has_element?(view, row_selector(word)), "#{key} is missing from the sheet"
        assert has_element?(view, chips(word), "EN")
        assert has_element?(view, chips(word), "FA")

        refute has_element?(view, row_selector(row!(key, site.id, "fa"))),
               "#{key} is listed once per language instead of once"
      end

      refute has_element?(view, row_selector(word_row!("Elsewhere #{n}", site.id))),
             "a word only another page asks for is on this page's sheet"
    end

    # The backfill case: a page saved while the site spoke only English has no Persian rows, and the
    # sheet is the first place an author would notice.
    test "registers a word in a language the site gained after the page was saved", %{
      conn: conn,
      site: site,
      n: n
    } do
      key = "Welcome #{n}"
      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
      page = page_asking(site, [key])
      assert languages(rows(key)) == ["en"]

      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      view = conn |> open("page", page) |> open_translations()

      assert languages(rows(key)) == ["en", "fa"]
      assert %Translation{value: nil} = row!(key, site.id, "fa")
      assert has_element?(view, chips(word_row!(key, site.id)), "FA")
    end

    test "registers a word typed in the editor before it has been saved", %{
      conn: conn,
      site: site,
      n: n
    } do
      page = page_asking(site, ["Welcome #{n}"])
      view = open(conn, "page", page)

      node = expression(view, ~s|t("Welcome #{n}")|)
      assert node, "the fixture has to contain the t/1 expression"

      render_change(view, "op", %{
        "kind" => "set_text",
        "node_id" => node.id,
        "text" => ~s|t("Typed #{n}")|
      })

      assert rows("Typed #{n}") == [], "nothing but the sheet should have registered the new word"

      open_translations(view)

      assert languages(rows("Typed #{n}")) == ["en", "fa"]
      assert Enum.all?(rows("Typed #{n}"), &(&1.site_id == site.id))
      assert has_element?(view, row_selector(word_row!("Typed #{n}", site.id)))
    end

    # Opening the sheet registers on every visit, so this is the guarantee that makes that safe.
    test "leaves a translation somebody already wrote exactly as it was", %{
      conn: conn,
      site: site,
      n: n
    } do
      key = "Categories #{n}"
      page = page_asking(site, [key])
      translate!(row!(key, site.id, "fa"), @categories_fa)

      conn |> open("page", page) |> open_translations()

      assert row!(key, site.id, "fa").value == @categories_fa
      assert row!(key, site.id, "en").value == nil
    end
  end

  describe "translating a word from the sheet" do
    setup %{conn: conn, site: site, n: n} do
      key = "Categories #{n}"
      view = conn |> open("page", page_asking(site, [key])) |> open_translations()

      %{view: view, key: key, row: row!(key, site.id, "fa"), word: word_row!(key, site.id)}
    end

    test "Translate opens the word in every language, in place of the list", %{
      view: view,
      word: word,
      key: key
    } do
      view
      |> element(~s(#{row_selector(word)} [phx-value-event="edit_translation"]))
      |> render_click()

      settle(view)

      assert has_element?(view, "#pb-translation-group-key", key)
      assert has_element?(view, "#pb-translation-group-language-en")
      assert has_element?(view, "#pb-translation-group-language-fa")
      assert has_element?(view, ~s(#translation_form-form textarea[name="form[value]"]))
      refute has_element?(view, "#pb-translations"), "the list is still drawn under the word"
    end

    test "the first missing language is picked, and a click picks another", %{
      view: view,
      site: site,
      key: key,
      row: row
    } do
      open_word(view, row)
      assert group(view).picked == row!(key, site.id, "en").id

      pick(view, "fa")

      assert group(view).picked == row.id
      assert has_element?(view, "#pb-translation-group-form", "FA")
    end

    test "Save writes the translation, moves on to the next missing one, and serves it", %{
      view: view,
      row: row,
      site: site,
      key: key
    } do
      save!(view, row, @categories_fa)

      assert row!(key, site.id, "fa").value == @categories_fa
      assert group(view).picked == row!(key, site.id, "en").id, "the next missing one is not up"
      assert has_element?(view, "#pb-translation-group-language-fa", @categories_fa)

      _handled = :sys.get_state(TranslationsState)
      assert TranslationsState.lookup(site.id, "fa", key) == @categories_fa
    end

    # THE TABLE REDRAWS UNDER THE NOTICE. A save is answered by reloading the sheet's table, and a
    # table that patches the URL as it loads replaces the editor's flash with its own empty one — so
    # the notice is asserted after that reload has run, where the author would be reading it.
    test "Save says so, and the notice outlives the table redrawing under it", %{
      view: view,
      row: row
    } do
      save!(view, row, @categories_fa)

      assert has_element?(view, "#flash-info", "Translation saved.")
    end

    # Gervaz's form tells its parent it was cancelled only when the resource's form declares an
    # `on_cancel` hook; the sheet goes back to the list on that message.
    test "Cancel goes back to the list and writes nothing", %{
      view: view,
      row: row,
      site: site,
      key: key
    } do
      view |> open_word(row) |> pick("fa")

      view |> element(~s(#pb-translation-group-form button[title="Cancel"])) |> render_click()
      settle(view)

      refute has_element?(view, "#pb-translation-group")
      assert has_element?(view, "#pb-translations")
      assert row!(key, site.id, "fa").value == nil
    end

    test "All words goes back to the list", %{view: view, row: row} do
      open_word(view, row)

      view |> element("#pb-translation-back") |> render_click()
      settle(view)

      assert group(view) == nil
      assert has_element?(view, "#pb-translations")
    end

    test "Delete removes the word in every language", %{view: view, word: word, key: key} do
      send(view.pid, {:row_action, "delete_translation_key", %{"id" => word.id}})
      settle(view)

      assert rows(key) == []
      assert has_element?(view, "#flash-info", "Deleted in every language (2).")
    end
  end

  # THE SHEET'S TABLE HEARS ITS WORDS CHANGE — the editor forwards the resource's broadcasts to it, as
  # the admin list's page does, and nothing reloads it.
  describe "over PubSub" do
    test "a translation written elsewhere reaches the open sheet", %{conn: conn, site: site, n: n} do
      key = "Heard #{n}"
      view = conn |> open("page", page_asking(site, [key])) |> open_translations()
      word = word_row!(key, site.id)
      assert has_element?(view, ~s(#{chips(word)} span[title="FA — missing"]))

      translate!(row!(key, site.id, "fa"), "شنیده")
      settle(view)

      assert has_element?(view, ~s(#{chips(word)} span[title="FA — translated"]))
    end

    test "a word the document does not ask for is not handed to the sheet", %{
      conn: conn,
      site: site,
      n: n
    } do
      view = conn |> open("page", page_asking(site, ["Ours #{n}"])) |> open_translations()
      :ok = Translations.register(site.id, ["Not ours #{n}"])
      settle(view)

      refute has_element?(view, row_selector(word_row!("Not ours #{n}", site.id)))
    end
  end

  # A PAGE'S WORDS INCLUDE ITS COMPONENTS' — nested ones too — each registered under the site the
  # component belongs to, not the page's.
  describe "the words of the components a page renders" do
    test "are listed, and registered under the component's own site", %{
      conn: conn,
      site: site,
      n: n
    } do
      create_component!(
        site_id: site.id,
        name: "card-#{n}",
        template: ~s|<div>{t("Card word #{n}")}</div>|
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<section id="hero"><.component component_name="card-#{n}" site="localhost" /></section>|
        )

      view = conn |> open("page", page) |> open_translations()

      assert languages(rows("Card word #{n}")) == ["en", "fa"]
      assert Enum.all?(rows("Card word #{n}"), &(&1.site_id == site.id))
      assert has_element?(view, row_selector(word_row!("Card word #{n}", site.id)))
    end

    test "nested global components' words come too, as global rows", %{
      conn: conn,
      site: site,
      n: n
    } do
      create_component!(
        site_id: nil,
        name: "inner-#{n}",
        template: ~s|<p>{t("Inner word #{n}")}</p>|
      )

      create_component!(
        site_id: site.id,
        name: "outer-#{n}",
        template: ~s|<div><.component component_name="inner-#{n}" site="Global" /></div>|
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<section id="hero"><.component component_name="outer-#{n}" site="localhost" /></section>|
        )

      forget_rows!("Inner word #{n}")
      view = conn |> open("page", page) |> open_translations()

      assert rows("Inner word #{n}") != []
      assert Enum.all?(rows("Inner word #{n}"), &is_nil(&1.site_id))
      assert has_element?(view, row_selector(word_row!("Inner word #{n}", nil)))
    end

    test "a site admin's sheet lists a global component's words without minting global rows", %{
      tenant_conn: conn,
      site: site,
      n: n
    } do
      create_component!(
        site_id: nil,
        name: "shared-#{n}",
        template: ~s|<p>{t("Shared word #{n}")}</p>|
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<section id="hero"><.component component_name="shared-#{n}" site="Global" /></section>|
        )

      forget_rows!("Shared word #{n}")
      conn |> open("page", page) |> open_translations()

      assert rows("Shared word #{n}") == [], "a site admin minted global rows"
    end
  end

  test "the sheet has no Used column: every word listed is one this document asks for", %{
    conn: conn,
    site: site,
    n: n
  } do
    view = conn |> open("page", page_asking(site, ["Asked #{n}"])) |> open_translations()

    refute has_element?(view, "#pb-translations_translations-thead", "Used")
    assert has_element?(view, "#pb-translations_translations-thead", "Languages")
  end

  test "Add language in the sheet publishes it on the page's site", %{
    conn: conn,
    site: site,
    n: n
  } do
    MishkaCmsCore.DataCase.forget_settings(~w(site.languages), [site.id])
    key = "Grow #{n}"
    view = conn |> open("page", page_asking(site, [key])) |> open_translations()
    open_word(view, row!(key, site.id, "en"))

    view
    |> element("#pb-translation-group-add-language")
    |> render_submit(%{"language" => "de"})

    settle(view)

    assert "de" in Settings.get("site.languages", nil, site.id)
    assert "de" in languages(rows(key))
    assert has_element?(view, "#pb-translation-group-language-de")
  end

  describe "who a visit registers words for" do
    test "a site admin registers under their own site and mints no global row", %{
      tenant_conn: conn,
      site: site,
      n: n
    } do
      view = open(conn, "page", page_asking(site, ["Welcome #{n}"]))

      render_change(view, "op", %{
        "kind" => "set_text",
        "node_id" => expression(view, ~s|t("Welcome #{n}")|).id,
        "text" => ~s|t("Ours #{n}")|
      })

      open_translations(view)

      assert languages(rows("Ours #{n}")) == ["en", "fa"]
      assert Enum.all?(rows("Ours #{n}"), &(&1.site_id == site.id))
    end

    # A GLOBAL ROW IS A MASTER'S TO MINT. The refusal at the door is where that holds: a site admin
    # never gets an editor over a global component, so no sheet of theirs ever reads its keys.
    test "a site admin is turned away from a global component, and no global row is minted", %{
      tenant_conn: conn,
      n: n
    } do
      key = "Shared #{n}"

      component =
        create_component!(
          site_id: nil,
          name: "shared-words-#{n}",
          template: ~s|<section id="root"><h2>{t("#{key}")}</h2></section>|
        )

      forget_rows!(key)

      assert {:error, {:redirect, %{flash: %{"error" => error}}}} =
               live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert error =~ "shared with every site"
      assert rows(key) == []
    end

    test "a master opening a global component registers its words as global rows", %{
      conn: conn,
      n: n
    } do
      key = "Shared #{n}"

      component =
        create_component!(
          site_id: nil,
          name: "shared-words-#{n}",
          template: ~s|<section id="root"><h2>{t("#{key}")}</h2></section>|
        )

      forget_rows!(key)

      view = conn |> open("component", component) |> open_translations()

      assert languages(rows(key)) == Translations.languages(nil)
      assert Enum.all?(rows(key), &is_nil(&1.site_id))

      word = word_row!(key, nil)
      assert has_element?(view, row_selector(word))

      for language <- Translations.languages(nil),
          do: assert(has_element?(view, chips(word), String.upcase(language)))
    end

    # THE SHEET SCOPES BY KEY ALONE and leaves which sites' rows come back to the resource's read
    # policy. Another site asking for the same word is exactly the row that policy has to keep out.
    test "a site admin's sheet shows their own rows and the global ones, never another site's", %{
      tenant_conn: conn,
      site: site,
      n: n
    } do
      key = "Welcome #{n}"
      page = page_asking(site, [key])

      other = create_site!()
      :ok = Translations.register(other.id, [key])
      :ok = Translations.register(nil, [key])

      view = conn |> open("page", page) |> open_translations()

      assert has_element?(view, row_selector(word_row!(key, site.id)))
      assert has_element?(view, row_selector(word_row!(key, nil)))

      for row <- Enum.filter(rows(key), &(&1.site_id == other.id)) do
        refute has_element?(view, row_selector(row)),
               "another site's #{row.language} row is on a site admin's sheet"
      end
    end
  end
end
