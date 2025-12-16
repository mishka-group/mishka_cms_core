defmodule MishkaCmsCore.Runtime.States.TranslationsStateTest do
  @moduledoc """
  The ETS copy of `MishkaCmsCore.Runtime.Translation` that every `t/1` is answered from.

  What it answers — a site's own word, else the global one, else nothing — and how it stays equal to
  the table: reloaded whole by `refresh/0`, and kept current between reloads off the resource's own
  broadcasts, with no query of its own. A cache that drifts shows a visitor a word an admin deleted,
  or hides one they just wrote, so every write path is checked to land here: a save, an emptied
  value, a delete.

  The cache is process-global, not sandboxed. Each test writes under keys no other test uses, and
  the setup drops every entry those keys could have left behind.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Languages, Translation, Translations}
  alias MishkaCmsCore.Runtime.States.TranslationsState
  alias MishkaCmsCore.Settings

  require Ash.Query

  @moduletag :integration

  @persian "دسته\u200Cبندی\u200Cها"

  setup do
    n = System.unique_integer([:positive])
    site = create_site!()
    other_site = create_site!()

    # A language no other test and no real site writes in (`qaa`–`qtz` is ISO 639's private-use
    # range), so what `languages/0` says about it can only have come from this test.
    private = "qaa-t#{rem(n, 10_000_000)}"

    # A global row may only be written in a language the global list publishes in, which this suite
    # reads rather than sets: the global `site.languages` is shared by every suite that runs after it.
    global = hd(Languages.site(nil))

    # A language only the sites publish in, so a site's row never shares one with the global row a
    # test did not mean it to shadow.
    local = hd(~w(fa ar) -- [global])
    languages = [global, local, private]

    forget_settings(~w(site.languages), [site.id, other_site.id])
    {:ok, _} = Settings.put("site.languages", languages, site_id: site.id)
    {:ok, _} = Settings.put("site.languages", languages, site_id: other_site.id)

    key = "translations-state-#{n} Categories"
    other_key = "translations-state-#{n} Tags"

    on_exit(fn ->
      for site_id <- [nil, site.id, other_site.id],
          language <- languages,
          entry <- [key, other_key] do
        TranslationsState.put(site_id, language, entry, nil)
      end
    end)

    %{
      site: site,
      other_site: other_site,
      global: global,
      local: local,
      private: private,
      key: key,
      other_key: other_key,
      master: create_user_with_permissions!(["admin:dashboard:*"]),
      tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
    }
  end

  # `:sys.get_state/1` is a call, so it returns only once the process has handled every message that
  # reached its mailbox before it — the broadcast of any write that has already returned included.
  defp await_cache, do: _ = :sys.get_state(TranslationsState)

  defp row!(site_id, language, key) do
    Translation
    |> Ash.Query.filter(key == ^key and language == ^language)
    |> then(
      &if is_nil(site_id),
        do: Ash.Query.filter(&1, is_nil(site_id)),
        else: Ash.Query.filter(&1, site_id == ^site_id)
    )
    |> Ash.read_one!(action: :read_any, authorize?: false)
  end

  # A translation that reaches the table WITHOUT a broadcast — written on another node before this
  # one booted, or by hand. Only `refresh/0` can bring it into the cache. `register/2` sends none of
  # its own, and the update's are handed back here instead of sent.
  defp write_silently!(site_id, language, key, value) do
    :ok = Translations.register(site_id, [key])

    {:ok, record, _held_back} =
      row!(site_id, language, key)
      |> Ash.Changeset.for_update(:master_update, %{value: value}, authorize?: false)
      |> Ash.update(authorize?: false, return_notifications?: true)

    record
  end

  # How a global row comes to be when a global template is saved and then translated in the admin.
  # Not `:master_create`: that is the case under test in "a global translation created with a value
  # reaches every site at once", and a cache test whose subject is a destroy or an emptied value
  # should not fail on how its global row was made.
  defp global!(master, language, key, value) do
    :ok = Translations.register(nil, [key])
    master_update!(master, row!(nil, language, key), value)
  end

  defp master_create!(master, attrs) do
    Translation
    |> Ash.Changeset.for_create(:master_create, attrs, actor: master, tenant: nil)
    |> Ash.create!()
  end

  defp master_update!(master, row, value) do
    row
    |> Ash.Changeset.for_update(:master_update, %{value: value}, actor: master, tenant: nil)
    |> Ash.update!()
  end

  describe "lookup/3 — the order t/1 reads in" do
    test "answers a site's own translation", %{site: site, local: local, key: key} do
      :ok = TranslationsState.put(site.id, local, key, @persian)

      assert TranslationsState.lookup(site.id, local, key) == @persian
    end

    test "falls back to the global translation when the site has none", %{
      site: site,
      other_site: other_site,
      local: local,
      key: key
    } do
      :ok = TranslationsState.put(nil, local, key, "global")

      assert TranslationsState.lookup(site.id, local, key) == "global"
      assert TranslationsState.lookup(other_site.id, local, key) == "global"
      assert TranslationsState.lookup(nil, local, key) == "global"
    end

    test "prefers the site's own translation over the global one, for that site alone", %{
      site: site,
      other_site: other_site,
      local: local,
      key: key
    } do
      :ok = TranslationsState.put(nil, local, key, "global")
      :ok = TranslationsState.put(site.id, local, key, "site")

      assert TranslationsState.lookup(site.id, local, key) == "site"
      assert TranslationsState.lookup(other_site.id, local, key) == "global"
      assert TranslationsState.lookup(nil, local, key) == "global"
    end

    # A site's words are its own. Another site reading them would show one tenant's copy on
    # another tenant's pages.
    test "never answers one site with another site's translation", %{
      site: site,
      other_site: other_site,
      local: local,
      key: key
    } do
      :ok = TranslationsState.put(site.id, local, key, "site")

      assert TranslationsState.lookup(other_site.id, local, key) == nil
      assert TranslationsState.lookup(nil, local, key) == nil
    end

    test "is nil when neither the site nor the global row has one", %{
      site: site,
      local: local,
      key: key
    } do
      assert TranslationsState.lookup(site.id, local, key) == nil
      assert TranslationsState.lookup(nil, local, key) == nil
    end

    test "never answers in a language it was not asked for", %{
      site: site,
      private: private,
      local: local,
      key: key
    } do
      :ok = TranslationsState.put(nil, local, key, "global")
      :ok = TranslationsState.put(site.id, local, key, "site")

      assert TranslationsState.lookup(site.id, private, key) == nil
    end

    # The key is the literal inside `t("…")` and is stored untrimmed, so the cache must not be any
    # looser than the table about what counts as the same key.
    test "matches the key byte for byte", %{site: site, local: local, key: key} do
      :ok = TranslationsState.put(site.id, local, key, "site")

      assert TranslationsState.lookup(site.id, local, String.downcase(key)) == nil
      assert TranslationsState.lookup(site.id, local, key <> " ") == nil
      assert TranslationsState.lookup(site.id, local, " " <> key) == nil
    end
  end

  describe "put/4" do
    test "with nil removes the entry", %{site: site, local: local, key: key} do
      :ok = TranslationsState.put(site.id, local, key, "site")
      :ok = TranslationsState.put(site.id, local, key, nil)

      assert TranslationsState.lookup(site.id, local, key) == nil
    end

    test "with an empty string removes the entry", %{site: site, local: local, key: key} do
      :ok = TranslationsState.put(site.id, local, key, "site")
      :ok = TranslationsState.put(site.id, local, key, "")

      assert TranslationsState.lookup(site.id, local, key) == nil
    end

    # Removing is not the same as storing blank: an entry holding "" would render an empty string
    # where the global word, or the key itself, belongs.
    test "removing a site's entry lets the global translation show through again", %{
      site: site,
      local: local,
      key: key
    } do
      :ok = TranslationsState.put(nil, local, key, "global")
      :ok = TranslationsState.put(site.id, local, key, "site")
      :ok = TranslationsState.put(site.id, local, key, "")

      assert TranslationsState.lookup(site.id, local, key) == "global"
    end

    test "replaces what the entry held", %{site: site, local: local, key: key} do
      :ok = TranslationsState.put(site.id, local, key, "first")
      :ok = TranslationsState.put(site.id, local, key, "second")

      assert TranslationsState.lookup(site.id, local, key) == "second"
    end
  end

  describe "refresh/0 — reloading from the database" do
    test "loads the translations the table holds", %{
      site: site,
      global: global,
      local: local,
      key: key
    } do
      write_silently!(nil, global, key, "global")
      write_silently!(site.id, local, key, @persian)

      await_cache()
      assert TranslationsState.lookup(nil, global, key) == nil
      assert TranslationsState.lookup(site.id, local, key) == nil

      :ok = TranslationsState.refresh()

      assert TranslationsState.lookup(nil, global, key) == "global"
      assert TranslationsState.lookup(site.id, global, key) == "global"
      assert TranslationsState.lookup(site.id, local, key) == @persian
    end

    test "drops what the table no longer holds", %{site: site, local: local, key: key} do
      :ok = TranslationsState.put(site.id, local, key, "stale")

      :ok = TranslationsState.refresh()

      assert TranslationsState.lookup(site.id, local, key) == nil
    end

    # `Translations.register/2` is how a saved template creates its rows — one per language, every
    # value nil. Were those cached, the site's untranslated entry would answer before the global
    # translation and render the key over a word somebody wrote.
    test "leaves untranslated rows out, so they never hide the global translation", %{
      site: site,
      global: global,
      private: private,
      key: key
    } do
      write_silently!(nil, global, key, "global")
      :ok = Translations.register(site.id, [key])

      assert %{value: nil} = row!(site.id, global, key)
      assert %{value: nil} = row!(site.id, private, key)

      :ok = TranslationsState.refresh()

      assert TranslationsState.lookup(site.id, global, key) == "global"
      assert TranslationsState.lookup(site.id, private, key) == nil
      refute private in TranslationsState.languages()
    end
  end

  describe "kept current off PubSub" do
    # The value is the one thing here that is not ASCII, and U+200C in it is part of the Persian
    # spelling: the cache must hand `t/1` exactly the bytes the admin saved.
    test "a translation saved through Ash reaches the cache, byte for byte", %{
      site: site,
      master: master,
      local: local,
      key: key
    } do
      :ok = Translations.register(site.id, [key])
      await_cache()
      assert TranslationsState.lookup(site.id, local, key) == nil

      master_update!(master, row!(site.id, local, key), @persian)
      await_cache()

      assert TranslationsState.lookup(site.id, local, key) == @persian
      assert length(String.split(TranslationsState.lookup(site.id, local, key), "\u200C")) == 3
    end

    test "a saved site translation is cached under that site and no other", %{
      site: site,
      other_site: other_site,
      master: master,
      local: local,
      key: key
    } do
      :ok = Translations.register(site.id, [key])

      master_update!(master, row!(site.id, local, key), "site")
      await_cache()

      assert TranslationsState.lookup(site.id, local, key) == "site"
      assert TranslationsState.lookup(other_site.id, local, key) == nil
      assert TranslationsState.lookup(nil, local, key) == nil
    end

    test "a site admin's own write reaches the cache under their site", %{
      site: site,
      tenant: tenant,
      local: local,
      key: key
    } do
      :ok = Translations.register(site.id, [key])

      row!(site.id, local, key)
      |> Ash.Changeset.for_update(:update, %{value: "tenant"}, actor: tenant, tenant: site.id)
      |> Ash.update!()

      await_cache()

      assert TranslationsState.lookup(site.id, local, key) == "tenant"
      assert TranslationsState.lookup(nil, local, key) == nil
    end

    # `:create` takes no `site_id` — it stamps the tenant's — so the row the broadcast carries is the
    # only place the cache can learn whose translation this is.
    test "a site admin's new translation is cached under their site", %{
      site: site,
      tenant: tenant,
      local: local,
      key: key
    } do
      Translation
      |> Ash.Changeset.for_create(:create, %{key: key, language: local, value: "tenant"},
        actor: tenant,
        tenant: site.id
      )
      |> Ash.create!()

      await_cache()

      assert TranslationsState.lookup(site.id, local, key) == "tenant"
      assert TranslationsState.lookup(nil, local, key) == nil
    end

    test "a global translation created with a value reaches every site at once", %{
      site: site,
      other_site: other_site,
      master: master,
      global: global,
      key: key
    } do
      master_create!(master, %{key: key, language: global, value: "global", site_id: nil})
      await_cache()

      assert TranslationsState.lookup(nil, global, key) == "global"
      assert TranslationsState.lookup(site.id, global, key) == "global"
      assert TranslationsState.lookup(other_site.id, global, key) == "global"
    end

    test "an untranslated row saved through Ash does not hide the global translation", %{
      site: site,
      master: master,
      global: global,
      key: key
    } do
      global!(master, global, key, "global")
      master_create!(master, %{key: key, language: global, value: nil, site_id: site.id})
      await_cache()

      assert TranslationsState.lookup(site.id, global, key) == "global"
    end

    # Clearing the textarea in the admin means "show the key again". A stale entry left behind
    # would keep rendering the old word after the admin removed it.
    test "an emptied translation leaves the cache", %{
      site: site,
      master: master,
      local: local,
      key: key
    } do
      :ok = Translations.register(site.id, [key])
      row = master_update!(master, row!(site.id, local, key), "site")
      await_cache()
      assert TranslationsState.lookup(site.id, local, key) == "site"

      master_update!(master, row, "")
      await_cache()

      assert TranslationsState.lookup(site.id, local, key) == nil
    end

    test "an emptied site translation lets the global one show through again", %{
      site: site,
      master: master,
      global: global,
      key: key
    } do
      global!(master, global, key, "global")
      row = master_create!(master, %{key: key, language: global, value: "site", site_id: site.id})
      await_cache()
      assert TranslationsState.lookup(site.id, global, key) == "site"

      master_update!(master, row, nil)
      await_cache()

      assert TranslationsState.lookup(site.id, global, key) == "global"
    end

    test "a destroyed translation leaves the cache", %{
      site: site,
      master: master,
      global: global,
      key: key,
      other_key: other_key
    } do
      global!(master, global, key, "global")

      site_row =
        master_create!(master, %{key: key, language: global, value: "site", site_id: site.id})

      master_create!(master, %{key: other_key, language: global, value: "kept", site_id: site.id})
      await_cache()
      assert TranslationsState.lookup(site.id, global, key) == "site"

      Ash.destroy!(site_row, action: :master_destroy, actor: master, tenant: nil)
      await_cache()

      assert TranslationsState.lookup(site.id, global, key) == "global"
      assert TranslationsState.lookup(site.id, global, other_key) == "kept"
    end

    test "a destroyed global translation leaves every site", %{
      site: site,
      master: master,
      global: global,
      key: key
    } do
      row = global!(master, global, key, "global")
      await_cache()
      assert TranslationsState.lookup(site.id, global, key) == "global"

      Ash.destroy!(row, action: :master_destroy, actor: master, tenant: nil)
      await_cache()

      assert TranslationsState.lookup(nil, global, key) == nil
      assert TranslationsState.lookup(site.id, global, key) == nil
    end
  end

  describe "languages/0" do
    test "lists every language a cached translation is written in, each once", %{
      site: site,
      private: private,
      key: key,
      other_key: other_key
    } do
      refute private in TranslationsState.languages()

      :ok = TranslationsState.put(nil, private, key, "global")
      :ok = TranslationsState.put(site.id, private, key, "site")
      :ok = TranslationsState.put(site.id, private, other_key, "other")

      assert Enum.count(TranslationsState.languages(), &(&1 == private)) == 1
    end

    test "forgets a language once its last translation leaves", %{
      site: site,
      private: private,
      key: key
    } do
      :ok = TranslationsState.put(nil, private, key, "global")
      :ok = TranslationsState.put(site.id, private, key, "site")

      :ok = TranslationsState.put(nil, private, key, nil)
      assert private in TranslationsState.languages()

      :ok = TranslationsState.put(site.id, private, key, "")
      refute private in TranslationsState.languages()
    end
  end
end
