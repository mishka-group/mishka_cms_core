# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.UserDeleteLiveTest do
  @moduledoc """
  Deleting an account from the Users page when it has worked in the editor.

  The table's Delete used to answer with the database's own words — a raw constraint error naming
  `page_builder_events_author_id_fkey` — because the editor's history held the account's id. The row
  goes now and what it made stays; see `MishkaCmsCore.Accounts.UserDestroyTest` for the rows.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.PageBuilderEvent
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @users "/admin/dashboard/account/users"
  @password "Password123!"

  setup %{conn: conn} do
    SiteState.clear()
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
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    page = create_page!(site_id: site.id)
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

    {:ok, conn: conn, site: site, worker: worker, event: event}
  end

  for {who, site?} <- [{"a master", false}, {"a site's admin", true}] do
    test "#{who} deletes an account with editor history, and no error is shown", ctx do
      admin =
        create_user_with_permissions!(["admin:dashboard:*"],
          site_id: if(unquote(site?), do: ctx.site.id),
          password: @password,
          password_confirmation: @password
        )

      {:ok, view, _html} =
        ctx.conn
        |> Map.put(:host, "localhost")
        |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:master_mode, is_nil(admin.site_id))
        |> AshAuthentication.Plug.Helpers.store_in_session(admin)
        |> live(@users)

      render_async(view)

      delete = ~s(button[phx-click="delete"][phx-value-id="#{ctx.worker.id}"])
      assert has_element?(view, delete), "the row has no Delete"

      view |> element(delete) |> render_click()
      render_async(view)

      refute has_element?(view, "#flash-error"), "the delete was answered with an error"

      assert {:ok, nil} = Ash.get(User, ctx.worker.id, actor: admin, error?: false)

      assert %{author_id: nil} =
               PageBuilderEvent
               |> Ash.Query.filter(id == ^ctx.event.id)
               |> Ash.read_one!(tenant: ctx.site.id, actor: admin)
    end
  end
end
