# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageLanguageTest do
  @moduledoc """
  A page's language editions, as rows: the same model blog posts and documents already use.

  An edition is a page with a `language` and a `language_group_id`, the group's key being its
  master's own id. These pin what the resource keeps true about that on every writer's behalf — the
  form, the JSON:API, "Add translation", a draft being published:

    * a new page is the master of a group of its own, written WITH the row. A second write would be an
      `:update`, which on a page is a second version, a second broadcast and a second compile job;
    * a translation keeps the group it was given, and a group holds each language once;
    * a group is never emptied — a page whose group is cleared starts one of its own;
    * the master cannot be archived, nor deleted for good, while a live translation of it exists, nor
      can a page with no group yet, whose translations join its id — however the destroy is called,
      `authorize?: false` included;
    * a translation is restored into a group that holds: not while its master is archived, and never
      at all once its master has been deleted, and the archive's bulk read hands the masters over
      first so a group restored in one selection comes back whole;
    * publishing a draft carries its language and group, and a draft that names no group leaves the
      page's alone.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.{Page, PageDraft}
  alias MishkaCmsCore.LanguageEditions
  alias MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore
  alias MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion
  alias MishkaCmsCore.Test.Plugins.{LanguageDeleteRefused, LanguageGroupChanged}
  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaGervaz.Form.Web.{DataLoader, State}
  alias MishkaGervaz.Table.Web.Events.BulkActionResult

  require Ash.Query

  @moduletag :integration

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @refused "This is the original English version. Its Persian translation is still live, so it " <>
             "can't be deleted yet. Archive or delete that translation first, then this one."
  @restore_refused "This is the Persian translation. Its original English version is archived, so " <>
                     "it can't be restored yet. Restore the original first, then this one."
  @restore_gone "This is the Persian translation. Its original version has been deleted for good, " <>
                  "so it can't be restored. It can only be deleted for good."

  setup do
    site = create_site!()
    master_user = create_user_with_permissions!(["*"])
    tenant_user = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
    master = create_page!(site_id: site.id, name: "about", path: "/about")

    %{site: site, master: master, master_user: master_user, tenant_user: tenant_user}
  end

  defp translate!(site, master, language, overrides \\ []) do
    create_page!(
      [
        site_id: site.id,
        name: "about-#{language}",
        path: "/#{language}/about",
        language: language,
        language_group_id: master.id
      ] ++ overrides
    )
  end

  defp archived!(page),
    do: Ash.get!(Page, page.id, action: :master_get_archived, authorize?: false)

  defp versions(page) do
    Page.Version
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(version_source_id == ^page.id)
    |> Ash.count!(authorize?: false)
  end

  describe "a new page" do
    test "is the master of a group of its own, in English", %{master: master} do
      assert master.language == "en"
      assert master.language_group_id == master.id
    end

    test "and so is one a master creates for a site", %{site: site, master_user: master_user} do
      page =
        Page
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "pricing",
            title: "Pricing",
            path: "/pricing",
            template: "<div>pricing</div>",
            site_id: site.id
          },
          actor: master_user
        )
        |> Ash.create!()

      assert page.language_group_id == page.id
    end

    test "gets its group in the same write, so creating it leaves one version", %{master: master} do
      assert versions(master) == 1
    end
  end

  describe "a translation" do
    test "keeps its master's group", %{site: site, master: master} do
      fa = translate!(site, master, "fa")

      assert fa.language == "fa"
      assert fa.language_group_id == master.id
    end

    test "is refused for a language its group already has", %{site: site, master: master} do
      translate!(site, master, "fa")

      assert {:error, %Ash.Error.Invalid{} = error} =
               Page
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "about-fa-again",
                   title: "About Fa Again",
                   path: "/fa/about-again",
                   template: "<div>again</div>",
                   language: "fa",
                   language_group_id: master.id
                 },
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()

      assert Exception.message(error) =~ "already exists in this language group"
    end

    test "cannot empty its group; it becomes a master of its own", %{site: site, master: master} do
      fa = translate!(site, master, "fa")

      detached =
        fa
        |> Ash.Changeset.for_update(:update, %{language_group_id: nil}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      assert detached.language_group_id == fa.id
    end
  end

  describe "archiving the master" do
    test "is refused while a translation exists, for a tenant", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")

      assert {:error, %Ash.Error.Invalid{} = error} =
               master
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant_user)
               |> Ash.destroy()

      assert Exception.message(error) =~ @refused
    end

    test "and for a master", %{site: site, master: master, master_user: master_user} do
      translate!(site, master, "fa")
      page = Ash.get!(Page, master.id, action: :master_get, actor: master_user)

      assert {:error, %Ash.Error.Invalid{}} =
               page
               |> Ash.Changeset.for_destroy(:master_destroy, %{}, actor: master_user)
               |> Ash.destroy()
    end

    # A PAGE STORED BEFORE LANGUAGE GROUPS has none until the boot or its restore gives it one, and
    # a translation made of it meanwhile joins the group of its id all the same.
    test "and for a page with no group yet", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")

      Ecto.Adapters.SQL.query!(
        @repo,
        "UPDATE pages SET language_group_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(master.id)]
      )

      ungrouped = Ash.get!(Page, master.id, tenant: site.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = error} =
               ungrouped
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant_user)
               |> Ash.destroy()

      assert Exception.message(error) =~ @refused
    end

    # THE ADMIN TABLES DESTROY WITH THE RECORD AND NO `authorize?`, and an archive called that way
    # builds its changeset before the domain's default applies: its validations are told
    # `authorize?: false`.
    test "and as the admin tables call it, with the record and no authorize?", %{
      site: site,
      master: master,
      master_user: master_user,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")
      page = Ash.get!(Page, master.id, action: :master_get, actor: master_user)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.destroy(page,
                 action: :master_destroy,
                 actor: master_user,
                 return_destroyed?: true
               )

      assert Exception.message(error) =~ @refused

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.destroy(master,
                 action: :destroy,
                 tenant: site.id,
                 actor: tenant_user,
                 return_destroyed?: true
               )

      assert Exception.message(error) =~ @refused
    end

    test "and with authorize?: false", %{site: site, master: master} do
      translate!(site, master, "fa")

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.destroy(master, action: :destroy, tenant: site.id, authorize?: false)

      assert Exception.message(error) =~ @refused
    end

    test "goes ahead once the translations are gone", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      fa = translate!(site, master, "fa")

      assert :ok =
               fa
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant_user)
               |> Ash.destroy()

      assert :ok =
               master
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant_user)
               |> Ash.destroy()
    end
  end

  # WHAT THE ADMIN AND THE API READ. "Master" is the word for a user with no site, so the refusal
  # never uses it; it names the languages and says what to do.
  describe "the refusal" do
    defp refusal(page, opts) do
      {:error, %Ash.Error.Invalid{errors: errors}} = Ash.destroy(page, opts)

      Enum.find(
        errors,
        &match?(%Ash.Error.Changes.InvalidAttribute{field: :language_group_id}, &1)
      )
    end

    test "names the original's language and each live translation's, and says what to do", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fr")
      translate!(site, master, "fa")

      error = refusal(master, action: :destroy, tenant: site.id, actor: tenant_user)

      assert error.message ==
               "This is the original English version. Its translations in French and Persian " <>
                 "are still live, so it can't be deleted yet. Archive or delete those " <>
                 "translations first, then this one."

      refute error.message =~ ~r/master/i
    end

    test "leaves out a translation already archived", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")
      fr = translate!(site, master, "fr")
      :ok = Ash.destroy(fr, action: :destroy, tenant: site.id, actor: tenant_user)

      error = refusal(master, action: :destroy, tenant: site.id, actor: tenant_user)

      assert error.message == @refused
    end

    test "says the same when deleting for good", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")

      error = refusal(master, action: :permanent_destroy, tenant: site.id, actor: tenant_user)

      assert error.message == @refused
    end

    test "reads in the language of the process that deletes", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fr")
      translate!(site, master, "fa")
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")

      error = refusal(master, action: :destroy, tenant: site.id, actor: tenant_user)

      assert error.message ==
               "[fa] This is the original انگلیسی version. " <>
                 "[fa] Its translations in فارسی و فرانسوی are still live, so it " <>
                 "can't be deleted yet. Archive or delete those translations first, then this one."
    end

    test "names the original the admin can act on, out of the API's sight", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")

      error = refusal(master, action: :destroy, tenant: site.id, actor: tenant_user)

      assert error.private_vars == [live_translations_of: master.id]
      assert error.vars == []
    end

    test "is found among a failure's errors, with the original's id and its own message", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")
      {:error, error} = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
      other = Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "is taken")

      assert LanguageEditions.refused_originals(error) == [%{id: master.id, message: @refused}]

      assert LanguageEditions.refused_originals(%BulkActionResult{failed_errors: [other, error]}) ==
               [%{id: master.id, message: @refused}]

      assert LanguageEditions.refused_originals(other) == []
    end

    # THE ALERT SAYS WHAT THE ERROR FLASH WOULD, so a failure that was only this refusal puts no
    # flash; one with another reason besides, or a bulk that partly went, keeps its own message.
    test "puts the table's own message aside only when the refusal is all there is to say", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")
      {:error, error} = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
      other = Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "is taken")
      state = %{static: %{resource: Page}}
      socket = %Phoenix.LiveView.Socket{}

      assert LanguageEditions.on_delete_refused(error, state, socket) == {:halt, socket}

      failed = %BulkActionResult{status: :error, failed_errors: [error]}
      assert LanguageEditions.on_delete_refused(failed, state, socket) == {:halt, socket}

      partly = %BulkActionResult{status: :partial_success, failed_errors: [error]}
      assert LanguageEditions.on_delete_refused(partly, state, socket) == socket

      mixed = %BulkActionResult{status: :error, failed_errors: [error, other]}
      assert LanguageEditions.on_delete_refused(mixed, state, socket) == socket

      assert LanguageEditions.on_delete_refused(other, state, socket) == socket

      assert LanguageEditions.on_delete_refused(
               %BulkActionResult{status: :success},
               state,
               socket
             ) == socket
    end

    test "reads a language it has no name for as its code, and an original with none as unnamed" do
      assert PreventMasterLanguageDeletion.message(nil, ["xx", "fa-IR"]) ==
               "This is the original version. Its translations in Persian (Iran) and XX are still " <>
                 "live, so it can't be deleted yet. Archive or delete those translations first, " <>
                 "then this one."
    end
  end

  # A PLUGIN MAY LISTEN FOR A DELETE REFUSED FOR LIVE TRANSLATIONS, and for the alert's quick action
  # taking those translations.
  describe "plugin events" do
    setup do
      Process.register(self(), :__plugin_hook_probe__)
      :ok
    end

    test "a refused delete is announced on runtime:language:delete_refused", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      register_plugin(LanguageDeleteRefused, "runtime:language:delete_refused")
      translate!(site, master, "fa")
      %{id: id, site_id: site_id} = master

      assert {:error, _refused} =
               Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)

      assert_receive {:language_delete_refused, ^id, ^site_id, ["fa"], @refused}
    end

    test "the quick action is announced on runtime:state:language_group:changed", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      register_plugin(LanguageGroupChanged, "runtime:state:language_group:changed")
      %{id: fa} = translate!(site, master, "fa")
      id = master.id

      {:error, error} = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
      refused = LanguageEditions.refused_originals(error)

      assert :ok =
               Page
               |> LanguageEditions.refusal(refused, tenant_user)
               |> LanguageEditions.take_translations(tenant_user)

      assert_receive {:language_group_changed, :translations_archived, ^id, [^fa]}
    end
  end

  describe "deleting the master for good" do
    test "is refused while a translation exists, for a tenant", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      translate!(site, master, "fa")

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.destroy(master,
                 action: :permanent_destroy,
                 tenant: site.id,
                 actor: tenant_user
               )

      assert Exception.message(error) =~ @refused
    end

    test "and for a master", %{site: site, master: master, master_user: master_user} do
      translate!(site, master, "fa")
      page = Ash.get!(Page, master.id, action: :master_get, actor: master_user)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.destroy(page, action: :master_permanent_destroy, actor: master_user)

      assert Exception.message(error) =~ @refused
    end

    # AN ARCHIVED TRANSLATION IS IN NOBODY'S WAY: the archive lists a master beside its archived
    # editions, and a selection holding all of them empties the group in one go. What keeps that
    # edition from outliving its master is its restore, below.
    test "goes ahead while an archived translation remains", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      fa = translate!(site, master, "fa")
      :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
      :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
      archived = Ash.get!(Page, master.id, action: :master_get_archived, authorize?: false)

      assert :ok =
               Ash.destroy(archived,
                 action: :permanent_destroy,
                 tenant: site.id,
                 actor: tenant_user
               )
    end

    test "goes ahead once the translations are gone for good", %{
      site: site,
      master: master,
      tenant_user: tenant_user
    } do
      fa = translate!(site, master, "fa")

      assert :ok =
               Ash.destroy(fa, action: :permanent_destroy, tenant: site.id, actor: tenant_user)

      assert :ok =
               Ash.destroy(master,
                 action: :permanent_destroy,
                 tenant: site.id,
                 actor: tenant_user
               )
    end
  end

  # A TRANSLATION BACK UNDER AN ARCHIVED MASTER is a page no list shows: the pages table lists masters
  # and reaches a translation through its master's chips, so the master comes back first.
  describe "restoring a translation" do
    setup %{site: site, master: master, tenant_user: tenant_user} do
      fa = translate!(site, master, "fa")
      :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
      :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)

      %{fa: archived!(fa), archived_master: archived!(master)}
    end

    test "is refused while its master is archived, for a tenant", %{
      site: site,
      fa: fa,
      tenant_user: tenant_user
    } do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.update(fa, action: :unarchive, tenant: site.id, actor: tenant_user)

      assert Exception.message(error) =~ @restore_refused
      refute Exception.message(error) =~ ~r/master/i
      assert archived!(fa).archived_at
    end

    test "reads in the language of the process that restores", %{
      site: site,
      fa: fa,
      tenant_user: tenant_user
    } do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.update(fa, action: :unarchive, tenant: site.id, actor: tenant_user)

      assert Enum.any?(
               errors,
               &(&1.message ==
                   "[fa] This is the فارسی translation. " <>
                     "[fa] Its original انگلیسی version is archived, so it can't be restored " <>
                     "yet. Restore the original first, then this one.")
             )
    end

    test "and for a master", %{fa: fa, master_user: master_user} do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.update(fa, action: :master_unarchive, actor: master_user)

      assert Exception.message(error) =~ @restore_refused
      assert archived!(fa).archived_at
    end

    # AND ONCE THE MASTER IS GONE FOR GOOD, nothing can be restored under it: that edition can only be
    # deleted too.
    test "is refused for good once its master has been deleted", %{
      site: site,
      fa: fa,
      archived_master: archived_master,
      tenant_user: tenant_user
    } do
      :ok =
        Ash.destroy(archived_master,
          action: :permanent_destroy,
          tenant: site.id,
          actor: tenant_user
        )

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.update(fa, action: :unarchive, tenant: site.id, actor: tenant_user)

      assert Exception.message(error) =~ @restore_gone
      refute Exception.message(error) =~ ~r/master/i
      assert archived!(fa).archived_at
    end

    test "says so in plain words when the original could not be checked, or has no language" do
      assert PreventOrphanedTranslationRestore.message("fa", :unchecked) ==
               "This is the Persian translation. Its original version could not be checked just " <>
                 "now, so it can't be restored yet. Try again in a moment."

      assert PreventOrphanedTranslationRestore.message(nil, {:archived, nil}) ==
               "This is a translation. Its original version is archived, so it can't be restored " <>
                 "yet. Restore the original first, then this one."
    end

    test "goes ahead once its master is back", %{
      site: site,
      fa: fa,
      archived_master: archived_master,
      tenant_user: tenant_user
    } do
      assert {:ok, master} =
               Ash.update(archived_master,
                 action: :unarchive,
                 tenant: site.id,
                 actor: tenant_user
               )

      assert is_nil(master.archived_at)

      assert {:ok, restored} =
               Ash.update(fa, action: :unarchive, tenant: site.id, actor: tenant_user)

      assert is_nil(restored.archived_at)
    end
  end

  # THE ARCHIVE'S BULK ACTIONS WALK THEIR ROWS ONE AT A TIME, in the order the read hands them over —
  # and a random-uuid key is no order at all. A group restored in one selection needs its master
  # first, so `MishkaCmsCore.LanguageEditions.BulkActionHandler` sorts the archive's bulk read.
  describe "the archive's bulk read" do
    setup %{site: site, master: master, tenant_user: tenant_user} do
      second = create_page!(site_id: site.id, name: "pricing", path: "/pricing")

      editions =
        Enum.map(["fa", "ar"], &translate!(site, master, &1)) ++
          [translate!(site, second, "fa", name: "pricing-fa", path: "/fa/pricing")]

      Enum.each(editions ++ [master, second], fn page ->
        :ok = Ash.destroy(page, action: :destroy, tenant: site.id, actor: tenant_user)
      end)

      %{second: second}
    end

    test "hands the masters over first", %{
      master: master,
      second: second,
      master_user: master_user
    } do
      state = %{
        static: %{resource: Page},
        archive_status: :archived,
        master_user?: true,
        current_user: master_user
      }

      %{results: rows} =
        Page
        |> MishkaCmsCore.LanguageEditions.BulkActionHandler.build_bulk_query(state, nil)
        |> Ash.read!(actor: master_user, page: [limit: 100])

      assert length(rows) == 5

      assert rows
             |> Enum.take_while(&(&1.language_group_id == &1.id))
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([master.id, second.id])
    end

    test "and leaves the active list's order alone", %{master_user: master_user} do
      state = %{
        static: %{resource: Page},
        archive_status: :active,
        master_user?: true,
        current_user: master_user
      }

      query = MishkaCmsCore.LanguageEditions.BulkActionHandler.build_bulk_query(Page, state, nil)

      assert query.sort in [nil, []]
    end
  end

  # A MASTER READS EVERY SITE'S PAGES, so the picker has to narrow them to the site the page is on:
  # a group on another site is one no edition of this page would ever be listed or checked with.
  describe "the Language Group picker" do
    defp group_choices(user, field_values) do
      state = %{State.init("page-form", Page, user) | field_values: field_values}
      field = Enum.find(state.static.fields, &(&1.name == :language_group_id))

      {:ok, options, _more?} = DataLoader.Default.relation_loader().load_options(field, state)
      Enum.map(options, &elem(&1, 1))
    end

    test "offers a master only the groups of the page's site", %{
      site: site,
      master: master,
      master_user: master_user
    } do
      elsewhere = create_page!(site_id: create_site!().id, name: "elsewhere", path: "/elsewhere")
      choices = group_choices(master_user, %{site_id: site.id})

      assert master.language_group_id in choices
      refute elsewhere.language_group_id in choices, "a group on another site was offered"
    end

    test "and a tenant only its own site's", %{master: master, tenant_user: tenant_user} do
      elsewhere = create_page!(site_id: create_site!().id, name: "elsewhere", path: "/elsewhere")
      choices = group_choices(tenant_user, %{})

      assert master.language_group_id in choices
      refute elsewhere.language_group_id in choices
    end
  end

  describe "publishing a draft" do
    defp publish!(draft, site) do
      draft
      |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id)
      |> Ash.update!(authorize?: false)
    end

    defp draft!(site, attrs) do
      PageDraft
      |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
      |> Ash.create!(authorize?: false)
    end

    defp reload(page), do: Ash.get!(Page, page.id, action: :master_get, authorize?: false)

    test "creates the page in the draft's language and group", %{site: site, master: master} do
      draft!(site, %{
        name: "about-ar",
        title: "About Ar",
        path: "/ar/about",
        template: "<div>عن</div>",
        language: "ar",
        language_group_id: master.id
      })
      |> publish!(site)

      page =
        Page
        |> Ash.Query.filter(path == "/ar/about")
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      assert page.language == "ar"
      assert page.language_group_id == master.id
    end

    test "keeps the page's language and group on an update", %{site: site, master: master} do
      fa = translate!(site, master, "fa")

      draft!(site, %{
        name: fa.name,
        title: fa.title,
        path: fa.path,
        template: "<div>درباره</div>",
        language: "fa",
        language_group_id: master.id,
        source_page_id: fa.id
      })
      |> publish!(site)

      assert %{language: "fa", language_group_id: group} = reload(fa)
      assert group == master.id
    end

    test "that names no group leaves the page's group alone", %{site: site, master: master} do
      fa = translate!(site, master, "fa")

      draft!(site, %{
        name: fa.name,
        title: fa.title,
        path: fa.path,
        template: "<div>درباره</div>",
        language: "fa",
        source_page_id: fa.id
      })
      |> publish!(site)

      assert reload(fa).language_group_id == master.id
    end
  end

  defp register_plugin(module, event) do
    {:ok, _} =
      Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, module, false) end)
  end
end
