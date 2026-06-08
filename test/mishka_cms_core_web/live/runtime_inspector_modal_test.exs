defmodule MishkaCmsCoreWeb.Test.RuntimeInspectorModalTest do
  @moduledoc """
  The one modal every runtime table opens, driven through the real page.

  Two things are being pinned here, and both are about what a click costs.

  **A look is not an edit.** Clicking the eye used to be the only way into the inspector, and editing
  meant a second, separate `<resource>-form-modal` sitting on the same page. That is one form
  component too many: `MishkaGervaz.Form.Web.Live` reads the row and every relation's options the
  moment it mounts, so the page paid for an edit nobody had asked for — and the two mounts of the
  same component collided on their DOM id. The form now lives on the modal's Configuration tab and
  mounts on the FIRST visit to it, which is why every test below checks the form's absence before it
  checks its presence.

  **The pencil has to reach it.** For Component/Layout/Page/ErrorPage the pencil was a
  `type :edit` row action, which sends `{:edit_modal, id}` to the parent LiveView — a message none of
  those four pages had a clause for. The clicks below go through the rendered button rather than a
  hand-sent message, so the resource's own DSL is part of what is under test.

  See `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers` and
  `MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal`.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, Page, Site}
  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.PageBuilder.Interface

  require Ash.Query

  @password "Password123!"

  # The modal's open load is a record read plus its drafts and a page of versions; the 100ms default
  # is a statement about nothing.
  @await 5_000

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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    admin = create_admin("inspector-#{unique()}@example.com")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(admin)

    {:ok, conn: conn, site: site, admin: admin}
  end

  # The form component's own root element, which only exists once it has been mounted. Its loading
  # skeleton lives inside this same wrapper, so the wrapper is present the moment the component is —
  # exactly the question these tests ask.
  defp form_wrapper(resource),
    do: "#" <> MishkaGervaz.Resource.Info.Form.component_id(resource) <> "-form-wrapper"

  defp form_selector(resource),
    do: "#" <> MishkaGervaz.Resource.Info.Form.component_id(resource) <> "-form"

  # Each declared attribute's options by name, whichever key shape the row is in.
  defp options(component), do: Map.new(Interface.attrs(component), &{&1["name"], &1["opts"]})

  # The pencil, as the table actually renders it: an `:event` row action is a button carrying its
  # event name, so clicking this drives resource DSL → table component → parent LiveView.
  defp pencil(table, event), do: ~s(##{table} button[phx-value-event="#{event}"])

  describe "the sites table's details modal" do
    test "the eye opens it without mounting the form, and the tab mounts it", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/sites")

      send(view.pid, {:row_action, "show_site_modal", %{"id" => site.id}})
      render_async(view, @await)

      refute has_element?(view, form_wrapper(Site)),
             "a look at a site mounted its edit form"

      render_click(view, "site_modal_set_tab", %{"tab" => "configuration"})

      assert has_element?(view, form_wrapper(Site)),
             "the Configuration tab did not mount the site form"
    end

    test "the pencil opens it straight on Configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/sites")
      render_async(view, @await)

      view |> element(pencil("sites-table", "edit_site_modal")) |> render_click()
      render_async(view, @await)

      assert has_element?(view, form_wrapper(Site)),
             "the pencil did not reach the site's Configuration tab"
    end
  end

  describe "saving a component's Configuration form" do
    # A RENAME IS NOT A REDECLARATION. Each attribute's options are drawn as three controls —
    # Required, Default, Doc — and a text box shows `nil` as nothing at all, while `values` gets no
    # control. Saved as the form sent them back, a rename of `chelekom-button` declared `attr :type`
    # with no default, and the first page that left `type` unset raised `key :type not found`.
    test "a renamed chelekom-button still renders without a type", %{conn: conn} do
      source =
        create_component!(
          name: "chelekom-button-copy-#{unique()}",
          template: ~s|<button type={@type} class={@size}>Send</button>|,
          attrs: Enum.filter(every_option_shape(), &(&1["name"] in ["type", "size"])),
          slots: [],
          active: true,
          precompile: false
        )

      renamed = "acme-go-#{unique()}"
      forget_component_on_exit(renamed)
      save_through_the_form(conn, %{"name" => renamed})

      assert Ash.get!(Component, source.id, authorize?: false).name == renamed,
             "the save did not go through"

      assert render_by_name(renamed) =~ ~s(<button class="large">Send</button>)
    end

    # What is kept is what the author did not touch. A default they empty is gone and one they type
    # is theirs — the options beside it stay either way.
    test "a default the author clears is cleared, and one they type replaces nil", %{conn: conn} do
      source =
        create_component!(
          name: "typed-#{unique()}",
          template: ~s|<button type={@type} class={@size}>Send</button>|,
          attrs: Enum.filter(every_option_shape(), &(&1["name"] in ["type", "size"])),
          slots: [],
          active: true,
          precompile: false
        )

      save_through_the_form(conn, %{
        "attrs" => %{
          "0" => %{"opts" => %{"default" => "submit"}},
          "1" => %{"opts" => %{"default" => ""}}
        }
      })

      assert options(Ash.get!(Component, source.id, authorize?: false)) == %{
               "type" => %{
                 "default" => "submit",
                 "doc" => "Specifies the type of the element",
                 "values" => ["button", "submit", "reset", nil]
               },
               "size" => %{"values" => ["small", "large"]}
             }
    end

    # The same loss, for every option shape the kit ships: `false`, `true`, `""` and `[]` come back
    # blank and were dropped, `0` and `1.0` came back as the strings Phoenix refuses as an integer's
    # and a float's default, and `editor` and `default_struct` were never sent at all.
    test "a rename keeps every option the form does not show, and the component still renders", %{
      conn: conn
    } do
      source =
        create_component!(
          name: "shapes-#{unique()}",
          template: every_option_template(),
          attrs: every_option_shape(),
          slots: [],
          active: true,
          precompile: false
        )

      renamed = "acme-go-#{unique()}"
      forget_component_on_exit(renamed)
      save_through_the_form(conn, %{"name" => renamed})

      stored = Ash.get!(Component, source.id, authorize?: false)
      assert stored.name == renamed, "the save did not go through"
      assert options(stored) == options(source)

      html = render_by_name(renamed)

      assert html =~ ~s(class="large ")
      assert html =~ ~s(data-full="false")
      assert html =~ ~s(data-pill="true")
      assert html =~ ~s(data-step="0")
      assert html =~ ~s(data-precision="1.0")
      assert html =~ ~s(data-items="0")
      refute html =~ ~s(type="), "an unset type is drawn as no attribute at all"
    end

    # The pencil on the table's one row, then the form's own submit with `changes` typed in — the
    # browser sends every other control as it was drawn.
    defp save_through_the_form(conn, changes) do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/components")
      render_async(view, @await)
      view |> element(pencil("components-table", "edit_preview_modal")) |> render_click()
      render_async(view, @await)

      view
      |> form(form_selector(Component), %{"form" => changes})
      |> render_submit()
    end

    # A page's `<.component component_name="…" site="Global"/>`, passing nothing else.
    defp render_by_name(name) do
      %{component_name: name, site: nil}
      |> LiveViewHelpers.component()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end
  end

  describe "Force compile" do
    # A lazy record is built by the first request that needs it, which is a poor way to find out its
    # template no longer compiles: the person who broke it is not the person who discovers it. The
    # button is the author's way to ask now — and it is a button, not something the modal does on
    # open, because what it produces is code held in RAM for the life of the node.
    test "builds a lazy component's module, which merely opening the modal does not", %{
      conn: conn,
      site: site
    } do
      n = unique()

      component =
        create_component!(
          site_id: site.id,
          name: "force-c-#{n}",
          template: ~s(<b class="force-probe">built</b>),
          precompile: false
        )

      module = Helpers.module_name(component.name, site.name, "Component")
      on_exit(fn -> ModuleCompiler.unload(module) end)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/components")
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => component.id}})
      html = render_async(view, @await)

      refute Helpers.loaded?(module), "opening the modal must not compile anything"

      assert html =~ "Force compile",
             "the action is not offered for an active, module-backed record"

      render_click(view, "preview_force_compile", %{})
      render_async(view, 30_000)

      assert Helpers.loaded?(module),
             "Force compile left the module unbuilt — a lazy record cannot be checked before a visitor finds it"
    end

    test "and a lazy layout's, whose preview otherwise never compiles it", %{
      conn: conn,
      site: site
    } do
      n = unique()

      layout =
        create_layout!(
          site_id: site.id,
          name: "force-l-#{n}",
          path: "/force-l-#{n}",
          precompile: false
        )

      module = Helpers.module_name(layout.id, site.name, "Layout")
      on_exit(fn -> ModuleCompiler.unload(module) end)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/layouts")
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => layout.id}})
      render_async(view, @await)

      refute Helpers.loaded?(module)

      render_click(view, "preview_force_compile", %{})
      render_async(view, 30_000)

      assert Helpers.loaded?(module)
    end

    # The button names a real cost, so it must not be offered where it cannot act. An inactive record
    # is read back by the compile worker through the same query the runtime uses, which for a
    # Component filters on `active` — so the compile would report `:not_found` and nothing else.
    test "is not offered for an inactive record", %{conn: conn, site: site} do
      component = create_component!(site_id: site.id, name: "off-#{unique()}", active: false)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/components")
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => component.id}})
      html = render_async(view, @await)

      refute html =~ "Force compile",
             "the action is offered for a record whose compile can only fail"
    end
  end

  defp unique, do: System.unique_integer([:positive])

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

  defp create_admin(email, site_id \\ nil, permissions \\ ["*"]) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    for permission <- permissions do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
      |> Ash.create!(authorize?: false)
    end

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
