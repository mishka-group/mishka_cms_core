# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.RegisterTranslationKeysTest do
  @moduledoc """
  Saving a component, a page or a layout registers the keys its template and its code — helpers,
  events, infos — pass to `t/1`: one row per key in every language the record's site publishes in,
  ready to translate in the admin.

  The same change is wired into all three resources, so every behaviour here is proved for each of
  them: a create registers, a template edit registers what it adds, an edit that leaves the template
  alone registers nothing, a save never erases a translation somebody wrote, and a template that is
  refused registers nothing at all. A global component or layout registers global rows.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Translation, Translations}
  alias MishkaCmsCore.Runtime.States.TranslationsState
  alias MishkaCmsCore.Settings

  require Ash.Query

  @moduletag :integration

  setup do
    site = create_site!()
    forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    %{site: site, n: System.unique_integer([:positive])}
  end

  for kind <- [:component, :page, :layout] do
    describe "#{kind}" do
      @kind kind

      test "creating one registers each key in every language its site publishes in",
           %{site: site, n: n} do
        keys = ["Heading #{n}", "Read %{count} posts #{n}"]

        save!(
          @kind,
          site.id,
          ~s|<section><h2>{t("Heading #{n}")}</h2><p>Plain #{n}</p><p>{t("Read %{count} posts #{n}", count: 3)}</p></section>|
        )

        # Every row the site has, not only the ones asked about: text outside `t/1` must not register.
        assert site_rows(site.id) == untranslated(site.id, keys, ["en", "fa"])
      end

      test "updating the template registers the keys the new one adds, and keeps the old ones",
           %{site: site, n: n} do
        record = save!(@kind, site.id, ~s|<div>{t("Old #{n}")}</div>|)

        update!(record, %{template: ~s|<div>{t("Old #{n}")} {t("New #{n}")}</div>|})

        assert site_rows(site.id) == untranslated(site.id, ["New #{n}", "Old #{n}"], ["en", "fa"])
      end

      # A row that already exists is left alone by `register`, so counting the same rows twice proves
      # nothing. A language the site gains after the create makes a skipped registration visible:
      # had the edit registered, `ar` rows would have appeared.
      test "an update that leaves the template alone registers nothing, where a template edit would",
           %{site: site, n: n} do
        record = save!(@kind, site.id, ~s|<div>{t("Stays #{n}")}</div>|)
        before = site_rows(site.id)

        {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)
        record = update!(record, %{description: "Edited #{n}"})

        assert site_rows(site.id) == before
        assert length(before) == 2

        update!(record, %{template: ~s|<div>{t("Stays #{n}")}</div><br />|})

        assert site_rows(site.id) == untranslated(site.id, ["Stays #{n}"], ["ar", "en", "fa"])
      end

      # The value carries two U+200C: the row must come back byte for byte, not merely non-nil.
      test "saving again never erases a value someone wrote", %{site: site, n: n} do
        key = "Categories #{n}"
        record = save!(@kind, site.id, ~s|<div>{t("#{key}")}</div>|)
        translate!(site.id, key, "fa", "دسته‌بندی‌ها")

        update!(record, %{template: ~s|<div>{t("#{key}")} {t("Tags #{n}")}</div>|})
        save!(@kind, site.id, ~s|<p>{t("#{key}")}</p>|)

        assert {site.id, key, "fa", "دسته‌بندی‌ها"} in site_rows(site.id)
        assert {site.id, key, "en", nil} in site_rows(site.id)
      end

      # An `after_action`: a template the resource refuses never reaches it, on create or on update.
      test "a template that is refused registers nothing", %{site: site, n: n} do
        assert_raise Ash.Error.Invalid, fn ->
          save!(@kind, site.id, ~s|<div :foo={1}>{t("Refused #{n}")}</div>|)
        end

        record = save!(@kind, site.id, "<div>No keys</div>")

        assert_raise Ash.Error.Invalid, fn ->
          update!(record, %{template: ~s|<div :foo={1}>{t("Refused again #{n}")}</div>|})
        end

        assert site_rows(site.id) == []
      end
    end
  end

  # THE CODE ASKS TOO: `t/1` is imported into helpers, events and infos as it is into the template.
  for {kind, field} <- [
        component: :helpers,
        layout: :helpers,
        page: :helpers,
        page: :events,
        page: :infos
      ] do
    describe "#{kind} #{field}" do
      @kind kind
      @field field

      test "creating one registers the keys only its code asks for", %{site: site, n: n} do
        save!(@kind, site.id, "<div>No keys</div>", %{
          @field => [code_entry(@field, "Coded #{n}")]
        })

        assert site_rows(site.id) == untranslated(site.id, ["Coded #{n}"], ["en", "fa"])
      end

      test "an update that changes only the code registers what it adds", %{site: site, n: n} do
        record =
          save!(@kind, site.id, "<div>No keys</div>", %{
            @field => [code_entry(@field, "Old #{n}")]
          })

        update!(
          record,
          %{@field => [code_entry(@field, "Old #{n}"), code_entry(@field, "New #{n}")]},
          %{page_code: :package}
        )

        assert site_rows(site.id) == untranslated(site.id, ["New #{n}", "Old #{n}"], ["en", "fa"])
      end
    end
  end

  # A page always belongs to a site, so only these two have a global row to save.
  for kind <- [:component, :layout] do
    describe "global #{kind}" do
      @kind kind

      # The language lists are read, not set: they are shared by every suite running beside this one.
      test "registers global rows in every language a site publishes in, and none for any site",
           %{site: site, n: n} do
        record = save!(@kind, nil, ~s|<div>{t("Global #{n}")}</div>|)
        assert record.site_id == nil

        update!(record, %{template: ~s|<div>{t("Global #{n}")} {t("Global added #{n}")}</div>|})

        keys = ["Global #{n}", "Global added #{n}"]

        assert rows(keys) == untranslated(nil, keys, Translations.languages(nil))
        assert site_rows(site.id) == []
      end
    end
  end

  defp save!(kind, site_id, template, attrs \\ %{})

  defp save!(:component, site_id, template, attrs),
    do: create_component!([site_id: site_id, template: template] ++ Map.to_list(attrs))

  defp save!(:page, site_id, template, attrs),
    do: create_page!([site_id: site_id, template: template] ++ Map.to_list(attrs))

  defp save!(:layout, site_id, template, attrs),
    do: create_layout!([site_id: site_id, template: template] ++ Map.to_list(attrs))

  # One entry of `field` whose code asks `t/1` for `key`, named after it so two entries differ.
  defp code_entry(:helpers, key),
    do: %{name: "said_#{:erlang.phash2(key)}", args: "", code: ~s|t("#{key}")|}

  defp code_entry(:events, key),
    do: %{
      name: "said-#{:erlang.phash2(key)}",
      code: ~s|{:noreply, put_flash(socket, :info, t("#{key}"))}|
    }

  defp code_entry(:infos, key),
    do: %{
      name: ":said_#{:erlang.phash2(key)}",
      code: ~s|{:noreply, put_flash(socket, :info, t("#{key}"))}|
    }

  # The action each record is edited through in the admin: a master's for a global one, a site's own
  # otherwise.
  # `context` is `%{page_code: :package}` for an edit of the code, which only a package may make
  # without an actor allowed to.
  defp update!(record, attrs, context \\ %{})

  defp update!(%{site_id: nil} = record, attrs, context) do
    record
    |> Ash.Changeset.for_update(:master_update, attrs, authorize?: false, context: context)
    |> Ash.update!()
  end

  defp update!(record, attrs, context) do
    record
    |> Ash.Changeset.for_update(:update, attrs,
      tenant: record.site_id,
      authorize?: false,
      context: context
    )
    |> Ash.update!()
  end

  # Writes a translation the way the admin does; its broadcast reaches the ETS cache, so the entry is
  # taken back out when the test ends.
  defp translate!(site_id, key, language, value) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and key == ^key and language == ^language)
    |> Ash.read_one!(authorize?: false)
    |> Ash.Changeset.for_update(:update, %{value: value}, tenant: site_id, authorize?: false)
    |> Ash.update!()

    on_exit(fn -> TranslationsState.put(site_id, language, key, nil) end)
  end

  defp site_rows(site_id) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> shape()
  end

  defp rows(keys) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key in ^keys)
    |> shape()
  end

  defp shape(query) do
    query
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(&{&1.site_id, &1.key, &1.language, &1.value})
    |> Enum.sort()
  end

  defp untranslated(site_id, keys, languages) do
    Enum.sort(for key <- keys, language <- languages, do: {site_id, key, language, nil})
  end
end
