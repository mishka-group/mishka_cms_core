defmodule MishkaCmsCoreWeb.Test.CollectionFieldTest do
  @moduledoc """
  The controls a list-of-maps property draws, one per key.

  A filterable gallery keeps its pictures in a `media` list whose items carry `src`, `alt` and
  `category`, and its categories come from the sibling `filters` list — so `category` is a dropdown
  of the buttons the author actually made. That list was handed to every key in the row that was not
  a picture, so the ALT TEXT of a photograph was a dropdown of category names and could not be typed
  at all: "we cannot add any image and it's not clear how it works".

  A key is offered a sibling's list only when that is what the list is a list of.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :integration

  @password "Password123!"

  @gallery ~S"""
  <div class="gallery">
    <button :for={f <- @filters}>{f}</button>
    <img :for={m <- @media} src={m.src} alt={m.alt} />
  </div>
  """

  @placed ~S|<.component component_name="picky" site="localhost" filters={["Branding", "Print"]} media={[%{src: "/images/one.jpg", alt: "a photograph", category: "Branding"}]} />|

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    create_component!(
      name: "picky",
      site_id: site.id,
      template: @gallery,
      attrs: [
        %{"name" => "filters", "type" => "list", "opts" => %{"default" => []}},
        %{"name" => "media", "type" => "list", "opts" => %{"default" => []}}
      ]
    )

    page = create_page!(site_id: site.id, template: @placed)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, admin("collection-field@example.com")), site: site, page: page}
  end

  defp cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
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

  defp admin(email) do
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

  defp selected_panel(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    _settled = render_async(view)

    token = :sys.get_state(view.pid).socket.assigns.token
    {:ok, editor} = MishkaCmsCore.Runtime.PageBuilder.EditorSession.fetch(token)
    component = editor.tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))

    render_click(view, "set_left_tab", %{"tab" => "inspector"})
    render_click(view, "select", %{"id" => component.id})
    view
  end

  defp form_for(key), do: ~s(form[phx-value-name="media"][phx-value-key="#{key}"])

  defp field(view, key) do
    view |> element(form_for(key)) |> render()
  end

  defp control(view, key) do
    cond do
      has_element?(view, form_for(key) <> " select") -> :select
      has_element?(view, form_for(key) <> " input[type=text]") -> :text
      has_element?(view, form_for(key)) -> :unknown
      true -> :absent
    end
  end

  describe "a list-of-maps property" do
    test "draws a dropdown for the key the sibling list is a list of", %{conn: conn, page: page} do
      view = selected_panel(conn, page)

      assert control(view, "category") == :select

      html = field(view, "category")
      assert html =~ "Branding"
      assert html =~ "Print"
    end

    # THE REPORTED DEFECT. Alt text is prose about one photograph; offering it the gallery's category
    # names meant it could not be written at all.
    test "and a text box for every other key, alt text most of all", %{conn: conn, page: page} do
      view = selected_panel(conn, page)

      assert control(view, "alt") == :text,
             "the alt text of a photograph is a dropdown of category names"

      refute field(view, "alt") =~ "Branding"
    end

    test "the picture itself stays a text box beside its own picker", %{conn: conn, page: page} do
      view = selected_panel(conn, page)

      assert control(view, "src") == :text
      assert has_element?(view, ~s(button[phx-click="pick_media"]))
    end

    test "and the author's own value is what the box shows", %{conn: conn, page: page} do
      view = selected_panel(conn, page)

      assert field(view, "alt") =~ "a photograph"
    end
  end
end
