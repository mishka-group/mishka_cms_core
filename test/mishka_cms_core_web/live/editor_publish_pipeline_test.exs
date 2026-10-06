defmodule MishkaCmsCoreWeb.Test.EditorPublishPipelineTest do
  @moduledoc """
  What happens to the site AFTER Publish is pressed, for each of the four sections.

  Everything else the editor does is answered inside the editor: the tree changed, the record was
  written, the flash said so. None of that is what an author means by publishing. They mean the page
  a visitor loads is the one they just made — and between the record and the visitor there is a
  compile: `Changes.SendToOban` enqueues a `RuntimeCompilerWorker` job per written row, and the
  module that job builds is what actually renders.

  That seam had no test from the editor's side at all, and it is the one that fails quietly:
  `MishkaCmsCore.Runtime.States.CompileFailureState` records the reason and the site goes on serving
  the module it already had. So a publish that enqueues nothing looks exactly like a publish that
  worked, for as long as nobody reloads the page.

  `SendToOban` is a no-op while `:env_test?` is true — which is how the rest of the suite avoids
  compiling on every fixture — so these flip it off, the way
  `MishkaCmsCore.Runtime.RuntimePipelineTest` does.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  @moduletag :integration

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  require Ash.Query

  @password "Password123!"
  @body ~s(<section id="root"><h1>Title</h1><p>Body text</p></section>)
  @layout_body ~s(<body class="page"><main>{@inner_content}</main><h1>Title</h1><p>Body text</p></body>)

  @sections [:page, :layout, :error_page, :component]

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:mishka_cms_core, :env_test?, false)

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
      Application.put_env(:mishka_cms_core, :env_test?, true)
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, admin!("boss@example.com")), site: site}
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

  defp admin!(email) do
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

  defp record!(:page, site), do: create_page!(site_id: site.id, template: @body)
  defp record!(:layout, site), do: create_layout!(site_id: site.id, template: @layout_body)

  defp record!(:error_page, site),
    do:
      create_error_page!(
        site_id: site.id,
        error_pages: [%{"status" => 404, "template" => @body, "layout" => %{}}]
      )

  defp record!(:component, site),
    do:
      create_component!(
        site_id: site.id,
        name: "pipeline-#{System.unique_integer([:positive])}",
        template: @body
      )

  defp path(:error_page), do: "error-page"
  defp path(section), do: to_string(section)

  defp resource(:page), do: MishkaCmsCore.Runtime.Page
  defp resource(:layout), do: MishkaCmsCore.Runtime.Layout
  defp resource(:error_page), do: MishkaCmsCore.Runtime.ErrorPage
  defp resource(:component), do: MishkaCmsCore.Runtime.Component

  defp open(conn, section, record) do
    {:ok, view, _html} =
      live(conn, "/admin/dashboard/runtime/builder/#{path(section)}/#{record.id}")

    view
  end

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token
  defp editor(view), do: elem(EditorSession.fetch(token(view)), 1)

  defp node_with_tag(view, tag) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> MishkaCmsCore.Runtime.PageBuilder.Tree.walk()
    |> Enum.find(&(&1.tag == tag))
  end

  defp publish!(view) do
    render_click(view, "set_stage", %{"stage" => "published"})
    render_click(view, "apply_stage", %{})
  end

  defp compile_jobs_for(id) do
    RuntimeCompilerWorker
    |> then(&all_enqueued(worker: &1))
    |> Enum.filter(&(get_in(&1.args, ["data", "id"]) == id))
  end

  # THE FIXTURE'S OWN CREATE ENQUEUED ONE, and a create and an update of the same row share a
  # `meta.slug` and coalesce into it (see `MishkaCmsCore.Runtime.RuntimePipelineTest`). So counting
  # before and after a publish counts the same job twice and passes whether or not the publish asked
  # for anything. The queue is emptied first instead, and what appears is the publish's alone.
  defp clear_jobs! do
    @repo.delete_all(Oban.Job)
    :ok
  end

  defp edit!(view) do
    render_click(view, "op", %{
      "kind" => "set_text",
      "node_id" => hd(node_with_tag(view, "h1").children),
      "text" => "Published title"
    })
  end

  for section <- @sections do
    describe "publishing a #{section}" do
      test "asks the runtime to rebuild the module a visitor renders", %{conn: conn, site: site} do
        record = record!(unquote(section), site)
        view = open(conn, unquote(section), record)
        clear_jobs!()

        edit!(view)
        publish!(view)

        assert [job] = compile_jobs_for(record.id),
               "publishing wrote the row and asked nothing to rebuild it"

        assert job.args["resource"] == inspect(resource(unquote(section))),
               "the job named a different resource than the one that was published"
      end

      # PUBLISHED IS IN FRONT OF VISITORS. A document named in the editor arrives inactive; the
      # publish is what puts it live — and the rebuild it asks for carries that, so the runtime
      # builds the module instead of unloading it.
      test "switches on a document that arrived inactive", %{conn: conn, site: site} do
        record =
          unquote(section)
          |> record!(site)
          |> Ash.Changeset.for_update(:master_update, %{active: false}, authorize?: false)
          |> Ash.update!()

        view = open(conn, unquote(section), record)
        clear_jobs!()

        edit!(view)
        publish!(view)

        assert Ash.get!(resource(unquote(section)), record.id, tenant: site.id, authorize?: false).active

        assert [job] = compile_jobs_for(record.id)
        assert job.args["data"]["active"] == true
      end
    end
  end

  # A REFUSED PUBLISH MUST ASK FOR NOTHING. The gate and the queue are two different steps, and a
  # rebuild queued for a row that was never written is a rebuild of the version already there —
  # which succeeds, and tells the author their refused change went out.
  #
  # `<div :foo={@a}>` is a special attribute that does not exist: `Tree.parse/1` takes it, so does
  # `Serializer.to_heex/1`, and the engine that has to build the module does not. A PAGE cannot be
  # seeded this way at all — `Validations.PageCodeCompiles` refuses it at the action boundary — which
  # is why the three sections without that validation are the ones asked here.
  describe "a publish the editor refuses" do
    @uncompilable ~s(<section id="root"><h1>Title</h1><div :foo={@a}>x</div></section>)
    @uncompilable_layout ~s(<body class="page"><main>{@inner_content}</main><h1>Title</h1><div :foo={@a}>x</div></body>)

    # SEEDED PAST THE ACTIONS. `Validations.TemplateCompiles` shut the front door on all four
    # resources, so a row like this can no longer be created — which is the point of it, and which
    # leaves only the rows written before it existed. Those are the documents the editor's own gate
    # is for, and `Ash.Seed.seed!/2` writing through the data layer is the only honest way to make
    # one. It skips the CHANGES too, hence `preview_token` under its NOT NULL column.
    defp broken!(section, site) do
      Ash.Seed.seed!(
        resource(section),
        Map.merge(
          %{
            preview_token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
            site_id: site.id
          },
          broken_attrs(section)
        )
      )
    end

    defp broken_attrs(:layout),
      do: %{
        name: "broken-layout-#{System.unique_integer([:positive])}",
        path: "/broken-#{System.unique_integer([:positive])}",
        template: @uncompilable_layout
      }

    defp broken_attrs(:error_page),
      do: %{
        name: "broken-error-#{System.unique_integer([:positive])}",
        path: "/broken-#{System.unique_integer([:positive])}",
        error_pages: [%{"status" => 404, "template" => @uncompilable, "layout" => %{}}]
      }

    defp broken_attrs(:component),
      do: %{
        name: "broken-pipeline-#{System.unique_integer([:positive])}",
        template: @uncompilable
      }

    for section <- [:layout, :error_page, :component] do
      test "queues no rebuild for a #{section}", %{conn: conn, site: site} do
        record = broken!(unquote(section), site)
        view = open(conn, unquote(section), record)

        edit!(view)
        clear_jobs!()
        publish!(view)

        assert render(view) =~ "will not compile", "the publish was not refused at all"

        assert compile_jobs_for(record.id) == [],
               "a refused publish still asked the runtime to rebuild"
      end
    end
  end

  # A DRAFT IS NOT A PUBLISH. It writes a draft row, and a draft row is not what the site renders —
  # so it must not queue a rebuild of the live module. This is the other half of the seam: a pipeline
  # that fired on every autosave would recompile the site every few seconds while somebody types.
  describe "a draft of an inactive document" do
    test "leaves it off", %{conn: conn, site: site} do
      record =
        :page
        |> record!(site)
        |> Ash.Changeset.for_update(:master_update, %{active: false}, authorize?: false)
        |> Ash.update!()

      view = open(conn, :page, record)
      edit!(view)
      render_click(view, "set_stage", %{"stage" => "draft"})
      render_click(view, "apply_stage", %{})

      refute Ash.get!(resource(:page), record.id, tenant: site.id, authorize?: false).active
    end
  end

  describe "a draft" do
    test "writes nothing the runtime has to rebuild", %{conn: conn, site: site} do
      record = record!(:page, site)
      view = open(conn, :page, record)

      clear_jobs!()

      edit!(view)
      render_click(view, "set_stage", %{"stage" => "draft"})
      render_click(view, "apply_stage", %{})
      render_async(view)

      assert compile_jobs_for(record.id) == [],
             "saving a draft queued a rebuild of the live page"
    end
  end
end
