# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.DeletedAuthorTest do
  @moduledoc """
  What the editor says about work whose author's account is gone.

  Deleting an account releases it from the history it made (`on_delete: :nilify`), so the sheet's
  rows and a review thread arrive with no author. A person's work reads as a deleted user: "System"
  is for what nobody did, and a deleted account's work is not that.
  """
  use MishkaCmsCore.BuilderLiveCase

  alias MishkaCmsCore.Runtime.{PageBuilderEvent, PageComment}

  setup %{site: site, page: page} do
    worker = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)
    master = create_user_with_permissions!(["*"])

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

    note =
      PageComment
      |> Ash.Changeset.for_create(
        :create,
        %{body: "a note from somebody", type: :information, section: :page, document_id: page.id},
        tenant: site.id,
        actor: worker
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:resolve, %{}, tenant: site.id, actor: worker)
      |> Ash.update!()

    %{worker: worker, master: master, event: event, note: note}
  end

  defp delete!(user, master), do: Ash.destroy!(user, action: :table_destroy, actor: master)

  test "the history sheet names a deleted account's change as a deleted user", %{
    conn: conn,
    page: page,
    worker: worker,
    master: master,
    event: event
  } do
    {:ok, view, _html} = open_builder(conn, page)
    render_click(view, "open_sheet", %{"sheet" => "history"})
    render_async(view)
    assert has_element?(view, "#pb-history-author-#{event.id}", worker.email |> to_string())

    delete!(worker, master)

    {:ok, view, _html} = open_builder(conn, page)
    render_click(view, "open_sheet", %{"sheet" => "history"})
    render_async(view)

    assert has_element?(view, "#pb-history-author-#{event.id}", "Deleted user")
    refute has_element?(view, "#pb-history-author-#{event.id}", "System")
  end

  test "a review thread names a deleted account as the writer and as who closed it", %{
    conn: conn,
    page: page,
    worker: worker,
    master: master,
    note: note
  } do
    delete!(worker, master)

    {:ok, view, _html} = open_builder(conn, page)
    render_click(view, "open_sheet", %{"sheet" => "review"})
    html = render_async(view)

    assert html =~ "a note from somebody"
    assert has_element?(view, "#pb-comment-resolver-#{note.id}", "Deleted user")
    assert html =~ "Deleted user"
  end
end
