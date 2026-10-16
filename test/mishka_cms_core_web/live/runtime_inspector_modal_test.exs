# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, Page, Site, Stylesheet}
  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.PageBuilder.{CodeAccess, Drafts, Interface}

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

  describe "the runtime tables' inspector modal" do
    setup %{site: site} do
      n = unique()

      %{
        pages: [
          %{
            label: "components",
            url: "/admin/dashboard/runtime/components",
            table: "components-table",
            resource: Component,
            gone: "#component-form-modal",
            record: create_component!(site_id: site.id, name: "insp-c-#{n}")
          },
          %{
            label: "layouts",
            url: "/admin/dashboard/runtime/layouts",
            table: "layouts-table",
            resource: Layout,
            gone: "#layout-form-modal",
            record: create_layout!(site_id: site.id, name: "insp-l-#{n}", path: "/insp-l-#{n}")
          },
          %{
            label: "pages",
            url: "/admin/dashboard/runtime/pages",
            table: "pages-table",
            resource: Page,
            gone: "#page-form-modal",
            record: create_page!(site_id: site.id, name: "insp-p-#{n}", path: "/insp-p-#{n}")
          },
          %{
            label: "error pages",
            url: "/admin/dashboard/runtime/error-pages",
            table: "error-pages-table",
            resource: ErrorPage,
            gone: "#error-page-form-modal",
            record:
              create_error_page!(site_id: site.id, name: "insp-e-#{n}", path: "/insp-e-#{n}")
          }
        ]
      }
    end

    test "the eye opens it WITHOUT mounting the Configuration form", %{conn: conn, pages: pages} do
      for %{label: label, url: url, resource: resource, record: record} <- pages do
        {:ok, view, _html} = live(conn, url)

        send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
        html = render_async(view, @await)

        assert html =~ record.name, "#{label}: the modal did not finish opening"

        assert html =~ "Configuration",
               "#{label}: the inspector has no Configuration tab to edit from"

        refute has_element?(view, form_wrapper(resource)),
               "#{label}: a look at a record mounted its edit form, which reads the row all over again"
      end
    end

    test "the Configuration tab mounts the form on first visit", %{conn: conn, pages: pages} do
      for %{label: label, url: url, resource: resource, record: record} <- pages do
        {:ok, view, _html} = live(conn, url)
        send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
        render_async(view, @await)

        render_click(view, "preview_set_tab", %{"tab" => "configuration"})

        assert has_element?(view, form_wrapper(resource)),
               "#{label}: the Configuration tab did not mount the form"
      end
    end

    test "and it stays mounted when you leave the tab", %{conn: conn, pages: pages} do
      for %{label: label, url: url, resource: resource, record: record} <- pages do
        {:ok, view, _html} = live(conn, url)
        send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
        render_async(view, @await)

        render_click(view, "preview_set_tab", %{"tab" => "configuration"})
        render_click(view, "preview_set_tab", %{"tab" => "overview"})

        assert has_element?(view, form_wrapper(resource)),
               "#{label}: a trip to another tab threw away whatever was half-typed in the form"
      end
    end

    test "the pencil opens it straight on Configuration", %{conn: conn, pages: pages} do
      for %{label: label, url: url, table: table, resource: resource} <- pages do
        {:ok, view, _html} = live(conn, url)
        render_async(view, @await)

        view |> element(pencil(table, "edit_preview_modal")) |> render_click()
        render_async(view, @await)

        assert has_element?(view, form_wrapper(resource)),
               "#{label}: the pencil did not reach the Configuration tab"
      end
    end

    # "+ Add" is the same modal on the same tab, with no record behind it — which is the whole reason
    # the standalone create modal could go away.
    test "+ Add opens it on an empty Configuration form", %{conn: conn, pages: pages} do
      for %{label: label, url: url, resource: resource} <- pages do
        {:ok, view, _html} = live(conn, url)

        render_click(view, "preview_add", %{})

        assert has_element?(view, form_wrapper(resource)),
               "#{label}: + Add did not open a form"
      end
    end

    # The form reports its own save; the page turns that into "close the inspector", which is what
    # `close_form_modal/1` used to do for a modal that no longer exists.
    test "a save closes it and unmounts the form", %{conn: conn, pages: pages} do
      for %{label: label, url: url, resource: resource, record: record} <- pages do
        {:ok, view, _html} = live(conn, url)
        send(view.pid, {:row_action, "edit_preview_modal", %{"id" => record.id}})
        render_async(view, @await)
        assert has_element?(view, form_wrapper(resource))

        send(view.pid, {:form_saved, :update, record})
        render(view)

        refute has_element?(view, form_wrapper(resource)),
               "#{label}: the inspector stayed open on the form after a successful save"
      end
    end

    # The Versions tab reads the database twice (a page and a count). Doing that in the LiveView
    # process froze every tab, the close button included; the tab now says it is loading and the
    # answer arrives after.
    test "paging versions draws a spinner first and the page after", %{conn: conn, pages: pages} do
      for %{label: label, url: url, record: record} <- pages do
        {:ok, view, _html} = live(conn, url)
        send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
        render_async(view, @await)

        render_click(view, "preview_set_tab", %{"tab" => "versions"})
        during = render_click(view, "preview_versions_page", %{"page" => "1"})

        assert during =~ "animate-spin",
               "#{label}: the Versions tab blocked instead of reporting itself loading"

        assert render_async(view, @await) =~ "Version History",
               "#{label}: the version page never landed"
      end
    end

    # The master's restore reads the actor its input was built with, and a missing actor is nobody,
    # so the modal builds it with the signed-in master.
    test "a master restores an older version from the Versions tab", %{conn: conn, site: site} do
      layout =
        create_layout!(site_id: site.id, name: "restore-#{unique()}", path: "/r-#{unique()}")

      layout
      |> Ash.Changeset.for_update(:update, %{description: "changed"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      version =
        Layout.Version
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(version_source_id == ^layout.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/layouts")
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => layout.id}})
      render_async(view, @await)

      render_click(view, "preview_set_tab", %{"tab" => "versions"})
      render_click(view, "preview_version_restore", %{"id" => version.id})
      render_async(view, @await)

      assert Ash.get!(Layout, layout.id, tenant: site.id, authorize?: false).description ==
               layout.description
    end

    test "and there is no second form modal left on the page", %{conn: conn, pages: pages} do
      for %{label: label, url: url, gone: gone} <- pages do
        {:ok, view, _html} = live(conn, url)

        refute has_element?(view, gone),
               "#{label}: #{gone} is still rendered — two mounts of one form component collide"
      end
    end
  end

  describe "who wrote a runtime record's versions" do
    setup %{site: site} do
      n = unique()
      colleague = create_admin("layout-colleague-#{n}@example.com", site.id)
      master = create_admin("layout-master-#{n}@platform.test")
      layout = create_layout!(site_id: site.id, name: "authors-#{n}", path: "/authors-#{n}")

      layout = edit_layout(layout, site, colleague, "by colleague")
      by_colleague = newest_layout_version(layout)
      layout = edit_layout(layout, site, master, "by master")
      by_master = newest_layout_version(layout)

      tenant_conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:host, "localhost")
        |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
        |> log_in(create_admin("layout-tenant-#{n}@example.com", site.id))

      {:ok,
       layout: layout,
       colleague: colleague,
       master: master,
       by_colleague: by_colleague,
       by_master: by_master,
       tenant_conn: tenant_conn}
    end

    defp edit_layout(layout, site, actor, description) do
      layout
      |> Ash.Changeset.for_update(:update, %{description: description},
        tenant: site.id,
        actor: actor,
        authorize?: false
      )
      |> Ash.update!()
    end

    defp newest_layout_version(layout) do
      Layout.Version
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(version_source_id == ^layout.id)
      |> Ash.Query.sort(version_inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)
    end

    defp open_layout(conn, layout) do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/layouts")
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => layout.id}})
      render_async(view, @await)
      view
    end

    defp text_of(view, selector),
      do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

    defp version_author(view, version),
      do: view |> text_of("#runtime-preview-versions-#{version.id}-author") |> String.trim()

    test "a master reads every author's email", %{conn: conn, layout: layout} = ctx do
      view = open_layout(conn, layout)

      assert view |> text_of("#runtime-preview-modified-by") |> String.trim() ==
               to_string(ctx.master.email)

      render_click(view, "preview_set_tab", %{"tab" => "versions"})
      render_async(view, @await)

      assert version_author(view, ctx.by_colleague) == to_string(ctx.colleague.email)
      assert version_author(view, ctx.by_master) == to_string(ctx.master.email)
    end

    test "a site admin reads its own people's emails and Master for a master", ctx do
      view = open_layout(ctx.tenant_conn, ctx.layout)
      master_email = to_string(ctx.master.email)

      assert view |> text_of("#runtime-preview-modified-by") |> String.trim() == "Master"

      render_click(view, "preview_set_tab", %{"tab" => "versions"})
      render_async(view, @await)

      assert version_author(view, ctx.by_colleague) == to_string(ctx.colleague.email)
      assert version_author(view, ctx.by_master) == "Master"
      refute render(view) =~ master_email
      refute render(view) =~ master_email |> String.split("@") |> hd()
    end
  end

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

  # THE ✖ ON A BADGE. Before it, the only delete in the strip was the bar's Discard, which is always
  # about the draft in focus — so throwing away any other one meant selecting it first, and the
  # builder's history sidebar was the only screen that could delete a draft where it stood.
  describe "deleting a draft from its badge" do
    setup %{conn: conn, site: site, admin: admin} do
      n = unique()
      page = create_page!(site_id: site.id, name: "insp-d-#{n}", path: "/insp-d-#{n}")

      # Oldest first, so the list — which is newest-first — reads [three, two, one].
      drafts =
        for label <- ~w(one two three) do
          {:ok, draft} =
            Drafts.save_as(
              "page",
              page,
              nil,
              "<div>#{label}</div>",
              admin,
              nil,
              String.capitalize(label),
              nil
            )

          draft
        end

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => page.id}})
      _opened = render_async(view, @await)

      {:ok, view: view, page: page, drafts: drafts, admin: admin}
    end

    defp delete_badge(view, draft),
      do: view |> element("#runtime-preview-draft-delete-#{draft.id}") |> render_click()

    defp labels(page, actor), do: "page" |> Drafts.list(page, actor) |> Enum.map(& &1.label)

    defp selected(view), do: :sys.get_state(view.pid).socket.assigns.preview.draft

    test "the strip opens with a badge and a ✖ for each draft", %{view: view, drafts: drafts} do
      for draft <- drafts do
        assert has_element?(view, "#runtime-preview-draft-#{draft.id}")
        assert has_element?(view, "#runtime-preview-draft-delete-#{draft.id}")
      end
    end

    # THE ROW THE BUTTON IS ON, not the row that happens to be selected. The event used to carry no
    # id at all and the helper read `preview.draft`, so every ✖ on the strip deleted the same draft.
    test "deletes the draft whose badge it sits on", %{view: view, page: page, drafts: drafts} do
      [_three, _two, one] = Enum.reverse(drafts)
      actor = :sys.get_state(view.pid).socket.assigns.current_user

      delete_badge(view, one)

      assert labels(page, actor) == ["Three", "Two"]
      refute has_element?(view, "#runtime-preview-draft-#{one.id}")
    end

    # Deleting something you are not reading is not a change of subject, so the selection stays put.
    test "and leaves the selection alone when it was some other draft", %{
      view: view,
      drafts: drafts
    } do
      [three, _two, one] = Enum.reverse(drafts)
      assert selected(view).id == three.id, "the strip opens on the newest"

      delete_badge(view, one)

      assert selected(view).id == three.id
    end

    # Deleting the one in focus IS a change of subject — there is nothing left to be looking at, so
    # the strip falls back to the newest survivor rather than to nothing.
    test "deleting the selected draft moves the selection on", %{view: view, drafts: drafts} do
      [three, two, _one] = Enum.reverse(drafts)
      assert selected(view).id == three.id

      delete_badge(view, three)

      assert selected(view).id == two.id
    end

    test "it says so, and the count follows", %{view: view, drafts: drafts} do
      [_three, two, _one] = Enum.reverse(drafts)

      html = delete_badge(view, two)

      assert html =~ "Draft discarded."
      assert :sys.get_state(view.pid).socket.assigns.preview.drafts_total == 2
    end

    # A badge someone else deleted a moment ago. The id resolves to nothing, and the answer is a
    # sentence rather than a crash — `preview.draft` would have deleted the selected one instead.
    test "a draft that is already gone reports rather than deleting something else", %{
      view: view,
      page: page,
      drafts: drafts,
      admin: admin
    } do
      [three, _two, one] = Enum.reverse(drafts)
      :ok = Drafts.discard("page", one.id, admin)

      html = render_click(view, "preview_discard_draft", %{"id" => one.id})

      assert html =~ "That draft is no longer there."
      assert selected(view).id == three.id
      assert labels(page, admin) == ["Three", "Two"]
    end

    # The bar's own Discard carries no id, and still means the draft in focus.
    test "the bar's Discard still deletes the selected draft", %{view: view, drafts: drafts} do
      [three, two, _one] = Enum.reverse(drafts)
      assert selected(view).id == three.id

      render_click(view, "preview_discard_draft", %{})

      assert selected(view).id == two.id
      refute has_element?(view, "#runtime-preview-draft-#{three.id}")
    end
  end

  # WHO THE ✖ MAY DELETE. The button carries an id, and an id in a click is a thing a browser can be
  # made to send whatever the page drew — so "the badge was not on my screen" is not the answer;
  # being unable to name another site's row is.
  describe "the badge's delete and tenancy" do
    setup %{site: site, admin: admin} do
      n = unique()
      neighbour = create_site!(name: "neighbour-#{n}", host: "neighbour-#{n}.test", active: true)

      mine = create_page!(site_id: site.id, name: "mine-#{n}", path: "/mine-#{n}")
      theirs = create_page!(site_id: neighbour.id, name: "theirs-#{n}", path: "/theirs-#{n}")

      {:ok, my_draft} =
        Drafts.save_as("page", mine, nil, "<div>mine</div>", admin, nil, "Mine", nil)

      {:ok, their_draft} =
        Drafts.save_as("page", theirs, nil, "<div>theirs</div>", admin, nil, "Theirs", nil)

      tenant =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:host, "localhost")
        |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
        |> log_in(create_admin("tenant-#{n}@example.com", site.id))

      {:ok,
       tenant_conn: tenant,
       mine: mine,
       theirs: theirs,
       my_draft: my_draft,
       their_draft: their_draft,
       admin: admin}
    end

    defp open_modal(conn, page) do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => page.id}})
      _opened = render_async(view, @await)
      view
    end

    defp alive?(draft, actor),
      do:
        match?(
          {:ok, _},
          Ash.get(MishkaCmsCore.Runtime.PageDraft, draft.id,
            actor: actor,
            action: :master_get,
            authorize?: false
          )
        )

    # The fixture is only worth anything if the two actors really are different kinds. A master has
    # no site; a tenant has exactly one, and that attribute is what every scope below reads.
    test "the fixture has one of each kind of actor", %{tenant_conn: conn, mine: mine, site: site} do
      view = open_modal(conn, mine)

      assert :sys.get_state(view.pid).socket.assigns.current_user.site_id == site.id
    end

    # The strip a tenant is looking at is their own site's rows, so the id of somebody else's draft
    # resolves against nothing — the click is refused before Ash is asked, and refused again by the
    # `:destroy` action's tenant scope if it ever were.
    test "a tenant cannot delete another site's draft by naming it", %{
      tenant_conn: conn,
      mine: mine,
      their_draft: their_draft,
      admin: admin
    } do
      view = open_modal(conn, mine)

      html = render_click(view, "preview_discard_draft", %{"id" => their_draft.id})

      assert html =~ "That draft is no longer there."
      assert alive?(their_draft, admin), "another site's draft was deleted from this site's strip"
    end

    # AND CANNOT GET TO THE STRIP THAT HAS IT. The row read is scoped the same way the drafts read
    # is, so the neighbour's page is not a document this actor can open — which is why the refusal
    # above is a second line rather than the only one.
    test "and cannot open the neighbour's record to reach its strip at all", %{
      tenant_conn: conn,
      theirs: theirs,
      their_draft: their_draft
    } do
      view = open_modal(conn, theirs)

      refute has_element?(view, "#runtime-preview-draft-delete-#{their_draft.id}")
      refute render(view) =~ theirs.name
    end

    test "and never had a badge for it in the first place", %{
      tenant_conn: conn,
      mine: mine,
      my_draft: my_draft,
      their_draft: their_draft
    } do
      view = open_modal(conn, mine)

      assert has_element?(view, "#runtime-preview-draft-delete-#{my_draft.id}")
      refute has_element?(view, "#runtime-preview-draft-delete-#{their_draft.id}")
    end

    test "but may delete its own site's", %{
      tenant_conn: conn,
      mine: mine,
      my_draft: my_draft,
      admin: admin
    } do
      view = open_modal(conn, mine)

      view |> element("#runtime-preview-draft-delete-#{my_draft.id}") |> render_click()

      refute alive?(my_draft, admin)
    end

    # A master has no site of its own, so every site's rows are its to read and to delete — which is
    # the whole difference between the two actors on this button.
    test "a master may delete any site's", %{
      conn: conn,
      theirs: theirs,
      their_draft: their_draft,
      admin: admin
    } do
      view = open_modal(conn, theirs)

      assert has_element?(view, "#runtime-preview-draft-delete-#{their_draft.id}")
      view |> element("#runtime-preview-draft-delete-#{their_draft.id}") |> render_click()

      refute alive?(their_draft, admin)
    end
  end

  # THE DUPLICATE BUTTON. A component copied from its own inspector, named after it, and the modal
  # closed on it. The modal is shared by six runtime tables, so what is pinned first is that the
  # button is offered on exactly one of them and only where the copy could be written.
  describe "Duplicate" do
    @duplicate "#runtime-preview-duplicate"
    @helper %{"name" => "shout", "args" => "word", "code" => "String.upcase(word)"}

    defp inspect_record(conn, url, record) do
      {:ok, view, _html} = live(conn, url)
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
      assert render_async(view, @await) =~ record.name, "the modal did not finish opening"
      view
    end

    defp tenant_conn(site, permissions) do
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(create_admin("dup-#{unique()}@example.com", site.id, permissions))
    end

    defp copies_of(source) do
      Component
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(extra["copied_from"] == ^source.id)
      |> Ash.read!(page: [limit: 50], authorize?: false)
      |> Map.fetch!(:results)
    end

    defp flash(view, kind), do: :sys.get_state(view.pid).socket.assigns.flash[kind]

    test "writes a copy named after the component and closes the modal on it", %{conn: conn} do
      source = create_component!(name: "dup-#{unique()}")
      view = inspect_record(conn, "/admin/dashboard/runtime/components", source)

      busy = view |> element(@duplicate) |> render_click() |> LazyHTML.from_fragment()

      assert Enum.count(LazyHTML.query(busy, "#{@duplicate}[disabled]")) == 1,
             "the button did not report the copy in flight"

      render_async(view, @await)

      assert [copy] = copies_of(source)
      assert copy.name =~ ~r/^#{source.name}-copy-[a-z2-7]{4}$/
      assert copy.site_id == nil

      refute has_element?(view, @duplicate), "the modal stayed open on the source"
      assert flash(view, "info") == "Duplicated as “#{copy.name}”"
    end

    test "is offered on no other runtime table's modal", %{conn: conn, site: site} do
      n = unique()

      {:ok, stylesheet} =
        Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{name: "dup-s-#{n}", kind: :theme, content: ":root {}", site_id: nil, active: true},
          authorize?: false
        )
        |> Ash.create()

      others = [
        {"/admin/dashboard/runtime/layouts",
         create_layout!(site_id: site.id, name: "dup-l-#{n}", path: "/dup-l-#{n}")},
        {"/admin/dashboard/runtime/pages",
         create_page!(site_id: site.id, name: "dup-p-#{n}", path: "/dup-p-#{n}")},
        {"/admin/dashboard/runtime/error-pages",
         create_error_page!(site_id: site.id, name: "dup-e-#{n}", path: "/dup-e-#{n}")},
        {"/admin/dashboard/runtime/js-hooks", create_js_hook!(name: "dup-h-#{n}")},
        {"/admin/dashboard/runtime/stylesheets", stylesheet}
      ]

      for {url, record} <- others do
        view = inspect_record(conn, url, record)

        refute has_element?(view, @duplicate),
               "#{url} offers Duplicate, and its page has no handler for it"
      end
    end

    # A site copies only its own rows. A shared component forked into one site is a copy whose
    # examples say `site="Global"` and cannot find it.
    test "a site admin is not offered it on a shared component", %{site: site} do
      conn = tenant_conn(site, ["*"])
      shared = create_component!(name: "dup-shared-#{unique()}")
      own = create_component!(site_id: site.id, name: "dup-own-#{unique()}")

      refute conn
             |> inspect_record("/admin/dashboard/runtime/components", shared)
             |> has_element?(@duplicate)

      assert conn
             |> inspect_record("/admin/dashboard/runtime/components", own)
             |> has_element?(@duplicate)
    end

    # The button not being drawn is not the refusal; a click is something a browser can be made to
    # send whatever the page drew.
    test "and sending the event anyway copies nothing", %{site: site} do
      shared = create_component!(name: "dup-shared-#{unique()}")

      view =
        site
        |> tenant_conn(["*"])
        |> inspect_record("/admin/dashboard/runtime/components", shared)

      render_click(view, "preview_duplicate", %{})

      assert copies_of(shared) == []
      assert flash(view, "error") == "This component cannot be duplicated here."
    end

    # THE COMPONENT SECTION OR CODE WRITES A COMPONENT'S CODE, so either copies one carrying
    # helpers — while the deployment takes author-written Elixir at all.
    for names <- [["admin:dashboard:runtime:component"], ["admin:dashboard:code"]] do
      @names names

      test "#{Enum.join(names, " + ")} is offered it on a component with helpers while Elixir is on",
           %{site: site} do
        on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
        conn = tenant_conn(site, @names)

        coded =
          create_component!(site_id: site.id, name: "dup-coded-#{unique()}", helpers: [@helper])

        assert conn
               |> inspect_record("/admin/dashboard/runtime/components", coded)
               |> has_element?(@duplicate)

        Application.put_env(:mishka_cms_core, :page_code, :off)

        refute conn
               |> inspect_record("/admin/dashboard/runtime/components", coded)
               |> has_element?(@duplicate)
      end
    end

    # A copy is a component written, so it is the component section's, or code's.
    test "a reader without the component section is not offered it", %{site: site} do
      plain = create_component!(site_id: site.id, name: "dup-area-#{unique()}")

      refute site
             |> tenant_conn(["admin:dashboard:runtime:page"])
             |> inspect_record("/admin/dashboard/runtime/components", plain)
             |> has_element?(@duplicate)
    end

    # The deployment switched author-written Elixir off between the modal opening and the click, so
    # the create itself refuses. The reader keeps the source in front of them and is told why.
    test "a refusal keeps the modal open and says why", %{conn: conn} do
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)

      source = create_component!(name: "dup-refused-#{unique()}", helpers: [@helper])
      view = inspect_record(conn, "/admin/dashboard/runtime/components", source)
      assert has_element?(view, @duplicate)

      Application.put_env(:mishka_cms_core, :page_code, :off)
      view |> element(@duplicate) |> render_click()
      render_async(view, @await)

      assert copies_of(source) == []
      assert has_element?(view, "#{@duplicate}:not([disabled])"), "the modal closed on a refusal"
      assert flash(view, "error") == "Could not duplicate: #{CodeAccess.refusal()}"
    end
  end

  # READING IS OPEN, WRITING NEEDS THE SECTION OR CODE. Every dashboard admin reads the runtime lists
  # and this modal, the Code tab included; the controls that write — create, Configuration, Force
  # compile, Duplicate, Publish, Discard, and the Code tab's Edit and New draft — are offered to a
  # holder of the record's section or of code, and the events behind them refuse everyone else.
  describe "what a reader's names offer" do
    setup %{site: site, admin: admin} do
      page =
        create_page!(site_id: site.id, name: "area-p-#{unique()}", path: "/area-p-#{unique()}")

      {:ok, draft} =
        Drafts.save_as("page", page, nil, "<div>draft</div>", admin, nil, "Area", nil)

      {:ok, page: page, draft: draft}
    end

    test "a reader of another section reads the list and the modal, and writes nothing", %{
      site: site,
      page: page
    } do
      conn = tenant_conn(site, ["admin:dashboard:runtime:layout"])
      {:ok, list, _html} = live(conn, "/admin/dashboard/runtime/pages")

      refute has_element?(list, "#add-page-toggle")

      view = inspect_record(conn, "/admin/dashboard/runtime/pages", page)

      refute render(view) =~ "Visual Editor"
      refute has_element?(view, "#runtime-preview-force-compile")
      refute has_element?(view, "#runtime-preview-publish")
      refute has_element?(view, "#runtime-preview-discard")
      refute render(view) =~ ~s(phx-value-tab="configuration")

      render_click(view, "preview_set_tab", %{"tab" => "code"})
      assert has_element?(view, "#runtime-preview-source")
      refute has_element?(view, "#runtime-preview-edit-code")
      refute has_element?(view, "#runtime-preview-new-draft")

      render_click(view, "preview_force_compile", %{})
      assert flash(view, "error") =~ "admin:dashboard:runtime:page"
    end

    # A SITE CANNOT EDIT A SHARED ROW, so the Code tab is not drawn on one; its own rows keep it.
    test "a site admin gets no Code tab on a shared component, and gets it on its own", %{
      site: site
    } do
      conn = tenant_conn(site, ["*"])
      shared = create_component!(name: "code-shared-#{unique()}")
      own = create_component!(site_id: site.id, name: "code-own-#{unique()}")
      code_tab = ~s([phx-value-tab="code"])

      refute conn
             |> inspect_record("/admin/dashboard/runtime/components", shared)
             |> has_element?(code_tab)

      assert conn
             |> inspect_record("/admin/dashboard/runtime/components", own)
             |> has_element?(code_tab)
    end

    # The refusal is the modal's own sentence, naming the area — not the data's later "could not".
    for {event, params} <- [
          {"preview_publish_draft", %{}},
          {"preview_discard_draft", :draft},
          {"preview_version_restore", :version},
          {"preview_add", %{}},
          {"preview_force_compile", %{}},
          {"preview_edit_code", %{}},
          {"preview_new_draft", %{}},
          {"preview_code_submit", %{"source" => "<p>{@x}</p>"}},
          {"preview_code_submit", %{"op" => "save", "source" => "<p>typed</p>"}}
        ] do
      @event event
      @params params

      test "and #{event} #{inspect(params)} refuses them, naming who may", %{
        site: site,
        page: page,
        draft: draft
      } do
        view =
          inspect_record(
            tenant_conn(site, ["admin:dashboard:runtime:layout"]),
            "/admin/dashboard/runtime/pages",
            page
          )

        params =
          case @params do
            :draft -> %{"id" => draft.id}
            :version -> %{"id" => Ecto.UUID.generate()}
            params -> params
          end

        render_click(view, @event, params)

        assert flash(view, "error") =~ "admin:dashboard:runtime:page or admin:dashboard:code"
        refute has_element?(view, "#preview-code-form")
        assert drafts_of(page, site) == [draft.id]

        assert {:ok, _still_there} =
                 Ash.get(MishkaCmsCore.Runtime.PageDraft, draft.id,
                   tenant: site.id,
                   authorize?: false
                 )

        refute has_element?(view, form_wrapper(Page))
      end
    end

    for names <- [["admin:dashboard:runtime:page"], ["admin:dashboard:code"]] do
      @names names

      test "#{Enum.join(names, " + ")} is offered every write, the Code tab's included", %{
        site: site,
        page: page
      } do
        conn = tenant_conn(site, @names)
        {:ok, list, _html} = live(conn, "/admin/dashboard/runtime/pages")

        assert has_element?(list, "#add-page-toggle")

        view = inspect_record(conn, "/admin/dashboard/runtime/pages", page)

        assert has_element?(view, "#runtime-preview-force-compile")
        assert has_element?(view, "#runtime-preview-publish")
        assert has_element?(view, "#runtime-preview-new-draft")
        assert render(view) =~ ~s(phx-value-tab="configuration")

        render_click(view, "preview_set_tab", %{"tab" => "code"})
        view |> element("#runtime-preview-edit-code") |> render_click()
        assert has_element?(view, "#preview-code-form")
      end

      # THE BUILDER OPENS FOR ITS OWN TYPE'S SECTION OR CODE, which `BuilderLive` asks again.
      test "#{Enum.join(names, " + ")} is offered the Visual Editor", %{site: site, page: page} do
        view =
          site
          |> tenant_conn(@names)
          |> inspect_record("/admin/dashboard/runtime/pages", page)

        assert render(view) =~ "Visual Editor"
      end

      # CODE TYPED ON THE CODE TAB IS A PAGE WRITTEN, so the page's own section saves it.
      test "#{Enum.join(names, " + ")} saves a draft from the Code tab", %{site: site, page: page} do
        view =
          site
          |> tenant_conn(@names)
          |> inspect_record("/admin/dashboard/runtime/pages", page)

        render_click(view, "preview_set_tab", %{"tab" => "code"})
        view |> element("#runtime-preview-new-draft") |> render_click()

        view
        |> element("#preview-code-form")
        |> render_submit(%{"op" => "save", "source" => "<p>typed</p>", "label" => "Typed"})

        assert flash(view, "info") =~ "Saved as draft"
        refute has_element?(view, "#preview-code-form")
        assert length(drafts_of(page, site)) == 2
      end
    end

    test "the list offers no write row action without the section", %{site: site, page: page} do
      {:ok, reader, _html} =
        live(
          tenant_conn(site, ["admin:dashboard:runtime:layout"]),
          "/admin/dashboard/runtime/pages"
        )

      {:ok, writer, _html} =
        live(
          tenant_conn(site, ["admin:dashboard:runtime:page"]),
          "/admin/dashboard/runtime/pages"
        )

      assert render_async(reader, @await) =~ page.name
      refute has_element?(reader, pencil("pages-table", "edit_preview_modal"))

      assert render_async(writer, @await) =~ page.name
      assert has_element?(writer, pencil("pages-table", "edit_preview_modal"))
    end
  end

  # EVERY RUNTIME LIST THE SAME WAY: read by an admin of another section, created and edited by a
  # holder of its own or of code.
  describe "each runtime list" do
    setup %{site: site} do
      n = unique()

      sheet =
        Ash.create!(
          Stylesheet,
          %{name: "list-s-#{n}", content: ".a{}", format: :css},
          action: :create,
          tenant: site.id,
          authorize?: false
        )

      %{
        lists: [
          {"/admin/dashboard/runtime/components", "components-table",
           "admin:dashboard:runtime:component", "add-component",
           create_component!(site_id: site.id, name: "list-c-#{n}")},
          {"/admin/dashboard/runtime/layouts", "layouts-table", "admin:dashboard:runtime:layout",
           "add-layout",
           create_layout!(site_id: site.id, name: "list-l-#{n}", path: "/list-l-#{n}")},
          {"/admin/dashboard/runtime/error-pages", "error-pages-table",
           "admin:dashboard:runtime:error_page", "add-error_page",
           create_error_page!(site_id: site.id)},
          {"/admin/dashboard/runtime/js-hooks", "js-hooks-table",
           "admin:dashboard:runtime:js_hook", "add-js_hook",
           create_js_hook!(site_id: site.id, name: "list-h-#{n}")},
          {"/admin/dashboard/runtime/stylesheets", "stylesheets-table",
           "admin:dashboard:runtime:stylesheet", "add-stylesheet", sheet}
        ]
      }
    end

    test "offers its create and its pencil to its own section and to code alone", %{
      site: site,
      lists: lists
    } do
      for {url, table, area, add, record} <- lists do
        {:ok, reader, _html} = live(tenant_conn(site, ["admin:dashboard:runtime:media"]), url)
        render_async(reader, @await)

        assert has_element?(reader, "##{table} [id*='#{record.id}']") or
                 render(reader) =~ record.id,
               "#{url} is not readable by another section"

        refute has_element?(reader, "##{add}"), "#{url} offers create to another section"
        refute has_element?(reader, "##{add}-toggle")
        refute has_element?(reader, pencil(table, "edit_preview_modal")), "#{url} pencil"

        for names <- [[area], ["admin:dashboard:code"]] do
          {:ok, writer, _html} = live(tenant_conn(site, names), url)
          render_async(writer, @await)

          assert has_element?(writer, "##{add}") or has_element?(writer, "##{add}-toggle"),
                 "#{url} does not offer create to #{inspect(names)}"

          assert has_element?(writer, pencil(table, "edit_preview_modal")),
                 "#{url} offers #{inspect(names)} no pencil"
        end
      end
    end

    # EVERY WRITE A ROW OFFERS, not only its pencil: Delete on the list, and Restore and Delete
    # permanently on its archive.
    test "offers a row's Delete, Restore and Delete permanently to its own section and to code alone",
         %{site: site, lists: lists} do
      n = unique()
      page = create_page!(site_id: site.id, name: "list-p-#{n}", path: "/list-p-#{n}")

      lists = [
        {"/admin/dashboard/runtime/pages", "pages-table", "admin:dashboard:runtime:page",
         "add-page", page}
        | lists
      ]

      reader = tenant_conn(site, ["admin:dashboard:runtime:media"])
      coder = tenant_conn(site, ["admin:dashboard:code"])

      holders = fn area ->
        [
          {reader, "another section", false},
          {tenant_conn(site, [area]), area, true},
          {coder, "code", true}
        ]
      end

      for {url, table, area, _add, record} <- lists, {conn, who, offered?} <- holders.(area) do
        {:ok, view, _html} = live(conn, url)
        render_async(view, @await)

        assert has_element?(view, row(table, record)), "#{url} draws the row"

        assert has_element?(view, row(table, record, ~s(button[phx-click="delete"]))) == offered?,
               "#{url} Delete offered to #{who}? #{offered?}"
      end

      for {_url, _table, _area, _add, record} <- lists do
        record
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()
      end

      for {url, table, area, _add, record} <- lists, {conn, who, offered?} <- holders.(area) do
        {:ok, view, _html} = live(conn, url)
        render_async(view, @await)

        view
        |> element(~s(button[phx-click="archive_filter"][phx-value-status="archived"]))
        |> render_click()

        render_async(view, @await)
        assert has_element?(view, row(table, record)), "#{url} draws the archived row"

        for event <- ~w(unarchive permanent_destroy) do
          assert has_element?(
                   view,
                   row(table, record, ~s(button[phx-value-event="#{event}"]))
                 ) == offered?,
                 "#{url} #{event} offered to #{who}? #{offered?}"
        end
      end
    end

    test "offers a page's Add translation to the page section and to code alone", %{site: site} do
      n = unique()
      page = create_page!(site_id: site.id, name: "list-t-#{n}", path: "/list-t-#{n}")
      translate = ~s(button[phx-value-event="add_translation"])

      for {permissions, offered?} <- [
            {["admin:dashboard:runtime:layout"], false},
            {["admin:dashboard:runtime:page"], true},
            {["admin:dashboard:code"], true}
          ] do
        {:ok, view, _html} =
          live(tenant_conn(site, permissions), "/admin/dashboard/runtime/pages")

        render_async(view, @await)

        assert has_element?(view, row("pages-table", page, "button"))
        assert has_element?(view, row("pages-table", page, translate)) == offered?
      end
    end
  end

  # A JS HOOK, A STYLESHEET, A COMPONENT HAVE NO DRAFTS. Their Code tab only read, and editing the
  # source meant leaving it for Configuration; it now offers the Edit the Page's does, saved straight
  # to the record by the update the Configuration form runs.
  describe "editing a draftless record's source on the Code tab" do
    defp open_code(conn, path, record) do
      {:ok, view, _html} = live(conn, path)
      send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
      render_async(view, @await)
      render_click(view, "preview_set_tab", %{"tab" => "code"})
      view
    end

    test "a JS hook's source is edited and saved in place", %{conn: conn, site: site} do
      hook =
        create_js_hook!(
          site_id: site.id,
          name: "inline-#{unique()}",
          content: "export default { mounted() {} };"
        )

      view = open_code(conn, "/admin/dashboard/runtime/js-hooks", hook)

      assert has_element?(view, "#runtime-preview-edit-code")
      view |> element("#runtime-preview-edit-code") |> render_click()

      assert has_element?(view, "#preview-code-save-form")
      refute has_element?(view, "#preview-code-form"), "a JS hook has no draft to save into"

      edited = "export default { mounted() { this.el.dataset.inline = 'yes'; } };"
      view |> form("#preview-code-save-form", %{source: edited}) |> render_submit()
      render_async(view, @await)

      assert Ash.get!(MishkaCmsCore.Runtime.JsHook, hook.id, tenant: site.id, authorize?: false).content ==
               edited

      assert has_element?(view, "#runtime-preview-source", "inline = 'yes'")
      refute has_element?(view, "#preview-code-save-form")
    end

    test "a component's template is saved, and one that does not compile is refused in the editor",
         %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "inline-c-#{unique()}",
          template: ~s(<b class="inline-probe">before</b>)
        )

      view = open_code(conn, "/admin/dashboard/runtime/components", component)
      view |> element("#runtime-preview-edit-code") |> render_click()

      view |> form("#preview-code-save-form", %{source: "<b>{</b>"}) |> render_submit()

      assert has_element?(view, "#preview-code-save-form"), "a refusal must leave the edit open"
      assert Ash.reload!(component, authorize?: false).template =~ "before"

      view
      |> form("#preview-code-save-form", %{source: ~s(<b class="inline-probe">after</b>)})
      |> render_submit()

      render_async(view, @await)
      assert Ash.reload!(component, authorize?: false).template =~ "after"
    end
  end

  defp row(table, record), do: ~s(##{table} [id$="-#{record.id}"])
  defp row(table, record, inner), do: row(table, record) <> " " <> inner

  defp drafts_of(page, site) do
    MishkaCmsCore.Runtime.PageDraft
    |> Ash.Query.filter(source_page_id == ^page.id)
    |> Ash.read!(tenant: site.id, authorize?: false, page: false)
    |> Enum.map(& &1.id)
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
