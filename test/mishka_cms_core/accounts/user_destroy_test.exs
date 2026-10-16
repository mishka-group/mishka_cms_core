# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.UserDestroyTest do
  @moduledoc """
  Deleting an account that has worked in the editor.

  Everything the editor records about a change keeps the account's id: the history sheet's events,
  the versions of a page, a review note and who closed it. They are a record of what happened, so
  they are not the account's to take with it and not a reason to keep it — deleting the account
  leaves each row in place with no author, which the screens read as a deleted user. Before, the
  first of them the database met refused the delete with a raw `Ecto.ConstraintError`.

  `every foreign key to users` is the class guard: it reads the database rather than a list of the
  resources known today, so a table added later that points at an account without saying what
  happens to it fails here, by name.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.{Page, PageBuilderEvent, PageComment}

  require Ash.Query

  @moduletag :unit
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  setup do
    site = create_site!(active: true)

    %{
      site: site,
      page: create_page!(site_id: site.id),
      master: create_user_with_permissions!(["*"]),
      site_admin: create_user_with_permissions!(["*"], site_id: site.id)
    }
  end

  # An account that has done each of the things the editor keeps a record of.
  defp worker!(%{site: site, page: page}) do
    worker = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

    event =
      PageBuilderEvent
      |> Ash.Changeset.for_create(
        :create,
        %{
          id: Ecto.UUID.generate(),
          source_type: :page,
          source_id: page.id,
          site_id: site.id,
          label: "Set gap (base)",
          kind: :style,
          op: :set_style
        },
        tenant: site.id,
        actor: worker
      )
      |> Ash.create!(actor: worker)

    # The note on the event is its own attribution, and the worker wrote it too.
    event =
      event
      |> Ash.Changeset.for_update(:annotate, %{note: "kept on purpose"},
        tenant: site.id,
        actor: worker
      )
      |> Ash.update!()

    page
    |> Ash.Changeset.for_update(:update, %{name: "renamed-by-worker"},
      actor: worker,
      tenant: site.id
    )
    |> Ash.update!()

    note =
      PageComment
      |> Ash.Changeset.for_create(
        :create,
        %{body: "a note", type: :information, section: :page, document_id: page.id},
        tenant: site.id,
        actor: worker
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:resolve, %{}, tenant: site.id, actor: worker)
      |> Ash.update!()

    %{worker: worker, event: event, note: note}
  end

  defp event(context, id) do
    PageBuilderEvent
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(tenant: context.site.id, actor: context.master)
  end

  defp note(context, id) do
    PageComment
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(tenant: context.site.id, actor: context.master)
  end

  defp page_versions(context) do
    version = AshPaperTrail.Resource.Info.version_resource(Page)

    version
    |> Ash.Query.filter(version_source_id == ^context.page.id)
    |> Ash.read!(tenant: context.site.id, actor: context.master)
  end

  defp grants(context, user) do
    MishkaCmsCore.Accounts.UserPermission
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(actor: context.master)
  end

  defp gone?(context, user),
    do: match?({:ok, nil}, Ash.get(User, user.id, actor: context.master, error?: false))

  # What each of the actions that delete an account is run as, and who runs it.
  @paths [
    master_destroy: "the generic master action",
    table_destroy: "the Users table, for a master",
    destroy: "the Users table, for a site's admin",
    tenant_destroy: "the tenant action"
  ]

  defp destroy(:master_destroy, user, context) do
    User
    |> Ash.ActionInput.for_action(:master_destroy, %{id: user.id}, actor: context.master)
    |> Ash.run_action()
    |> case do
      {:ok, %User{}} -> :ok
      other -> other
    end
  end

  defp destroy(:table_destroy, user, context),
    do: Ash.destroy(user, action: :table_destroy, actor: context.master)

  defp destroy(:destroy, user, context),
    do: Ash.destroy(user, action: :destroy, actor: context.site_admin, tenant: context.site.id)

  defp destroy(:tenant_destroy, user, context),
    do:
      Ash.destroy(user,
        action: :tenant_destroy,
        actor: context.site_admin,
        tenant: context.site.id
      )

  describe "an account with a history in the editor" do
    for {path, label} <- @paths do
      test "is deleted by #{label}, and the history stays with no author", context do
        %{worker: worker, event: event, note: note} = worker!(context)

        assert page_versions(context) |> Enum.any?(&(&1.user_id == worker.id)),
               "the setup has to leave a version made by the account"

        assert :ok = destroy(unquote(path), worker, context)
        assert gone?(context, worker)
        assert grants(context, worker) == [], "the account's own permission grants went with it"

        kept = event(context, event.id)
        assert kept.author_id == nil
        assert kept.note_author_id == nil
        assert kept.author_type == :human
        assert kept.note == "kept on purpose"

        kept_note = note(context, note.id)
        assert kept_note.author_id == nil
        assert kept_note.resolved_by_id == nil
        assert kept_note.body == "a note"

        versions = page_versions(context)
        assert versions != []
        refute Enum.any?(versions, &(&1.user_id == worker.id))
        assert Enum.any?(versions, &is_nil(&1.user_id))
      end
    end

    test "the generic master action run by the system, with no actor, still deletes", context do
      %{worker: worker} = worker!(context)

      assert {:ok, %User{}} =
               User
               |> Ash.ActionInput.for_action(:master_destroy, %{id: worker.id}, authorize?: false)
               |> Ash.run_action(authorize?: false)

      assert gone?(context, worker)
    end

    test "does not take the master's own history, or anyone else's, with it", context do
      %{worker: worker} = worker!(context)
      other = worker!(context)

      assert :ok = destroy(:table_destroy, worker, context)

      assert event(context, other.event.id).author_id == other.worker.id
      assert note(context, other.note.id).author_id == other.worker.id
    end

    test "still refuses to delete yourself, and nothing is deleted", context do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.destroy(context.master, action: :table_destroy, actor: context.master)

      refute gone?(context, context.master)
    end
  end

  describe "every foreign key to users" do
    # `a` NO ACTION and `r` RESTRICT refuse the delete, which is what surfaces as a raw constraint
    # error. A key either goes with the account (`c`, its own grants and codes) or lets go of it
    # (`n`, history and notes). A table that is neither has to refuse on purpose, with a message of
    # its own, and be named here when it does.
    test "lets the account go: it cascades or it is released" do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          @repo,
          """
          SELECT conrelid::regclass::text, conname, confdeltype::text
          FROM pg_constraint
          WHERE contype = 'f' AND confrelid = 'users'::regclass
          ORDER BY 1, 2
          """
        )

      assert rows != [], "the query found no foreign key to users at all"

      refusing = for [table, name, rule] <- rows, rule not in ["c", "n"], do: "#{table}.#{name}"

      assert refusing == [],
             "deleting an account is refused by #{Enum.join(refusing, ", ")}: " <>
               "give the reference `on_delete: :nilify` (history) or `:delete` (what the account owns)"
    end
  end
end
