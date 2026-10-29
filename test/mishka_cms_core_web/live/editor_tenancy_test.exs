# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.EditorTenancyTest do
  @moduledoc """
  Who may open which document in the editor — asked once for every section, and both ways round.

  The builder is one address with a resource id in it, so "which documents exist" and "which
  documents are mine" are not the same question, and only the first of them is answered by a route.
  Three rules are asserted here, on all four sections:

    * a tenant admin opens their own site's document, and nothing else on any other site;
    * a **global** layout or component — one with no `site_id`, which every site renders and places —
      is a master's to edit. The tenant is told that, in those words, rather than being let in and
      refused at Publish an hour later. `Layout` and `Component` say the same thing from inside their
      own `:update` validation; this is that rule arriving before the work rather than after it;
    * a master opens any of them, on any site, global included.

  And the canvas is asked separately, because it is a second LiveView addressed by the editing
  session's TOKEN rather than by the document — so it inherits none of the above. A token is
  unguessable and also shareable, which makes it a secret and not an authorization.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @body ~s(<section id="root"><h1>Title</h1></section>)
  @layout_body ~s(<body class="page"><main>{@inner_content}</main></body>)

  @sections [:page, :layout, :error_page, :component]
  @globals [:layout, :component]

  setup %{conn: conn} do
    SiteState.clear()

    mine = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    theirs = create_site!(name: "neighbour", host: "neighbour.test", active: true)

    for site <- [mine, theirs] do
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })
    end

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn = on_host(conn)

    {:ok,
     conn: log_in(conn, admin!("boss@example.com")),
     tenant_conn:
       log_in(on_host(Phoenix.ConnTest.build_conn()), admin!("tenant@example.com", mine.id)),
     mine: mine,
     theirs: theirs}
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

  defp record!(:page, site_id), do: create_page!(site_id: site_id, template: @body)
  defp record!(:layout, site_id), do: create_layout!(site_id: site_id, template: @layout_body)

  defp record!(:error_page, site_id),
    do:
      create_error_page!(
        site_id: site_id,
        error_pages: [%{"status" => 404, "template" => @body, "layout" => %{}}]
      )

  defp record!(:component, site_id),
    do:
      create_component!(
        site_id: site_id,
        name: "tenancy-#{System.unique_integer([:positive])}",
        template: @body
      )

  defp scoped_component!(site, tag) do
    component =
      create_component!(
        site_id: site.id,
        name: "scoped-#{tag}-#{System.unique_integer([:positive])}",
        template: ~s(<div class="probe-#{tag}">#{tag}</div>)
      )

    module = Helpers.module_name(component.name, site.name, "Component")

    on_exit(fn -> ModuleCompiler.unload(module) end)
    component
  end

  defp path(:error_page), do: "error-page"
  defp path(section), do: to_string(section)

  defp list_path(:page), do: "/admin/dashboard/runtime/pages"
  defp list_path(:layout), do: "/admin/dashboard/runtime/layouts"
  defp list_path(:error_page), do: "/admin/dashboard/runtime/error-pages"
  defp list_path(:component), do: "/admin/dashboard/runtime/components"

  defp open(conn, section, record),
    do: live(conn, "/admin/dashboard/runtime/builder/#{path(section)}/#{record.id}")

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token

  for section <- @sections do
    describe "#{section}: a tenant's own site" do
      test "opens in the editor", %{tenant_conn: conn, mine: mine} do
        record = record!(unquote(section), mine.id)

        assert {:ok, view, _html} = open(conn, unquote(section), record)
        assert has_element?(view, "#pb-root")
      end
    end

    describe "#{section}: another site's document" do
      test "is turned away as though it were not there", %{tenant_conn: conn, theirs: theirs} do
        record = record!(unquote(section), theirs.id)

        assert {:error, {:redirect, %{to: to, flash: flash}}} =
                 open(conn, unquote(section), record)

        assert to == list_path(unquote(section))
        assert flash["error"] =~ "could not be opened"

        refute flash["error"] =~ "shared",
               "a document belonging to another site must not be described as a shared one"
      end
    end

    describe "#{section}: a master" do
      test "opens any site's document", %{conn: conn, theirs: theirs} do
        record = record!(unquote(section), theirs.id)

        assert {:ok, view, _html} = open(conn, unquote(section), record)
        assert has_element?(view, "#pb-root")
      end
    end
  end

  for section <- @globals do
    describe "#{section}: a global document" do
      test "is refused to a tenant, in words that say why", %{tenant_conn: conn} do
        record = record!(unquote(section), nil)

        assert {:error, {:redirect, %{to: to, flash: flash}}} =
                 open(conn, unquote(section), record)

        assert to == list_path(unquote(section))
        assert flash["error"] =~ "shared with every site"
        assert flash["error"] =~ "master"

        refute flash["error"] =~ "deleted",
               "the document is there — telling the reader it may be gone is a lie"
      end

      test "opens for a master", %{conn: conn} do
        record = record!(unquote(section), nil)

        assert {:ok, view, _html} = open(conn, unquote(section), record)
        assert has_element?(view, "#pb-root")
      end
    end
  end

  # The row's own way in. `BuilderLive` refusing the address is the rule; this is the same rule
  # arriving one click earlier, so a tenant is never offered a button that bounces them.
  describe "the details modal" do
    for section <- @globals do
      test "offers no Visual Editor on a global #{section} to a tenant", %{tenant_conn: conn} do
        record = record!(unquote(section), nil)

        {:ok, view, _html} = live(conn, list_path(unquote(section)))
        send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
        html = render_async(view, 5_000)

        assert html =~ record.name, "the modal did not finish opening"
        refute html =~ "Visual Editor"

        refute html =~ "runtime/builder/#{path(unquote(section))}/#{record.id}",
               "the shared row still linked into the editor"
      end

      test "and offers it on the same #{section} to a master", %{conn: conn} do
        record = record!(unquote(section), nil)

        {:ok, view, _html} = live(conn, list_path(unquote(section)))
        send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
        html = render_async(view, 5_000)

        assert html =~ "Visual Editor"
        assert html =~ "runtime/builder/#{path(unquote(section))}/#{record.id}"
      end
    end

    test "and still offers it on a tenant's own layout", %{tenant_conn: conn, mine: mine} do
      record = record!(:layout, mine.id)

      {:ok, view, _html} = live(conn, list_path(:layout))
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
      html = render_async(view, 5_000)

      assert html =~ "Visual Editor"
    end
  end

  describe "the canvas" do
    test "a tenant may not mount a session opened on another site", %{
      conn: conn,
      tenant_conn: tenant_conn,
      theirs: theirs
    } do
      {:ok, view, _html} = open(conn, :page, record!(:page, theirs.id))

      {:ok, _canvas, html} =
        live(tenant_conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "belongs to another site"
    end

    # THE FRAME DRAWS WHAT THE PUBLISHED PAGE WILL. A component another site owns reads as that
    # site, so drawing one here showed a tenant another site's markup and rows from their own page —
    # the same leak the published page is refused, one screen earlier.
    test "draws its own site's components and not another site's", %{
      tenant_conn: conn,
      mine: mine,
      theirs: theirs
    } do
      own = scoped_component!(mine, "own")
      foreign = scoped_component!(theirs, "foreign")

      page =
        create_page!(
          site_id: mine.id,
          template: """
          <section id="root">
            <.component component_name="#{own.name}" site="#{mine.name}" />
            <.component component_name="#{foreign.name}" site="#{theirs.name}" />
          </section>
          """
        )

      {:ok, view, _html} = open(conn, :page, page)

      # Refused before it is built: the frame reads the attributes a component declares before it
      # draws it, and that read must not load another site's module on a tenant's say-so.
      foreign_module = Helpers.module_name(foreign.name, theirs.name, "Component")

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "probe-own", "the page's own component is missing from the frame"
      refute html =~ "probe-foreign", "another site's component was drawn in the frame"
      refute Helpers.loaded?(foreign_module), "another site's component was built by the frame"
    end
  end
end
