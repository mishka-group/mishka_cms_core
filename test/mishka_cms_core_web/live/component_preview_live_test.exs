defmodule MishkaCmsCoreWeb.Test.ComponentPreviewLiveTest do
  @moduledoc """
  Opening a component's preview must not build it. Clicking the eye in the Components table is a
  look, not a use — the modal opens on Overview, which reads the record and never runs it.

  This matters because a component is built by the first thing that renders it. Building the preview
  document on modal open compiled the component as a side effect, and the Pipeline tab then reported
  "Live" about one nothing had ever rendered — the admin's own answer to "has this compiled yet?"
  was made true by the act of asking.

  Driven through the real LiveView rather than the helper functions, because the modal-open path is
  the one that regressed.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @index "/admin/dashboard/runtime/components"

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

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

    n = System.unique_integer([:positive])

    component =
      create_component!(
        site_id: site.id,
        name: "eye-probe-#{n}",
        template: ~s(<b class="eye-probe">rendered</b>),
        examples: [~s(<.component component_name="eye-probe-#{n}" site="#{site.name}" />)],
        precompile: false
      )

    module = Helpers.module_name(component.name, site.name, "Component")

    on_exit(fn ->
      ModuleCompiler.unload(module)
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(create_admin("preview@example.com"))

    {:ok, conn: conn, site: site, component: component, module: module}
  end

  # The record is fetched in a `start_async`, so the modal is not finished until that lands.
  # `render_async/1` awaits it; anything asserted before would be asserting about a modal that had
  # not opened yet, and would pass for the wrong reason.
  defp open_modal(view, component) do
    send(view.pid, {:row_action, "show_preview_modal", %{"id" => component.id}})
    html = render_async(view)

    assert html =~ component.name, "the modal did not finish opening"
    html
  end

  describe "clicking the eye" do
    test "opens the modal without compiling the component", %{
      conn: conn,
      component: component,
      module: module
    } do
      {:ok, view, _html} = live(conn, @index)
      refute Helpers.loaded?(module)

      open_modal(view, component)

      refute Helpers.loaded?(module),
             "opening a preview must not build the component — the Pipeline tab would then call it Live"
    end

    test "and the Pipeline tab still reports it as lazy", %{conn: conn, component: component} do
      {:ok, view, _html} = live(conn, @index)
      open_modal(view, component)

      html = render_click(view, "preview_set_tab", %{"tab" => "pipeline"})

      assert html =~ "compiles on first request"
    end
  end

  describe "opening the Preview tab" do
    test "builds the component and renders its example", %{
      conn: conn,
      component: component,
      module: module
    } do
      {:ok, view, _html} = live(conn, @index)
      open_modal(view, component)
      refute Helpers.loaded?(module)

      # The tab switches at once and the document follows, so the assertion has to await it —
      # which is also the proof that the modal is not frozen while the component compiles.
      switched = render_click(view, "preview_set_tab", %{"tab" => "preview"})

      assert switched =~ "Rendering the component",
             "the tab should open immediately, with a spinner"

      # Compiling a component takes seconds; the default 100ms would fail on the work itself.
      html = render_async(view, 30_000)

      assert Helpers.loaded?(module), "the Preview tab is where a component is built"
      assert html =~ "eye-probe"
    end
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

  defp create_admin(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!("*").id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
