# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.TranslationsTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.Translations` — what `t/1` renders, which keys a template asks for, and the
  rows those keys become.

  A template is the only source of keys, so `keys/1` has to find exactly the ones `t/1` will be
  asked for at render and nothing that merely looks like them. `translate/2` has to answer from
  this site's row, then the global one, then the key, and never from another site's row. The rows
  themselves are written by `register/2` and `sync/1` under the site of the template that asks for
  them, and deleted by `purge_unused/2` only when no template asks any more — and only the ones the
  actor may delete.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaCmsCore.Runtime.{Languages, Translation, Translations}
  alias MishkaCmsCore.Runtime.States.{SiteState, TranslationsState}
  alias MishkaCmsCore.Settings
  alias MishkaGervaz.Table.Types.Filter.Text

  require Ash.Query

  @moduletag :integration

  @backend MishkaCmsCore.Gettext

  defp unique(label), do: "#{label} #{System.unique_integer([:positive])}"

  defp site_in!(languages) do
    site = create_site!()
    forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", languages, site_id: site.id)
    site
  end

  # `site_in!/1`, and known to `SiteState` besides, as a booted site is — `Translations.languages/1`
  # reads a global row's languages from the sites the cache knows. A host of its own keeps it from
  # colliding with a site another test left there.
  defp published_site!(languages) do
    n = System.unique_integer([:positive])
    site = create_site!(name: "published-#{n}", host: "published-#{n}.test")
    forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", languages, site_id: site.id)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  # The cache is process-global and outlives the sandbox that rolls the database back, so whatever
  # a test puts in it is taken out again when the test ends.
  defp cache!(site_id, language, key, value) do
    :ok = TranslationsState.put(site_id, language, key, value)
    on_exit(fn -> TranslationsState.put(site_id, language, key, nil) end)
  end

  defp answering(language, site_id) do
    Gettext.put_locale(@backend, language)
    Translations.put_site(site_id)
  end

  defp rows(keys) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key in ^keys)
    |> Ash.read!(authorize?: false, page: false)
  end

  defp shape(rows) do
    rows
    |> Enum.map(&{&1.site_id, &1.key, &1.language, &1.value})
    |> Enum.sort()
  end

  defp row!(site_id, key, language) do
    [row] =
      [key]
      |> rows()
      |> Enum.filter(&(&1.site_id == site_id and &1.language == language))

    row
  end

  # Writes a value the way the admin does, then waits for the broadcast to reach the cache: the
  # call is answered only after every message sent to the cache before it has been handled.
  defp write!(row, value) do
    on_exit(fn -> TranslationsState.put(row.site_id, row.language, row.key, nil) end)

    written =
      row
      |> Ash.Changeset.for_update(:master_update, %{value: value}, authorize?: false)
      |> Ash.update!()

    _ = :sys.get_state(TranslationsState)
    written
  end

  # What a template saved before `t/1` existed looks like: keys in its template, no rows for them.
  defp unregister!(keys) do
    %Ash.BulkResult{status: :success} =
      keys
      |> rows()
      |> Ash.bulk_destroy(:master_destroy, %{},
        authorize?: false,
        strategy: [:stream],
        return_errors?: true
      )

    assert rows(keys) == []
  end

  defp template(keys), do: Enum.map_join(keys, &~s|<p>{t("#{&1}")}</p>|)

  describe "keys/1 — what a template asks t/1 for" do
    test "reads every double-quoted literal passed to t, in the order first asked, each once" do
      template =
        ~S|{t("A")}{t("B", n: 1)}{format("C")}{Foo.t("D")}{t("Say \"hi\"")}{t("E #{x}")}{t("A")}|

      assert Translations.keys(template) == ["A", "B", ~s(Say "hi")]
    end

    # `format(`, `list(` and `Foo.t(` all end in `t(`; only a call to the imported `t` is a key.
    test "refuses anything that only ends in t(" do
      assert Translations.keys(~S|{format("A")}{list("B")}{Foo.t("C")}{:t("D")}{at("E")}|) == []
    end

    test "unescapes a literal the way the compiler will read it" do
      assert Translations.keys(~S|{t("Say \"hi\"")}|) == [~s(Say "hi")]
      assert Translations.keys(~S|{t("a\\b")}|) == ["a\\b"]
    end

    # An interpolated literal names a different key on every render, so there is none to register.
    test "skips an interpolated literal" do
      assert Translations.keys(~S|{t("Hello #{@name}")}|) == []
    end

    test "skips what is not a literal, and a literal that is empty" do
      assert Translations.keys(~S|{t(@label)}{t(label)}{t('charlist')}{t("")}|) == []
    end

    test "is nothing for an empty template, or for anything that is not a template" do
      assert Translations.keys("") == []
      assert Translations.keys(nil) == []
      assert Translations.keys(42) == []
      assert Translations.keys(%{template: ~S|{t("A")}|}) == []
    end

    test "reads a literal with whitespace around it" do
      assert Translations.keys(~S|{t(  "Spaced"  )}{t("Bound", count: 1 )}|) == [
               "Spaced",
               "Bound"
             ]
    end

    test "reads a call split across lines" do
      template = """
      <section>
        <h2>{t(
          "Categories"
        )}</h2>
        <p>{t("Read %{count} posts",
              count: @count)}</p>
      </section>
      """

      assert Translations.keys(template) == ["Categories", "Read %{count} posts"]
    end

    test "reads a call in attribute position" do
      template = ~S|<.card heading={t("Tags")} label={t("More")}>{t("Body")}</.card>|

      assert Translations.keys(template) == ["Tags", "More", "Body"]
    end

    # The key is matched byte for byte at render, so a zero-width non-joiner dropped here would be a
    # key no template ever asks for again.
    test "keeps a key exactly as written, zero-width non-joiners included" do
      [key] = Translations.keys(~s|{t("دسته‌بندی‌ها")}|)

      assert key == "دسته‌بندی‌ها"
      assert length(String.split(key, "\u200C")) == 3
    end
  end

  describe "translate/2 — which row answers" do
    setup do
      %{site: create_site!(), other_site: create_site!(), key: unique("Categories")}
    end

    test "is the site's own row before the global one", %{site: site, key: key} do
      cache!(site.id, "fa", key, "دسته‌های این سایت")
      cache!(nil, "fa", key, "دسته‌ها")
      answering("fa", site.id)

      assert Translations.translate(key) == "دسته‌های این سایت"
    end

    test "is the global row when the site has none", %{site: site, key: key} do
      cache!(nil, "fa", key, "دسته‌ها")
      answering("fa", site.id)

      assert Translations.translate(key) == "دسته‌ها"
    end

    test "is the key itself when nothing is written", %{site: site, key: key} do
      answering("fa", site.id)

      assert Translations.translate(key) == key
    end

    test "is in the language Gettext answers in", %{site: site, key: key} do
      cache!(site.id, "fa", key, "دسته‌ها")
      cache!(site.id, "ar", key, "الفئات")

      answering("fa", site.id)
      assert Translations.translate(key) == "دسته‌ها"

      answering("ar", site.id)
      assert Translations.translate(key) == "الفئات"

      answering("en", site.id)
      assert Translations.translate(key) == key
    end

    # A site admin writes their own site's words; another site's must never render in its place.
    test "never reads another site's row", %{site: site, other_site: other_site, key: key} do
      cache!(other_site.id, "fa", key, "the other site's")
      answering("fa", site.id)

      assert Translations.translate(key) == key
    end

    test "reads the global row alone when no site is named", %{site: site, key: key} do
      cache!(site.id, "fa", key, "the site's")
      cache!(nil, "fa", key, "global")
      Gettext.put_locale(@backend, "fa")

      assert Translations.translate(key) == "global"

      Translations.put_site(nil)
      assert Translations.translate(key) == "global"
    end

    # The same path `t/1` takes on a real page: written through the resource, carried to the cache
    # by its broadcast, read back by `translate/2`.
    test "renders what the admin wrote, zero-width non-joiners intact" do
      site = site_in!(["en", "fa"])
      key = unique("Categories")
      :ok = Translations.register(site.id, [key])

      site.id |> row!(key, "fa") |> write!("دسته‌بندی‌ها")
      answering("fa", site.id)

      assert Translations.translate(key) == "دسته‌بندی‌ها"
      assert length(String.split(Translations.translate(key), "\u200C")) == 3
    end

    # Clearing a value means "show the key again", so the old word must not outlive it.
    test "is the key again once its value is emptied" do
      site = site_in!(["en", "fa"])
      key = unique("Tags")
      :ok = Translations.register(site.id, [key])
      row = site.id |> row!(key, "fa") |> write!("برچسب‌ها")
      answering("fa", site.id)
      assert Translations.translate(key) == "برچسب‌ها"

      write!(row, nil)

      assert Translations.translate(key) == key
    end
  end

  describe "translate/2 — what comes back" do
    setup do
      Gettext.put_locale(@backend, "fa")
      Translations.put_site(nil)
      %{key: unique("Read %{count} posts")}
    end

    test "fills placeholders from a keyword list", %{key: key} do
      assert Translations.translate(key, count: 3) == String.replace(key, "%{count}", "3")
    end

    test "fills placeholders from a map, keyed by atom or by string", %{key: key} do
      expected = String.replace(key, "%{count}", "3")

      assert Translations.translate(key, %{count: 3}) == expected
      assert Translations.translate(key, %{"count" => 3}) == expected
    end

    test "fills the placeholders of the translation, not only of the key", %{key: key} do
      cache!(nil, "fa", key, "خواندن %{count} نوشته")

      assert Translations.translate(key, count: 3) == "خواندن 3 نوشته"
    end

    test "fills every placeholder that has a binding, however often it appears" do
      assert Translations.translate("%{a} and %{b}, then %{a}", a: 1, b: "two") ==
               "1 and two, then 1"
    end

    test "leaves a placeholder with no binding as written" do
      assert Translations.translate("Hi %{name}, %{missing}", name: "Ali") ==
               "Hi Ali, %{missing}"

      assert Translations.translate("100%{done}") == "100%{done}"
      assert Translations.translate("100%{done}", %{}) == "100%{done}"
    end

    # `t(@label)` with nothing assigned is still something to render.
    test "renders a key that is not a string as text" do
      assert Translations.translate(nil) == ""
      assert Translations.translate(nil, count: 1) == ""
      assert Translations.translate(:Tags) == "Tags"
      assert Translations.translate(42) == "42"
      assert Translations.translate(:"%{n} left", n: 2) == "2 left"
    end

    # The value is whatever an admin typed, so it is text to HEEx, never markup.
    test "is a plain string that HEEx escapes, never safe HTML", %{key: key} do
      cache!(nil, "fa", key, "<script>alert(1)</script>")

      value = Translations.translate(key)
      assert value == "<script>alert(1)</script>"
      assert is_binary(value)

      assigns = %{key: key}

      assert rendered_to_string(~H"<p>{Translations.translate(@key)}</p>") ==
               "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>"
    end

    test "escapes a binding the same way" do
      assigns = %{greeting: Translations.translate("Hi %{name}", name: "<b>x</b>")}

      assert rendered_to_string(~H"<p>{@greeting}</p>") == "<p>Hi &lt;b&gt;x&lt;/b&gt;</p>"
    end
  end

  # A TEMPLATE DOES NOT WAIT FOR THE CACHE. The host starts its endpoint before `TranslationsState`,
  # and restarts the cache like any other child, so `t/1` can be asked while its table is not there.
  describe "translate/2 while the cache is not running" do
    setup do
      site = create_site!()
      :ok = Supervisor.terminate_child(MishkaCmsCore.TestSupervisor, TranslationsState)
      on_exit(fn -> Supervisor.restart_child(MishkaCmsCore.TestSupervisor, TranslationsState) end)
      answering("fa", site.id)

      %{site: site, key: unique("Categories")}
    end

    test "is the key, its placeholders filled", %{key: key} do
      assert Translations.translate(key) == key
      assert Translations.translate("Read %{count} posts", count: 3) == "Read 3 posts"
    end

    test "finds no row and no language", %{site: site, key: key} do
      assert TranslationsState.lookup(site.id, "fa", key) == nil
      assert TranslationsState.lookup(nil, "fa", key) == nil
      assert TranslationsState.languages() == []
    end
  end

  describe "register/2" do
    setup do
      %{site: site_in!(["en", "fa"])}
    end

    test "gives every key an empty row in every language the site publishes in", %{site: site} do
      [hello, bye] = [unique("Hello"), unique("Bye")]

      assert Translations.register(site.id, [hello, bye]) == :ok

      assert shape(rows([hello, bye])) ==
               Enum.sort(
                 for key <- [hello, bye],
                     language <- ["en", "fa"],
                     do: {site.id, key, language, nil}
               )
    end

    test "adds nothing the second time", %{site: site} do
      key = unique("Hello")
      :ok = Translations.register(site.id, [key])
      first = shape(rows([key]))

      :ok = Translations.register(site.id, [key])

      assert shape(rows([key])) == first
      assert length(first) == 2
    end

    # Saving a template again runs this again; a translation somebody wrote must survive it.
    test "never touches a value somebody wrote", %{site: site} do
      key = unique("Categories")
      :ok = Translations.register(site.id, [key])
      site.id |> row!(key, "fa") |> write!("دسته‌بندی‌ها")

      :ok = Translations.register(site.id, [key])

      assert row!(site.id, key, "fa").value == "دسته‌بندی‌ها"
      assert row!(site.id, key, "en").value == nil
    end

    test "fills in a language the site gained, and leaves the others as they were", %{site: site} do
      key = unique("Tags")
      :ok = Translations.register(site.id, [key])
      site.id |> row!(key, "fa") |> write!("برچسب‌ها")

      {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)
      :ok = Translations.register(site.id, [key])

      assert shape(rows([key])) == [
               {site.id, key, "ar", nil},
               {site.id, key, "en", nil},
               {site.id, key, "fa", "برچسب‌ها"}
             ]
    end

    test "writes nothing for no keys", %{site: site} do
      assert Translations.register(site.id, []) == :ok

      assert Translation
             |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
             |> Ash.Query.filter(site_id == ^site.id)
             |> Ash.read!(authorize?: false, page: false) == []
    end

    test "writes global rows for the global scope, in every language a site publishes in" do
      key = unique("Home")

      :ok = Translations.register(nil, [key])

      assert shape(rows([key])) ==
               for(language <- Translations.languages(nil), do: {nil, key, language, nil})
    end

    # A GLOBAL COMPONENT RENDERS ON EVERY SITE. Registered in the global list alone, its words had no
    # Persian row on a site that publishes Persian — and `published_language/2` refused one added by
    # hand — so a global component could never be translated into a language only a site speaks.
    test "a global row is registered in a language only a site publishes in" do
      published_site!(["en", "ku"])
      key = unique("Global")

      :ok = Translations.register(nil, [key])

      assert {nil, key, "ku", nil} in shape(rows([key]))
    end

    # Matched byte for byte against the literal in `t("…")` — a trimmed key is never asked for.
    test "stores a key exactly as given", %{site: site} do
      [padded, persian] = ["  #{unique("Padded")}  ", "دسته‌بندی‌ها #{unique("")}"]

      :ok = Translations.register(site.id, [padded, persian])

      assert rows([padded, persian]) |> Enum.map(& &1.key) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort([padded, persian])
    end
  end

  # A NEW ROW IS ANNOUNCED, AS A COMPONENT OR A LAYOUT IS: on the site's own topic and on the shared
  # one. That is what keeps an admin list open on the words current without a reload — and what
  # keeps a re-registration of rows already there from announcing anything at all.
  describe "register/2 on the resource's PubSub" do
    setup do
      site = site_in!(["en", "fa"])
      other = site_in!(["en"])
      key = unique("Announced")

      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "translation:#{site.id}:updated")
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "translation:#{other.id}:updated")
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "translation:updated")

      %{site: site, other: other, key: key}
    end

    test "each row it writes, on the site's topic and the shared one", %{site: site, key: key} do
      site_topic = "translation:#{site.id}:updated"

      :ok = Translations.register(site.id, [key])

      for language <- ["en", "fa"] do
        assert_receive %Phoenix.Socket.Broadcast{
          topic: ^site_topic,
          payload: %{data: %{key: ^key, language: ^language}}
        }

        assert_receive %Phoenix.Socket.Broadcast{
          topic: "translation:updated",
          payload: %{data: %{key: ^key, language: ^language}}
        }
      end
    end

    test "nothing on another site's topic", %{site: site, other: other, key: key} do
      other_topic = "translation:#{other.id}:updated"

      :ok = Translations.register(site.id, [key])

      refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic}, 200
    end

    test "nothing at all for rows that are already there", %{site: site, key: key} do
      :ok = Translations.register(site.id, [key])
      flush_broadcasts()

      :ok = Translations.register(site.id, [key])

      refute_receive %Phoenix.Socket.Broadcast{}, 200
    end

    test "only the language the site gained, when it gains one", %{site: site, key: key} do
      :ok = Translations.register(site.id, [key])
      flush_broadcasts()
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "de"], site_id: site.id)

      :ok = Translations.register(site.id, [key])

      assert_receive %Phoenix.Socket.Broadcast{payload: %{data: %{language: "de"}}}
      refute_receive %Phoenix.Socket.Broadcast{payload: %{data: %{language: "en"}}}, 200
      refute_receive %Phoenix.Socket.Broadcast{payload: %{data: %{language: "fa"}}}, 200
    end
  end

  defp flush_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{} -> flush_broadcasts()
    after
      100 -> :ok
    end
  end

  describe "unused_ids/2 — what Remove unused lists" do
    setup do
      site = site_in!(["en", "fa"])
      other = site_in!(["en"])
      [kept, gone, theirs] = [unique("Kept"), unique("Gone"), unique("Theirs")]

      create_component!(site_id: site.id, template: template([kept]))
      :ok = Translations.register(site.id, [gone])
      :ok = Translations.register(other.id, [theirs])

      %{
        site: site,
        other: other,
        kept: kept,
        gone: gone,
        theirs: theirs,
        master: create_user_with_permissions!(["admin:dashboard:*"]),
        site_admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      }
    end

    defp ids_of(keys), do: keys |> rows() |> Enum.map(& &1.id) |> MapSet.new()

    test "a master's :all is every unused row, every site", %{
      master: master,
      gone: gone,
      theirs: theirs,
      kept: kept
    } do
      ids = MapSet.new(Translations.unused_ids(master, :all))

      assert MapSet.subset?(ids_of([gone, theirs]), ids)
      assert MapSet.disjoint?(ids_of([kept]), ids)
    end

    test "a site admin's :all is their own site's unused rows alone", %{
      site_admin: site_admin,
      gone: gone,
      theirs: theirs
    } do
      ids = MapSet.new(Translations.unused_ids(site_admin, :all))

      assert ids == ids_of([gone])
      assert MapSet.disjoint?(ids_of([theirs]), ids)
    end

    test "a site admin asking for another site gets nothing", %{
      site_admin: site_admin,
      other: other
    } do
      assert Translations.unused_ids(site_admin, other.id) == []
    end

    # A MASTER IS A USER WHOSE `site_id` IS NIL. No user at all, or a user-shaped map that names no
    # site, is not one, and reaches nothing — not every site's rows.
    test "no user, and nothing that is not a user, reaches anything", %{site: site} do
      for nobody <- [nil, %{}, %{id: Ecto.UUID.generate()}] do
        assert Translations.unused_ids(nobody, :all) == []
        assert Translations.unused_ids(nobody, site.id) == []
        assert Translations.purge_unused(nobody, :all) == 0
        refute Translations.may_write?(nobody, site.id)
        refute Translations.may_write?(nobody, nil)
      end
    end

    test "only a holder of the translation area writes a site's words", %{site: site, gone: gone} do
      page_admin =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      translator =
        create_user_with_permissions!(["admin:dashboard:runtime:translation"], site_id: site.id)

      refute Translations.may_write?(page_admin, site.id)
      assert Translations.unused_ids(page_admin, site.id) == []
      assert Translations.purge_unused(page_admin, site.id) == 0
      assert {:error, :forbidden} = Translations.add_language(page_admin, site.id, gone, "fa")

      assert Translations.may_write?(translator, site.id)
      assert MapSet.new(Translations.unused_ids(translator, site.id)) == ids_of([gone])
    end

    test "is exactly what purge_unused/2 then deletes", %{master: master, site: site, gone: gone} do
      ids = MapSet.new(Translations.unused_ids(master, site.id))
      assert ids == ids_of([gone])

      assert Translations.purge_unused(master, site.id) == MapSet.size(ids)
      assert rows([gone]) == []
    end
  end

  describe "used_keys/1" do
    setup do
      [site, other_site] = [create_site!(), create_site!()]

      keys = %{
        component: unique("Component key"),
        page: unique("Page key"),
        layout: unique("Layout key"),
        other: unique("Other site key"),
        global: unique("Global key")
      }

      create_component!(site_id: site.id, template: template([keys.component]))
      create_page!(site_id: site.id, template: template([keys.page]))

      create_layout!(
        site_id: site.id,
        template: "<html><body>#{template([keys.layout])}<%= @content %></body></html>"
      )

      create_component!(site_id: other_site.id, template: template([keys.other]))
      create_component!(site_id: nil, template: template([keys.global]))

      %{site: site, other_site: other_site, keys: keys}
    end

    test "is a site's own templates' keys and the global templates', from every kind of template",
         %{site: site, keys: keys} do
      used = Translations.used_keys(site.id)

      assert %MapSet{} = used
      assert keys.component in used
      assert keys.page in used
      assert keys.layout in used
      assert keys.global in used
    end

    test "never includes another site's keys", %{site: site, keys: keys} do
      refute keys.other in Translations.used_keys(site.id)
    end

    # A global row serves every site, so it is used when ANY template asks for it.
    test "is every template's keys for the global scope", %{keys: keys} do
      used = Translations.used_keys(nil)

      for {_kind, key} <- keys, do: assert(key in used, "#{key} is asked for by a template")
    end

    test "follows the template as it is now" do
      site = create_site!()
      [before, now] = [unique("Before"), unique("Now")]
      component = create_component!(site_id: site.id, template: template([before]))
      assert before in Translations.used_keys(site.id)

      component
      |> Ash.Changeset.for_update(:update, %{template: template([now])},
        authorize?: false,
        tenant: site.id,
        context: %{page_code: :package}
      )
      |> Ash.update!()

      used = Translations.used_keys(site.id)
      assert now in used
      refute before in used
    end
  end

  # A key the code asks for — the seeded sign-in pages keep their rate-limit texts, strength labels
  # and quotes there — is as used as one the template asks for.
  describe "a key only the code asks for" do
    setup do
      site = site_in!(["en", "fa"])

      keys = %{
        event: unique("Event key"),
        info: unique("Info key"),
        page_helper: unique("Page helper key"),
        layout_helper: unique("Layout helper key"),
        component_helper: unique("Component helper key")
      }

      create_page!(
        site_id: site.id,
        template: "<div>No keys</div>",
        events: [
          %{name: "said", code: ~s|{:noreply, put_flash(socket, :info, t("#{keys.event}"))}|}
        ],
        infos: [
          %{name: ":said", code: ~s|{:noreply, put_flash(socket, :info, t("#{keys.info}"))}|}
        ],
        helpers: [%{name: "said", args: "", code: ~s|t("#{keys.page_helper}")|}]
      )

      create_layout!(
        site_id: site.id,
        template: "<main>{@inner_content}</main>",
        helpers: [%{name: "said", args: "", code: ~s|t("#{keys.layout_helper}")|}]
      )

      create_component!(
        site_id: site.id,
        template: "<p>No keys</p>",
        helpers: [%{name: "said", args: "", code: ~s|t("#{keys.component_helper}")|}]
      )

      %{site: site, keys: keys, master: create_user_with_permissions!(["admin:dashboard:*"])}
    end

    test "is used, whichever code asks for it", %{site: site, keys: keys} do
      used = Translations.used_keys(site.id)

      for {field, key} <- keys, do: assert(key in used, "#{field}: #{key} is not used")
    end

    test "is not listed by Remove unused, and is kept by it", %{
      site: site,
      keys: keys,
      master: master
    } do
      gone = unique("Gone")
      code_keys = Map.values(keys)
      :ok = Translations.register(site.id, [gone | code_keys])

      assert MapSet.new(Translations.unused_ids(master, site.id)) == ids_of([gone])
      assert Translations.purge_unused(master, site.id) == 2

      assert length(rows(code_keys)) == 2 * length(code_keys)
      assert rows([gone]) == []
    end

    test "is registered by sync/1", %{site: site, keys: keys} do
      code_keys = Map.values(keys)
      unregister!(code_keys)

      :ok = Translations.sync(site.id)

      assert shape(rows(code_keys)) ==
               Enum.sort(for key <- code_keys, l <- ["en", "fa"], do: {site.id, key, l, nil})
    end

    test "is a component's word for the builder's sheet" do
      site = published_site!(["en"])
      n = System.unique_integer([:positive])

      create_component!(
        site_id: site.id,
        name: "coded-#{n}",
        template: template(["Shown #{n}"]),
        helpers: [%{name: "said", args: "", code: ~s|t("Coded #{n}")|}]
      )

      assert Translations.component_words([{"coded-#{n}", site.name}]) ==
               %{site.id => ["Shown #{n}", "Coded #{n}"]}
    end
  end

  describe "source_keys/1" do
    test "reads the template, then the code of the helpers, events and infos, each key once" do
      record = %{
        template: ~S|{t("A")}{t("B")}|,
        helpers: [%{name: "h", args: "", code: ~S|t("C") <> t("A")|}],
        events: [%{"name" => "e", "code" => ~S|t("D")|}],
        infos: [%{name: ":i", code: ~S|{t("E"), format("F")}|}]
      }

      assert Translations.source_keys(record) == ["A", "B", "C", "D", "E"]
    end

    test "a field the record lacks, or leaves unset, asks for nothing" do
      assert Translations.source_keys(%{template: ~S|{t("A")}|}) == ["A"]

      assert Translations.source_keys(%{template: nil, helpers: nil, events: [%{name: "e"}]}) ==
               []

      assert Translations.source_keys(%{}) == []
    end
  end

  describe "sync/1" do
    setup do
      site = site_in!(["en", "fa"])
      [own, global] = [unique("Own"), unique("Shared")]

      create_component!(site_id: site.id, template: template([own]))
      create_component!(site_id: nil, template: template([global]))
      unregister!([own, global])

      %{site: site, own: own, global: global}
    end

    # A global template's key registered as a site row would be translated once per site, and every
    # site but the one it landed on would render the key.
    test "puts each key under its own template's site", %{site: site, own: own, global: global} do
      assert Translations.sync(:all) == :ok

      assert shape(rows([own])) == [{site.id, own, "en", nil}, {site.id, own, "fa", nil}]

      assert shape(rows([global])) ==
               for(language <- Translations.languages(nil), do: {nil, global, language, nil})
    end

    test "a site's scope registers that site's templates alone", %{
      site: site,
      own: own,
      global: global
    } do
      :ok = Translations.sync(site.id)

      assert shape(rows([own])) == [{site.id, own, "en", nil}, {site.id, own, "fa", nil}]
      assert rows([global]) == []
    end

    test "the global scope registers the global templates alone", %{own: own, global: global} do
      :ok = Translations.sync(nil)

      assert rows([own]) == []
      assert rows([global]) |> Enum.map(& &1.site_id) |> Enum.uniq() == [nil]
    end

    test ":all reaches every site", %{site: site, own: own} do
      other_site = site_in!(["en"])
      theirs = unique("Theirs")
      create_page!(site_id: other_site.id, template: template([theirs]))
      unregister!([theirs])

      :ok = Translations.sync(:all)

      assert shape(rows([own])) == [{site.id, own, "en", nil}, {site.id, own, "fa", nil}]
      assert shape(rows([theirs])) == [{other_site.id, theirs, "en", nil}]
    end

    # The backfill for a site that gained a language after its templates were saved.
    test "fills in a language the site gained, keeping what was written", %{site: site} do
      key = unique("Gained")
      create_component!(site_id: site.id, template: template([key]))
      site.id |> row!(key, "fa") |> write!("به‌دست‌آمده")

      {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)
      :ok = Translations.sync(site.id)

      assert shape(rows([key])) == [
               {site.id, key, "ar", nil},
               {site.id, key, "en", nil},
               {site.id, key, "fa", "به‌دست‌آمده"}
             ]
    end
  end

  # `Seo.site_name/2` reads the title's translation, so it is a key of its site like any other.
  describe "the site's title" do
    setup do
      site = site_in!(["en", "fa"])
      title = unique("Studio")
      forget_settings(~w(site.title), [site.id])
      {:ok, _} = Settings.put("site.title", title, site_id: site.id)
      create_component!(site_id: site.id, template: template([unique("Any")]))
      unregister!([title])

      %{site: site, title: title}
    end

    test "sync/1 registers it in each of the site's languages", %{site: site, title: title} do
      :ok = Translations.sync(site.id)

      assert shape(rows([title])) == [{site.id, title, "en", nil}, {site.id, title, "fa", nil}]
    end

    test "used_keys/1 counts it, so Remove unused keeps it", %{site: site, title: title} do
      assert title in Translations.used_keys(site.id)
    end
  end

  describe "purge_unused/2" do
    setup do
      site = site_in!(["en", "fa"])
      other_site = site_in!(["en", "fa"])
      [kept, gone] = [unique("Kept"), unique("Gone")]

      create_component!(site_id: site.id, template: template([kept]))
      :ok = Translations.register(site.id, [gone])

      %{
        site: site,
        other_site: other_site,
        kept: kept,
        gone: gone,
        master: create_user_with_permissions!(["admin:dashboard:*"]),
        site_admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      }
    end

    test "deletes only the rows no template asks for, and says how many",
         %{master: master, site: site, kept: kept, gone: gone} do
      assert Translations.purge_unused(master, site.id) == 2

      assert length(rows([kept])) == 2
      assert rows([gone]) == []
    end

    test "is zero when every row is asked for", %{master: master, site: site} do
      assert Translations.purge_unused(master, site.id) == 2
      assert Translations.purge_unused(master, site.id) == 0
    end

    # A site's row is asked for by the global templates as much as by the site's own.
    test "keeps a site row a global template asks for", %{master: master, site: site} do
      key = unique("Asked globally")
      create_component!(site_id: nil, template: template([key]))
      :ok = Translations.register(site.id, [key])

      Translations.purge_unused(master, site.id)

      assert length(rows([key]) |> Enum.filter(&(&1.site_id == site.id))) == 2
    end

    # A global row serves every site, so one site's template is enough to keep it.
    test "keeps a global row any site's template asks for", %{master: master, kept: kept} do
      unused = unique("Unused globally")
      :ok = Translations.register(nil, [kept, unused])

      Translations.purge_unused(master, nil)

      assert rows([kept]) |> Enum.filter(&is_nil(&1.site_id)) != []
      assert rows([unused]) == []
    end

    test "a site admin purges their own site",
         %{site_admin: site_admin, site: site, kept: kept, gone: gone} do
      assert Translations.purge_unused(site_admin, site.id) == 2

      assert length(rows([kept])) == 2
      assert rows([gone]) == []
    end

    test "a site admin cannot delete another site's rows",
         %{site_admin: site_admin, other_site: other_site} do
      theirs = unique("Theirs")
      :ok = Translations.register(other_site.id, [theirs])

      assert Translations.purge_unused(site_admin, other_site.id) == 0
      assert length(rows([theirs])) == 2
    end

    test "a site admin's :all reaches their own rows and no one else's",
         %{site_admin: site_admin, other_site: other_site, gone: gone} do
      [theirs, global] = [unique("Theirs"), unique("Global unused")]
      :ok = Translations.register(other_site.id, [theirs])
      :ok = Translations.register(nil, [global])

      purged = Translations.purge_unused(site_admin, :all)

      assert rows([gone]) == []
      assert length(rows([theirs])) == 2
      assert rows([global]) != []
      assert purged == 2
    end

    # A purged key a template asks for again gets a new, empty row — and must render as the key,
    # not as the translation the purged row carried.
    test "a purged translation stops rendering", %{master: master, site: site, gone: gone} do
      site.id |> row!(gone, "fa") |> write!("رفته")
      answering("fa", site.id)
      assert Translations.translate(gone) == "رفته"

      Translations.purge_unused(master, site.id)
      _ = :sys.get_state(TranslationsState)

      assert Translations.translate(gone) == gone
    end
  end

  # THE ADMIN LIST SHOWS A WORD ONCE. Its rows are stored per language; the list keeps the first one
  # by code standing for the rest, until someone is looking for a language — a search, a filter.
  describe "one_row_per_key/2" do
    @collapsed %{archive_status: :active, filter_values: %{}, static: %{filters: []}}

    setup do
      site = site_in!(["en", "fa"])
      key = unique("Collapsed")
      :ok = Translations.register(site.id, [key])
      %{site: site, key: key}
    end

    defp listed(state, key) do
      Translation
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(key == ^key)
      |> Translations.one_row_per_key(state)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.map(&{&1.site_id, &1.language})
      |> Enum.sort()
    end

    test "keeps the first language's row alone", %{site: site, key: key} do
      assert listed(@collapsed, key) == [{site.id, "en"}]
    end

    test "is per site: a word's global rows and a site's rows each keep one", %{
      site: site,
      key: key
    } do
      :ok = Translations.register(nil, [key])
      [first_global | _] = Translations.languages(nil)

      assert listed(@collapsed, key) == Enum.sort([{nil, first_global}, {site.id, "en"}])
    end

    # A row per matching language would draw the same word once per language picked.
    test "filtered by language, keeps the word's first row among the picked languages", %{
      site: site,
      key: key
    } do
      state = %{@collapsed | filter_values: %{language: ["fa"]}}

      # The list query applies the filter itself; this is the rows it would keep, collapsed.
      assert listed_where(state, key, language: ["fa"]) == [{site.id, "fa"}]
    end

    test "filtered by two languages, still one row for the word", %{site: site, key: key} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "fr"], site_id: site.id)
      :ok = Translations.register(site.id, [key])
      state = %{@collapsed | filter_values: %{language: ["fa", "fr"]}}

      assert listed_where(state, key, language: ["fa", "fr"]) == [{site.id, "fa"}]
    end

    # Searching a Persian word finds its FA row; its English row does not match, so it is not the
    # one standing for the word.
    test "searching by a translation keeps the row that matched", %{site: site, key: key} do
      write!(row!(site.id, key, "fa"), "جستجو")
      state = %{@collapsed | filter_values: %{search: "جستجو"}}

      assert listed_where(state, key, search: "جستجو") == [{site.id, "fa"}]
    end

    test "searching by the key keeps one row, not one per language", %{site: site, key: key} do
      state = %{@collapsed | filter_values: %{search: "Collapsed"}}

      assert listed_where(state, key, search: "Collapsed") == [{site.id, "en"}]
    end

    # THE TABLE SEARCHES WITHOUT CASE, SO THE COLLAPSE MUST TOO. Matched with case, the English row
    # would not count as a match for "collapsed", and the Persian row would stand beside it.
    test "a search in another case still keeps one row", %{site: site, key: key} do
      state = %{@collapsed | filter_values: %{search: "  collapsed  "}}

      assert listed_where(state, key, search: "collapsed") == [{site.id, "en"}]
    end

    # A `%` is that character. Read as a wildcard it would make the English row match too, and the
    # Persian row — the only one that holds a `%` — would be hidden behind a row the search dropped.
    test "a % in the search is matched as itself", %{site: site, key: key} do
      write!(row!(site.id, key, "fa"), "۵۰%")
      state = %{@collapsed | filter_values: %{search: "%"}}

      assert listed_where(state, key, search: "%") == [{site.id, "fa"}]
    end
  end

  # What the list reads with a filter set: the filter's own narrowing, then the collapse.
  defp listed_where(state, key, narrowing) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key == ^key)
    |> then(fn query ->
      Enum.reduce(narrowing, query, fn
        {:language, languages}, q -> Ash.Query.filter(q, language in ^languages)
        {:search, term}, q -> Text.build_query(q, :search, term, %{fields: [:key, :value]})
      end)
    end)
    |> Translations.one_row_per_key(state)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(&{&1.site_id, &1.language})
    |> Enum.sort()
  end

  describe "language_states/1 — a word's chips" do
    test "every language the site publishes, in its order, translated or missing" do
      site = site_in!(["fa", "en"])
      key = unique("Chips")
      :ok = Translations.register(site.id, [key])
      write!(row!(site.id, key, "fa"), "واژه")

      assert [[%{language: "fa", translated?: true}, %{language: "en", translated?: false}]] =
               Translations.language_states([row!(site.id, key, "en")])
    end

    # The site gained a language after the word was registered: no row, and exactly the chip that
    # says so.
    test "a language the site publishes with no row yet is a missing chip" do
      site = site_in!(["en"])
      key = unique("Gained")
      :ok = Translations.register(site.id, [key])
      {:ok, _} = Settings.put("site.languages", ["en", "de"], site_id: site.id)

      assert [[%{language: "en"}, %{language: "de", translated?: false}]] =
               Translations.language_states([row!(site.id, key, "en")])
    end

    test "a language it has a row in but the site dropped still shows, after the rest" do
      site = site_in!(["en", "fa"])
      key = unique("Dropped")
      :ok = Translations.register(site.id, [key])
      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)

      assert [[%{language: "en"}, %{language: "fa"}]] =
               Translations.language_states([row!(site.id, key, "en")])
    end

    test "another site's rows of the same word are not this word's chips" do
      [site, other] = [site_in!(["en"]), site_in!(["en", "fa"])]
      key = unique("Shared text")
      :ok = Translations.register(site.id, [key])
      :ok = Translations.register(other.id, [key])
      write!(row!(other.id, key, "en"), "Other's")

      assert [[%{language: "en", translated?: false}]] =
               Translations.language_states([row!(site.id, key, "en")])
    end

    test "is nothing for no records", do: assert(Translations.language_states([]) == [])
  end

  describe "group/2 — a word in every language, for the modal" do
    setup do
      site = site_in!(["fa", "en"])
      other = site_in!(["en"])

      %{
        site: site,
        other: other,
        master: create_user_with_permissions!(["admin:dashboard:*"]),
        site_admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      }
    end

    test "every language, in the site's order", %{master: master, site: site} do
      key = unique("Group")
      :ok = Translations.register(site.id, [key])
      write!(row!(site.id, key, "en"), "Group")

      assert {:ok, %{key: ^key, site_id: site_id, rows: rows}} =
               Translations.group(master, row!(site.id, key, "en").id)

      assert site_id == site.id
      assert Enum.map(rows, &{&1.language, &1.value}) == [{"fa", nil}, {"en", "Group"}]
    end

    test "registers a language the site gained, so the modal can offer it", %{
      master: master,
      site: site
    } do
      key = unique("Gained")
      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
      :ok = Translations.register(site.id, [key])
      {:ok, _} = Settings.put("site.languages", ["en", "de"], site_id: site.id)

      {:ok, %{rows: rows}} = Translations.group(master, row!(site.id, key, "en").id)

      assert Enum.map(rows, & &1.language) == ["en", "de"]
    end

    test "a site admin cannot open another site's word", %{site_admin: site_admin, other: other} do
      key = unique("Theirs")
      :ok = Translations.register(other.id, [key])

      assert Translations.group(site_admin, row!(other.id, key, "en").id) == {:error, :not_found}
    end

    # A GLOBAL ROW IS A MASTER'S TO MINT. A site admin may read a global word, and opening it must not
    # register a language the global list lacks on their behalf.
    test "a site admin opening a global word registers nothing", %{site_admin: site_admin} do
      key = unique("Global")
      [first | _] = Translations.languages(nil)
      :ok = Translations.register(nil, [key])
      write!(row!(nil, key, first), "shared")
      before = shape(rows([key]))

      assert {:ok, %{site_id: nil}} = Translations.group(site_admin, row!(nil, key, first).id)
      assert shape(rows([key])) == before
    end

    test "an id that is not a row is not found", %{master: master} do
      assert Translations.group(master, Ash.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "delete_key/2 — a word in every language" do
    setup do
      site = site_in!(["en", "fa"])
      other = site_in!(["en"])

      %{
        site: site,
        other: other,
        master: create_user_with_permissions!(["admin:dashboard:*"]),
        site_admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      }
    end

    test "deletes every language and the cache forgets them", %{master: master, site: site} do
      key = unique("Gone")
      :ok = Translations.register(site.id, [key])
      write!(row!(site.id, key, "fa"), "رفته")

      assert Translations.delete_key(master, row!(site.id, key, "en").id) == {:ok, 2}
      assert rows([key]) == []

      _handled = :sys.get_state(TranslationsState)
      assert TranslationsState.lookup(site.id, "fa", key) == nil
    end

    test "leaves the same word on another site alone", %{master: master, site: site, other: other} do
      key = unique("Two sites")
      :ok = Translations.register(site.id, [key])
      :ok = Translations.register(other.id, [key])

      {:ok, 2} = Translations.delete_key(master, row!(site.id, key, "en").id)

      assert shape(rows([key])) == [{other.id, key, "en", nil}]
    end

    test "a site admin cannot reach another site's word", %{site_admin: site_admin, other: other} do
      key = unique("Theirs")
      :ok = Translations.register(other.id, [key])

      assert Translations.delete_key(site_admin, row!(other.id, key, "en").id) ==
               {:error, :not_found}

      assert [_] = rows([key])
    end

    # They may read a global word, and the destroy policy still refuses each row of it.
    test "a site admin deletes none of a global word", %{site_admin: site_admin} do
      key = unique("Global")
      [first | _] = Translations.languages(nil)
      :ok = Translations.register(nil, [key])
      before = shape(rows([key]))

      assert Translations.delete_key(site_admin, row!(nil, key, first).id) == {:ok, 0}
      assert shape(rows([key])) == before
    end
  end

  describe "component_words/1 — the words of the components a template renders" do
    setup do
      %{site: published_site!(["en"]), n: System.unique_integer([:positive])}
    end

    test "a site component's words, under its site", %{site: site, n: n} do
      create_component!(site_id: site.id, name: "a-#{n}", template: template(["A #{n}"]))

      assert Translations.component_words([{"a-#{n}", site.name}]) == %{site.id => ["A #{n}"]}
    end

    test "Global, or no site at all, names a global component", %{n: n} do
      create_component!(site_id: nil, name: "g-#{n}", template: template(["G #{n}"]))

      for site <- ["Global", nil],
          do: assert(Translations.component_words([{"g-#{n}", site}]) == %{nil => ["G #{n}"]})
    end

    test "follows nested components, each word under its own component's site", %{
      site: site,
      n: n
    } do
      create_component!(site_id: nil, name: "inner-#{n}", template: template(["Inner #{n}"]))

      create_component!(
        site_id: site.id,
        name: "outer-#{n}",
        template:
          ~s|<div>{t("Outer #{n}")}<.component component_name="inner-#{n}" site="Global" /></div>|
      )

      assert Translations.component_words([{"outer-#{n}", site.name}]) ==
               %{site.id => ["Outer #{n}"], nil => ["Inner #{n}"]}
    end

    test "a cycle ends", %{site: site, n: n} do
      create_component!(
        site_id: site.id,
        name: "ping-#{n}",
        template:
          ~s|<p>{t("Ping #{n}")}<.component component_name="pong-#{n}" site="#{site.name}" /></p>|
      )

      create_component!(
        site_id: site.id,
        name: "pong-#{n}",
        template:
          ~s|<p>{t("Pong #{n}")}<.component component_name="ping-#{n}" site="#{site.name}" /></p>|
      )

      assert %{} = words = Translations.component_words([{"ping-#{n}", site.name}])
      assert Enum.sort(words[site.id]) == Enum.sort(["Ping #{n}", "Pong #{n}"])
    end

    test "an inactive component, an unknown site and a name given as an expression give nothing",
         %{
           site: site,
           n: n
         } do
      create_component!(
        site_id: site.id,
        name: "off-#{n}",
        active: false,
        template: template(["Off #{n}"])
      )

      assert Translations.component_words([{"off-#{n}", site.name}]) == %{}
      assert Translations.component_words([{"off-#{n}", "no-such-site"}]) == %{}

      create_component!(
        site_id: site.id,
        name: "dyn-#{n}",
        template: ~s|<div><.component component_name={@name} site="Global" /></div>|
      )

      assert Translations.component_words([{"dyn-#{n}", site.name}]) == %{}
    end
  end

  describe "add_language/4 — a word in one more language" do
    setup do
      site = site_in!(["en", "fa"])
      other = site_in!(["en"])
      forget_settings(~w(site.allowed_languages site.languages), [nil])
      key = unique("Grow")
      :ok = Translations.register(site.id, [key])

      %{
        site: site,
        other: other,
        key: key,
        master: create_user_with_permissions!(["admin:dashboard:*"]),
        site_admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      }
    end

    defp langs(key, site_id),
      do:
        [key]
        |> rows()
        |> Enum.filter(&(&1.site_id == site_id))
        |> Enum.map(& &1.language)
        |> Enum.sort()

    test "a master publishes it on the word's site, then registers it", %{
      master: master,
      site: site,
      key: key
    } do
      assert Translations.add_language(master, site.id, key, " FR ") == :ok

      assert Settings.get("site.languages", nil, site.id) == ["en", "fa", "fr"]
      assert langs(key, site.id) == ["en", "fa", "fr"]
    end

    test "a site admin, on their own site", %{site_admin: site_admin, site: site, key: key} do
      assert Translations.add_language(site_admin, site.id, key, "de") == :ok
      assert "de" in langs(key, site.id)
    end

    test "no user adds nothing anywhere", %{site: site, key: key} do
      assert Translations.add_language(nil, site.id, key, "de") == {:error, :forbidden}
      refute "de" in langs(key, site.id)
    end

    test "a site admin, never on another site or a global word", %{
      site_admin: site_admin,
      other: other
    } do
      other_key = unique("Theirs")
      :ok = Translations.register(other.id, [other_key])

      assert Translations.add_language(site_admin, other.id, other_key, "de") ==
               {:error, :forbidden}

      assert Translations.add_language(site_admin, nil, unique("Global"), "de") ==
               {:error, :forbidden}

      assert Settings.get("site.languages", nil, other.id) == ["en"]
    end

    test "a language the site already publishes is only registered", %{
      master: master,
      site: site,
      key: key
    } do
      :ok = Translations.delete_key(master, row!(site.id, key, "fa").id) |> elem(0)
      :ok = Translations.register(site.id, [key])

      assert Translations.add_language(master, site.id, key, "fa") == :ok
      assert Settings.get("site.languages", nil, site.id) == ["en", "fa"]
    end

    test "outside the master's allowed languages is refused", %{
      master: master,
      site: site,
      key: key
    } do
      {:ok, _} = Settings.put("site.allowed_languages", ["en", "fa", "de"])

      assert Translations.add_language(master, site.id, key, "fr") == {:error, :not_allowed}
      assert Translations.add_language(master, site.id, key, "de") == :ok
    end

    test "what is not a language code is refused", %{master: master, site: site, key: key} do
      assert Translations.add_language(master, site.id, key, "French") == {:error, :invalid}
      assert Settings.get("site.languages", nil, site.id) == ["en", "fa"]
    end

    test "addable_languages/1 offers the allowed ones, else every site's, less what the word has" do
      published_site!(["en", "fa", "tr"])
      assert "tr" in Translations.addable_languages(["en", "fa"])
      refute "en" in Translations.addable_languages(["en", "fa"])

      {:ok, _} = Settings.put("site.allowed_languages", ["en", "fa", "de"])
      assert Translations.addable_languages(["en"]) == ["fa", "de"]
    end
  end

  describe "language_options_for/1 — what the Add form's Language field offers" do
    test "a master: nothing until a site is picked, the site's for a site, every site's for Global" do
      site = site_in!(["en", "fa"])

      assert Translations.language_options_for(%{master_user?: true, field_values: %{}}) == []

      assert Translations.language_options_for(%{
               master_user?: true,
               field_values: %{site_id: site.id}
             }) ==
               [{"EN", "en"}, {"FA", "fa"}]

      assert Translations.language_options_for(%{
               master_user?: true,
               field_values: %{site_id: "__nil__"}
             }) ==
               Translations.language_options()
    end

    test "a site admin: their own site's, whatever the field values say" do
      site = site_in!(["fa", "en"])
      other = site_in!(["de"])

      state = %{
        master_user?: false,
        current_user: %{site_id: site.id},
        field_values: %{site_id: other.id}
      }

      assert Translations.language_options_for(state) == [{"FA", "fa"}, {"EN", "en"}]
    end
  end

  test "may_write?/2 — a master anywhere, a site admin on their own site only" do
    site = create_site!()
    translator = [%MishkaCmsCore.Accounts.Permission{name: "admin:dashboard:runtime:translation"}]
    master = %{site_id: nil, permissions: translator}
    site_admin = %{site_id: site.id, permissions: translator}

    assert Translations.may_write?(master, nil)
    assert Translations.may_write?(master, site.id)
    assert Translations.may_write?(site_admin, site.id)
    refute Translations.may_write?(site_admin, nil)
    refute Translations.may_write?(site_admin, Ash.UUID.generate())
  end

  describe "published_language/2" do
    test "admits a language the row's site publishes in, and refuses any other" do
      site = site_in!(["en", "fa"])

      in_language = fn language ->
        Ash.Changeset.for_create(
          Translation,
          :master_create,
          %{key: unique("Key"), language: language, site_id: site.id},
          authorize?: false
        )
      end

      assert in_language.("fa").valid?
      refute in_language.("de").valid?
    end

    test "admits a global row in a language any site publishes in, and refuses one none does" do
      published_site!(["en", "ku"])

      global_in = fn language ->
        Ash.Changeset.for_create(
          Translation,
          :master_create,
          %{key: unique("Key"), language: language, site_id: nil},
          authorize?: false
        )
      end

      assert global_in.("ku").valid?
      refute global_in.("zu").valid?
    end
  end

  # A LANGUAGE NOBODY HAS TRANSLATED INTO YET IS THE ONE AN ADMIN IS LOOKING FOR. It has no cached
  # value to be found by, so the picker learns it from the site that publishes in it — the admin's
  # Language filter used to offer EN alone on a site whose Persian rows were all still empty.
  test "language_options/0 offers every language a site publishes in, translated or not" do
    published_site!(["en", "fa", "ku"])

    options = Translations.language_options()

    assert {"KU", "ku"} in options
    assert {"FA", "fa"} in options

    for language <- Languages.site(nil),
        do: assert({String.upcase(language), language} in options)

    assert options == options |> Enum.uniq() |> Enum.sort_by(&elem(&1, 1))
  end

  # The inverse: a cached value in a language no site publishes in would be offered, then refused by
  # `published_language/2` on save.
  test "language_options/0 does not offer a language no site publishes in" do
    cache!(nil, "zu", unique("Option"), "value")

    refute {"ZU", "zu"} in Translations.language_options()
  end
end
