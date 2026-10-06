defmodule MishkaCmsCore.Runtime.Resources.TranslationTest do
  @moduledoc """
  The translation table, and above all who may read and write which of its rows.

  A row is one `{site, key, language}`, and a site admin's own words sit in the same table as every
  other site's. What keeps them apart is the ACTOR, never the tenant a caller passes: a tenant is a
  claim anybody can make, so every read and write here is tried with somebody else's site named as
  the tenant as well as with the admin's own.

  Beside that: the one-row-per-`{site, key, language}` identity, the refusal of a language a site
  does not publish in, what a save does to the text — a Persian value keeps the zero-width
  non-joiner it is spelled with, and a key is stored exactly as the template wrote it — and the
  `:used` calculation the admin's Used column reads.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Languages, Translation, Translations}
  alias MishkaCmsCore.Runtime.States.TranslationsState
  alias MishkaCmsCore.Settings

  require Ash.Query

  @moduletag :integration

  @admin ["admin:dashboard:*"]

  @zwnj "\u200C"

  # دسته‌بندی‌ها, built from its parts so the two U+200C it is spelled with are visible in the source.
  @categories "دسته" <> @zwnj <> "بندی" <> @zwnj <> "ها"

  setup do
    site = create_site!()
    other = create_site!()
    forget_settings(~w(site.languages), [site.id, other.id])

    for id <- [site.id, other.id] do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: id)
    end

    # The global rows publish in whatever the global list says; the first of it is always there.
    [global_language | _] = Languages.site(nil)

    %{
      site: site,
      other: other,
      global_language: global_language,
      n: System.unique_integer([:positive])
    }
  end

  # A FIXTURE ROW COMES TO EXIST THE WAY A REAL ONE DOES: a saved template registers the key, and
  # somebody writes the word. Tests about `:create` and `:master_create` call those directly.
  defp row!(attrs) do
    attrs = Map.new(attrs)

    Translation
    |> Ash.create!(Map.take(attrs, [:key, :language, :site_id]),
      action: :register,
      authorize?: false
    )
    |> write_value(attrs[:value])
    |> forget_cached()
  end

  defp write_value(row, nil), do: row

  defp write_value(row, value),
    do: Ash.update!(row, %{value: value}, action: :master_update, authorize?: false)

  defp master_create(attrs) do
    Translation
    |> Ash.create(Map.new(attrs), action: :master_create, authorize?: false)
    |> tap(fn
      {:ok, row} -> forget_cached(row)
      _refused -> :ok
    end)
  end

  # A ROW WITH A VALUE OUTLIVES THE ROLLBACK. It reaches `TranslationsState` through the resource's
  # own broadcast, and the ETS table is not sandboxed, so each one is taken back out when the test
  # ends — a global word left cached would render in every later suite.
  defp forget_cached(%Translation{} = row) do
    on_exit(fn -> TranslationsState.put(row.site_id, row.language, row.key, nil) end)
    row
  end

  defp stored(%Translation{id: id}) do
    Ash.get!(Translation, id, action: :read_any, authorize?: false)
  end

  defp rows_named(keys) do
    keys = List.wrap(keys)

    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key in ^keys)
    |> Ash.read!(page: false)
  end

  defp read(action, actor, tenant, keys) do
    Translation
    |> Ash.Query.for_read(action, %{}, actor: actor, tenant: tenant, authorize?: true)
    |> Ash.Query.filter(key in ^keys)
    |> Ash.read(page: false)
  end

  defp keys_read(action, actor, tenant, keys) do
    {:ok, rows} = read(action, actor, tenant, keys)
    rows |> Enum.map(& &1.key) |> Enum.sort()
  end

  defp used(keys) do
    keys
    |> List.wrap()
    |> rows_named()
    |> Ash.load!(:used, authorize?: false)
    |> Enum.map(&{&1.site_id, &1.language, &1.used})
    |> Enum.sort()
  end

  describe "the identity — one row per key, language and site" do
    test "refuses the same key in the same language on the same site twice", %{site: site, n: n} do
      assert {:ok, _row} = master_create(key: "Save #{n}", language: "en", site_id: site.id)

      assert {:error, %Ash.Error.Invalid{}} =
               master_create(key: "Save #{n}", language: "en", site_id: site.id)
    end

    test "lets two sites each hold the same key in the same language", %{
      site: site,
      other: other,
      n: n
    } do
      assert {:ok, _mine} = master_create(key: "Save #{n}", language: "en", site_id: site.id)
      assert {:ok, _theirs} = master_create(key: "Save #{n}", language: "en", site_id: other.id)
    end

    test "lets one site hold the same key in each language it publishes in", %{site: site, n: n} do
      assert {:ok, _english} = master_create(key: "Save #{n}", language: "en", site_id: site.id)
      assert {:ok, _persian} = master_create(key: "Save #{n}", language: "fa", site_id: site.id)
    end

    # `nils_distinct?: false`. Postgres treats two NULLs as different by default, which would let the
    # global rows — site_id NULL — hold one key twice, and `t/1` would answer from whichever it read.
    test "refuses the same global key in the same language twice", %{
      global_language: language,
      n: n
    } do
      row!(key: "Save #{n}", language: language, site_id: nil)

      assert {:error, %Ash.Error.Invalid{}} =
               master_create(key: "Save #{n}", language: language, site_id: nil)
    end

    # The same guarantee from the side that leans on it hardest: every save of a global template
    # registers its keys again, and with NULLs distinct each save would add another row.
    test "registering a global key again finds the row it already has", %{
      global_language: language,
      n: n
    } do
      first = row!(key: "Save #{n}", language: language, site_id: nil)
      again = row!(key: "Save #{n}", language: language, site_id: nil)

      assert again.id == first.id
      assert [%Translation{site_id: nil}] = rows_named("Save #{n}")
    end
  end

  describe "the language a row is written in" do
    test ":create refuses a language the site does not publish in", %{site: site, n: n} do
      admin = create_user_with_permissions!(@admin, site_id: site.id)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(Translation, %{key: "Save #{n}", language: "de"},
                 action: :create,
                 actor: admin,
                 tenant: site.id,
                 authorize?: true
               )

      assert Enum.any?(errors, &(Map.get(&1, :field) == :language))
    end

    test ":master_create refuses one for a site's row", %{site: site, n: n} do
      master = create_user_with_permissions!(@admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(Translation, %{key: "Save #{n}", language: "de", site_id: site.id},
                 action: :master_create,
                 actor: master,
                 authorize?: true
               )

      assert Enum.any?(errors, &(Map.get(&1, :field) == :language))
    end

    # A global row is checked against every site's list, not waved through for having no site.
    test ":master_create refuses one for a global row", %{n: n} do
      unpublished = Enum.find(~w(de ja sw zu), &(&1 not in Translations.languages(nil)))

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               master_create(key: "Save #{n}", language: unpublished, site_id: nil)

      assert Enum.any?(errors, &(Map.get(&1, :field) == :language))
    end

    test ":master_create writes a global row in a language the global list publishes", %{
      global_language: language,
      n: n
    } do
      assert {:ok, %Translation{site_id: nil}} =
               master_create(key: "Save #{n}", language: language, site_id: nil, value: "Save")
    end

    # The list is read at write time, so a site that drops a language stops taking words in it.
    test "follows the site's list when it changes", %{site: site, n: n} do
      assert {:ok, _row} = master_create(key: "Save #{n}", language: "fa", site_id: site.id)

      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)

      assert {:error, %Ash.Error.Invalid{}} =
               master_create(key: "Cancel #{n}", language: "fa", site_id: site.id)
    end
  end

  describe "what a save does to the text" do
    # The reason `no_zero_width` is not on `value`. U+200C is inside its class, and Persian spells
    # with it: stripped, the word would still render — as a different-looking word nobody wrote.
    test "a value keeps every zero-width non-joiner it is spelled with", %{site: site, n: n} do
      assert {:ok, row} =
               master_create(
                 key: "Categories #{n}",
                 language: "fa",
                 site_id: site.id,
                 value: @categories
               )

      assert String.codepoints(row.value) == String.codepoints(@categories)
      assert String.codepoints(stored(row).value) == String.codepoints(@categories)
      assert row.value |> String.codepoints() |> Enum.count(&(&1 == @zwnj)) == 2

      :sys.get_state(TranslationsState)
      assert TranslationsState.lookup(site.id, "fa", row.key) == @categories
    end

    test "a value loses ASCII control characters", %{site: site, n: n} do
      assert {:ok, row} =
               master_create(
                 key: "Save #{n}",
                 language: "en",
                 site_id: site.id,
                 value: "Sa\u0007ve\u0000"
               )

      assert row.value == "Save"
      assert stored(row).value == "Save"
    end

    # `no_control` stops short of these three: a translation of a paragraph has lines.
    test "a value keeps its line breaks and tabs", %{site: site, n: n} do
      value = "Line one\nLine two\r\n\tindented"

      assert {:ok, row} =
               master_create(key: "Intro #{n}", language: "en", site_id: site.id, value: value)

      assert stored(row).value == value
    end

    test "an update is sanitized the same way", %{site: site, n: n} do
      row = row!(key: "Save #{n}", language: "fa", site_id: site.id, value: "old")

      updated =
        Ash.update!(row, %{value: "\u0007" <> @categories},
          action: :master_update,
          authorize?: false
        )

      assert String.codepoints(updated.value) == String.codepoints(@categories)
    end

    # The key is matched byte for byte against the literal inside `t("…")`. A key trimmed on save
    # would never be asked for again, and its template would show the untranslated text forever.
    test "the key is stored byte for byte, surrounding spaces included", %{site: site, n: n} do
      key = "  Read more #{n} "

      assert {:ok, row} = master_create(key: key, language: "en", site_id: site.id)

      assert row.key == key
      assert stored(row).key == key
    end

    test "the key keeps a zero-width non-joiner as well", %{site: site, n: n} do
      key = "#{@categories} #{n}"

      assert {:ok, row} = master_create(key: key, language: "fa", site_id: site.id)

      assert String.codepoints(stored(row).key) == String.codepoints(key)
    end
  end

  describe "reading" do
    setup %{site: site, other: other, global_language: global_language, n: n} do
      own = row!(key: "Own #{n}", language: "en", site_id: site.id, value: "mine")
      theirs = row!(key: "Theirs #{n}", language: "en", site_id: other.id, value: "private")
      shared = row!(key: "Shared #{n}", language: global_language, site_id: nil, value: "all")

      %{own: own, theirs: theirs, shared: shared, keys: [own.key, theirs.key, shared.key]}
    end

    test "a master reads every site's rows and the global ones", %{keys: keys} do
      master = create_user_with_permissions!(@admin)

      assert keys_read(:master_read, master, nil, keys) == Enum.sort(keys)
    end

    test "a site admin reads their own rows and the global ones", %{
      site: site,
      own: own,
      shared: shared,
      keys: keys
    } do
      admin = create_user_with_permissions!(@admin, site_id: site.id)

      assert keys_read(:tenant_read, admin, site.id, keys) == Enum.sort([own.key, shared.key])
    end

    # `:tenant_read` filters by the tenant it is handed. `TenantContext` refuses a site admin who
    # hands another site's id, before the read policy would have narrowed it to nothing of that site.
    test "a site admin who names another site as the tenant reads none of its rows", %{
      site: site,
      other: other,
      keys: keys
    } do
      admin = create_user_with_permissions!(@admin, site_id: site.id)

      assert {:error, %Ash.Error.Forbidden{} = error} = read(:tenant_read, admin, other.id, keys)
      assert Exception.message(error) =~ "A site user can act only on their own site."
    end

    test "a site admin cannot get another site's row by id, whichever tenant they name", %{
      site: site,
      other: other,
      theirs: theirs
    } do
      admin = create_user_with_permissions!(@admin, site_id: site.id)

      for tenant <- [site.id, other.id] do
        assert {:error, _not_theirs} =
                 Ash.get(Translation, theirs.id,
                   action: :tenant_get,
                   actor: admin,
                   tenant: tenant,
                   authorize?: true
                 )
      end
    end

    test "a site admin gets their own row and a global one by id", %{
      site: site,
      own: own,
      shared: shared
    } do
      admin = create_user_with_permissions!(@admin, site_id: site.id)

      for row <- [own, shared] do
        assert {:ok, %Translation{id: id}} =
                 Ash.get(Translation, row.id,
                   action: :tenant_get,
                   actor: admin,
                   tenant: site.id,
                   authorize?: true
                 )

        assert id == row.id
      end
    end

    test "a site admin cannot read through :master_read", %{site: site, keys: keys} do
      admin = create_user_with_permissions!(@admin, site_id: site.id)

      assert {:error, _master_only} = read(:master_read, admin, nil, keys)
    end

    # Ash applies a read policy as a filter, so a reader it refuses gets an empty list rather than an
    # error — the rows are there, as the master's read of the same keys shows.
    test "a user with no admin permission reads nothing", %{site: site, keys: keys} do
      nobody = create_user!(site_id: site.id)
      master_nobody = create_user!()

      master = create_user_with_permissions!(@admin)

      assert {:ok, []} = read(:tenant_read, nobody, site.id, keys)
      assert {:ok, []} = read(:master_read, master_nobody, nil, keys)
      assert keys_read(:master_read, master, nil, keys) == Enum.sort(keys)
    end

    # Nobody is not a master: the master's read refuses a missing actor outright.
    test "nobody at all reads nothing", %{site: site, keys: keys} do
      assert {:ok, []} = read(:tenant_read, nil, site.id, keys)
      assert {:error, %Ash.Error.Forbidden{}} = read(:master_read, nil, nil, keys)
    end
  end

  describe "writing" do
    setup %{site: site, other: other, global_language: global_language, n: n} do
      own = row!(key: "Own #{n}", language: "en", site_id: site.id, value: "mine")
      theirs = row!(key: "Theirs #{n}", language: "en", site_id: other.id, value: "private")
      shared = row!(key: "Shared #{n}", language: global_language, site_id: nil, value: "all")
      admin = create_user_with_permissions!(@admin, site_id: site.id)

      %{own: own, theirs: theirs, shared: shared, admin: admin}
    end

    # The control for every refusal below: the same admin, the same actions, their own row.
    test "a site admin updates and destroys their own row", %{site: site, own: own, admin: admin} do
      assert {:ok, %Translation{value: "changed"}} =
               Ash.update(own, %{value: "changed"},
                 action: :update,
                 actor: admin,
                 tenant: site.id,
                 authorize?: true
               )

      assert :ok =
               Ash.destroy(own,
                 action: :destroy,
                 actor: admin,
                 tenant: site.id,
                 authorize?: true
               )

      assert rows_named(own.key) == []
    end

    test "a site admin cannot update or destroy a global row", %{
      site: site,
      shared: shared,
      admin: admin
    } do
      assert {:error, _refused} =
               Ash.update(shared, %{value: "hijacked"},
                 action: :update,
                 actor: admin,
                 tenant: site.id,
                 authorize?: true
               )

      assert {:error, _refused} =
               Ash.update(shared, %{value: "hijacked"},
                 action: :master_update,
                 actor: admin,
                 authorize?: true
               )

      assert {:error, _refused} =
               Ash.destroy(shared,
                 action: :destroy,
                 actor: admin,
                 tenant: site.id,
                 authorize?: true
               )

      assert {:error, _refused} =
               Ash.destroy(shared, action: :master_destroy, actor: admin, authorize?: true)

      assert stored(shared).value == "all"
    end

    # Named with the admin's own tenant and with the other site's: the policy reads the actor's site,
    # so neither tenant gets them through.
    test "a site admin cannot write another site's row, whichever tenant they name", %{
      site: site,
      other: other,
      theirs: theirs,
      admin: admin
    } do
      for tenant <- [site.id, other.id] do
        assert {:error, _refused} =
                 Ash.update(theirs, %{value: "hijacked"},
                   action: :update,
                   actor: admin,
                   tenant: tenant,
                   authorize?: true
                 )

        assert {:error, _refused} =
                 Ash.destroy(theirs,
                   action: :destroy,
                   actor: admin,
                   tenant: tenant,
                   authorize?: true
                 )
      end

      assert stored(theirs).value == "private"
    end

    test "a site admin's :create lands on their own site", %{site: site, admin: admin, n: n} do
      assert {:ok, row} =
               Ash.create(Translation, %{key: "New #{n}", language: "fa", value: "نو"},
                 action: :create,
                 actor: admin,
                 tenant: site.id,
                 authorize?: true
               )

      forget_cached(row)
      assert row.site_id == site.id
    end

    # `:create` does not accept `site_id`; it stamps the tenant. So the only way to aim a row at
    # another site is to name that site as the tenant, and the policy refuses it off the actor.
    test "a site admin cannot create a row on another site", %{
      site: site,
      other: other,
      admin: admin,
      n: n
    } do
      assert {:error, _not_an_input} =
               Ash.create(Translation, %{key: "New #{n}", language: "en", site_id: other.id},
                 action: :create,
                 actor: admin,
                 tenant: site.id,
                 authorize?: true
               )

      assert {:error, _master_only} =
               Ash.create(Translation, %{key: "New #{n}", language: "en", site_id: other.id},
                 action: :master_create,
                 actor: admin,
                 authorize?: true
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(Translation, %{key: "New #{n}", language: "en"},
                 action: :create,
                 actor: admin,
                 tenant: other.id,
                 authorize?: true
               )

      assert rows_named("New #{n}") == []
    end

    test "a master writes any site's row and the global ones", %{theirs: theirs, shared: shared} do
      master = create_user_with_permissions!(@admin)

      for row <- [theirs, shared] do
        assert {:ok, %Translation{value: "by master"}} =
                 Ash.update(row, %{value: "by master"},
                   action: :master_update,
                   actor: master,
                   authorize?: true
                 )
      end
    end

    test "an update cannot move a row to another key, language or site", %{
      site: site,
      other: other,
      own: own,
      admin: admin
    } do
      for change <- [%{key: "Other"}, %{language: "fa"}, %{site_id: other.id}] do
        assert {:error, _not_an_input} =
                 Ash.update(own, change,
                   action: :update,
                   actor: admin,
                   tenant: site.id,
                   authorize?: true
                 )
      end

      assert %Translation{key: key, language: "en", site_id: site_id} = stored(own)
      assert key == own.key
      assert site_id == site.id
    end
  end

  # REACHED ONLY WITH `authorize?: false`. The cache loads through `:read_any` and a saved template
  # registers through `:register`, and both bypass the tenant — so an actor, however privileged, is
  # refused rather than trusted to be the system.
  describe ":register and :read_any" do
    setup %{site: site, n: n} do
      %{
        existing: row!(key: "Existing #{n}", language: "en", site_id: site.id, value: "there"),
        actors: [
          create_user_with_permissions!(["*"]),
          create_user_with_permissions!(@admin),
          create_user_with_permissions!(@admin, site_id: site.id)
        ]
      }
    end

    test ":register is forbidden to every actor", %{site: site, actors: actors, n: n} do
      for actor <- actors do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Ash.create(Translation, %{key: "Save #{n}", language: "en", site_id: site.id},
                   action: :register,
                   actor: actor,
                   authorize?: true
                 )
      end

      assert rows_named("Save #{n}") == []
    end

    # A read policy is a filter, so the refusal is an empty list: every actor, the super admin
    # included, reads none of a row the system reads with `authorize?: false`.
    test ":read_any gives every actor nothing", %{actors: actors, existing: existing} do
      for actor <- actors do
        assert {:ok, []} =
                 Translation
                 |> Ash.Query.for_read(:read_any, %{}, actor: actor, authorize?: true)
                 |> Ash.Query.filter(key == ^existing.key)
                 |> Ash.read(page: false)
      end

      assert [%Translation{}] = rows_named(existing.key)
    end

    # What makes registering on every save safe: a key that is already translated keeps its word.
    test ":register never overwrites a value", %{existing: existing} do
      assert {:ok, _upserted} =
               Ash.create(
                 Translation,
                 %{key: existing.key, language: existing.language, site_id: existing.site_id},
                 action: :register,
                 authorize?: false
               )

      assert stored(existing).value == "there"
    end
  end

  describe ":used — whether any template still asks for the key" do
    test "is true while a template asks for the key, and false once none does", %{
      site: site,
      n: n
    } do
      key = "Headline #{n}"
      component = create_component!(site_id: site.id, template: ~s|<h2>{t("#{key}")}</h2>|)

      assert used(key) == [{site.id, "en", true}, {site.id, "fa", true}]

      Ash.update!(component, %{template: "<h2>No words here</h2>"},
        action: :update,
        tenant: site.id,
        authorize?: false
      )

      assert used(key) == [{site.id, "en", false}, {site.id, "fa", false}]
    end

    test "is false for a key no template has ever asked for", %{site: site, n: n} do
      row!(key: "Orphan #{n}", language: "en", site_id: site.id)

      assert used("Orphan #{n}") == [{site.id, "en", false}]
    end

    # A global component renders on every site, so the words it asks for are that site's too.
    test "counts a global template's words for a site's own row", %{site: site, n: n} do
      key = "Footer #{n}"
      create_component!(site_id: nil, template: ~s|<footer>{t("#{key}")}</footer>|)
      row!(key: key, language: "fa", site_id: site.id)

      assert {site.id, "fa", true} in used(key)
    end

    # The reverse does not hold: one site's template is no reason to keep another site's row.
    test "does not count one site's template for another site's row", %{
      site: site,
      other: other,
      n: n
    } do
      key = "Banner #{n}"
      create_component!(site_id: site.id, template: ~s|<p>{t("#{key}")}</p>|)
      row!(key: key, language: "en", site_id: other.id)

      assert {site.id, "en", true} in used(key)
      assert {other.id, "en", false} in used(key)
    end
  end
end
