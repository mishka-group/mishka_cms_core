# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.ActivityActorLabelTest do
  @moduledoc """
  Who the activity log names, on the Activity page and in a list page's Logs panel.

  A master reads every actor's email. A site admin reads its own site's people by email and a
  master as "Master", never the master's email or any part of it.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000

  setup do
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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    n = System.unique_integer([:positive])
    colleague = create_admin("log-colleague-#{n}@example.com", site.id)
    master = create_admin("log-master-#{n}@platform.test")

    by_colleague =
      create_layout!(site_id: site.id, name: "log-a-#{n}", path: "/log-a-#{n}")
      |> edit(site, colleague)

    by_master =
      create_layout!(site_id: site.id, name: "log-b-#{n}", path: "/log-b-#{n}")
      |> edit(site, master)

    {:ok,
     site: site,
     colleague: colleague,
     master: master,
     by_colleague: by_colleague,
     by_master: by_master,
     master_conn: conn_for(create_admin("log-reader-#{n}@platform.test")),
     site_conn: conn_for(create_admin("log-site-admin-#{n}@example.com", site.id))}
  end

  describe "the Activity page" do
    test "a master reads every actor's email", ctx do
      view = open_activity(ctx.master_conn)

      assert page_actor(view, ctx.by_colleague) == ["L", to_string(ctx.colleague.email)]
      assert page_actor(view, ctx.by_master) == ["L", to_string(ctx.master.email)]
    end

    test "a site admin reads its own people's emails and Master for a master", ctx do
      view = open_activity(ctx.site_conn)

      assert page_actor(view, ctx.by_colleague) == ["L", to_string(ctx.colleague.email)]
      assert page_actor(view, ctx.by_master) == ["M", "Master"]
      refute_master_email(view, ctx.master)
    end
  end

  describe "a list page's Logs panel" do
    test "a master reads every actor's email", ctx do
      view = open_logs(ctx.master_conn)

      assert feed_actor(view, ctx.by_colleague) == to_string(ctx.colleague.email)
      assert feed_actor(view, ctx.by_master) == to_string(ctx.master.email)
    end

    test "a site admin reads its own people's emails and Master for a master", ctx do
      view = open_logs(ctx.site_conn)

      assert feed_actor(view, ctx.by_colleague) == to_string(ctx.colleague.email)
      assert feed_actor(view, ctx.by_master) == "Master"
      refute_master_email(view, ctx.master)
    end

    test "a live entry by a master the panel has not named yet reads Master to a site admin",
         ctx do
      view = open_logs(ctx.site_conn)
      n = System.unique_integer([:positive])
      newcomer = create_admin("log-newcomer-#{n}@platform.test")

      live_edit =
        create_layout!(site_id: ctx.site.id, name: "log-live-#{n}", path: "/log-live-#{n}")
        |> edit(ctx.site, newcomer)

      render(view)

      assert feed_actor(view, live_edit) == "Master"
      refute_master_email(view, newcomer)
    end
  end

  defp edit(layout, site, actor) do
    layout
    |> Ash.Changeset.for_update(:update, %{description: "edited"},
      tenant: site.id,
      actor: actor,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp open_activity(conn) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/activity")
    render_async(view, @await)
    view
  end

  defp open_logs(conn) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/layouts")
    render_async(view, @await)
    view |> element("#layouts-activity-toggle") |> render_click()
    render_async(view, @await)
    view
  end

  # The avatar's initials and the name beside them.
  defp page_actor(view, layout),
    do: view |> text(~s([id^="activity-actor-pt-#{layout.id}-update-"])) |> String.split()

  defp feed_actor(view, layout),
    do: text(view, ~s([id^="activity-pt-#{layout.id}-update-"][id$="-actor"]))

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp refute_master_email(view, master) do
    email = to_string(master.email)
    html = render(view)

    refute html =~ email
    refute html =~ email |> String.split("@") |> hd()
  end

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp create_admin(email, site_id \\ nil) do
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
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!("*").id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end
end
