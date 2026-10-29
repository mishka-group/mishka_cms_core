defmodule MishkaCmsCoreWeb.Test.RuntimeMetricsCardsTest do
  @moduledoc """
  The Performance Metrics card of every runtime table's modal, driven through the real page: the eye
  opens the modal, the card's numbers are read off the LiveView process (`:preview_metrics`), and the
  page has to route that answer back. A page that does not would leave its card on "Loading…".

  The numbers themselves are pinned in `MishkaCmsCore.Runtime.RenderMetricsResourcesTest`; this is
  the wiring.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Stylesheet
  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}

  require Ash.Query

  @password "Password123!"
  @await 5_000
  @switch "runtime.render_metrics"

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
      SettingsState.delete(nil, @switch)
    end)

    admin = create_admin("metrics-cards-#{unique()}@example.com")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(admin)

    {:ok, conn: conn, site: site}
  end

  defp open(conn, url, record) do
    {:ok, view, _html} = live(conn, url)
    send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
    html = render_async(view, @await)
    # the record loads first, then its numbers, each off the LiveView process
    _ = render_async(view, @await)
    {view, html}
  end

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  describe "a module-backed record's card" do
    setup %{site: site} do
      n = unique()

      %{
        records: [
          {"/admin/dashboard/runtime/pages",
           create_page!(site_id: site.id, name: "mc-p-#{n}", path: "/mc-p-#{n}"), "Re-renders"},
          {"/admin/dashboard/runtime/layouts",
           create_layout!(site_id: site.id, name: "mc-l-#{n}", path: "/mc-l-#{n}"), "Re-renders"},
          {"/admin/dashboard/runtime/error-pages",
           create_error_page!(site_id: site.id, name: "mc-e-#{n}", path: "/mc-e-#{n}"), "Shown"}
        ]
      }
    end

    test "loads its numbers, and says so while measuring is off", %{conn: conn, records: records} do
      for {url, record, fourth} <- records do
        {view, _html} = open(conn, url, record)

        render_time = text(view, "#runtime-preview-render-time")
        assert render_time =~ "Not active", "#{url}: #{render_time}"
        assert render_time =~ "Turn it on in Settings"
        assert text(view, "#runtime-preview-rerenders") =~ fourth
        refute render(view) =~ "1.2s", "#{url}: the card still shows the sample"
      end
    end

    test "with measuring on, a record nothing has drawn says what it is", %{
      conn: conn,
      records: records
    } do
      :ok = SettingsState.put(nil, @switch, %{"value" => true})

      for {url, record, _fourth} <- records do
        {view, _html} = open(conn, url, record)
        render_time = text(view, "#runtime-preview-render-time")

        assert render_time =~ "Not loaded" or render_time =~ "No renders",
               "#{url}: #{render_time}"

        refute render_time =~ "Loading…", "#{url}: the numbers never arrived"
      end
    end
  end

  describe "a stylesheet's card" do
    test "is its site's CSS bundle as this node holds it", %{conn: conn, site: site} do
      n = unique()

      {:ok, sheet} =
        Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{name: "mc-s-#{n}", kind: :custom, content: ".x{}", site_id: site.id, active: true},
          authorize?: false
        )
        |> Ash.create()

      now = DateTime.utc_now()

      AssetsState.save_batch([
        %{
          id: site.name,
          type: "css",
          value: String.duplicate("a", 3000),
          hash: "f00dfeed",
          updated_at: now
        },
        %{
          id: site.name,
          type: "brotli_css",
          value: String.duplicate("b", 600),
          hash: "f00dfeed",
          updated_at: now
        },
        %{
          id: site.name,
          type: "gzip_css",
          value: String.duplicate("g", 800),
          hash: "f00dfeed",
          updated_at: now
        }
      ])

      on_exit(fn ->
        for type <- ~w(css brotli_css gzip_css), do: AssetsState.delete(site.name, type)
      end)

      {view, _html} = open(conn, "/admin/dashboard/runtime/stylesheets", sheet)
      bundle = text(view, "#runtime-preview-bundle")
      assert bundle =~ "Site CSS"
      assert bundle =~ "600 B"
      assert bundle =~ "raw 2.9 KB · gzip 800 B"
      assert text(view, "#runtime-preview-build") =~ "Built"
      assert text(view, "#runtime-preview-last-built") =~ "Version f00dfeed"
    end
  end

  describe "a JS hook's card" do
    test "counts the templates that attach it", %{conn: conn, site: site} do
      n = unique()
      hook = create_js_hook!(site_id: site.id, name: "mc-h-#{n}")

      name =
        hook
        |> Ash.load!([:is_global], authorize?: false)
        |> JavaScriptCompiler.browser_name(site.name)

      create_page!(
        site_id: site.id,
        path: "/mc-h-#{n}",
        template: ~s|<div id="h-#{n}" phx-hook="#{name}"></div>|
      )

      {view, _html} = open(conn, "/admin/dashboard/runtime/js-hooks", hook)
      assert text(view, "#runtime-preview-bundle") =~ "Site JS"
      assert text(view, "#runtime-preview-named-in") =~ "1 template"
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
