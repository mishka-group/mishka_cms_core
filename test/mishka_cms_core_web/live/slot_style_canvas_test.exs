defmodule MishkaCmsCoreWeb.Test.SlotStyleCanvasTest do
  @moduledoc """
  A style set on a component's SLOT paints on the canvas.

  A slot is selectable in the layers rail and the inspector offers it the same Layout and Appearance
  controls every other node gets — but the canvas built each slot's assigns from `slot_node.attrs`
  alone, and parsing has already moved every recognised utility OUT of that `class` and into
  `meta.styles`. So the document was right, the canvas painted nothing, and a reload did not rescue
  it: the next parse lifted the utilities straight back out again.

  Reported as "inside the table we cannot select a header or slot and add specific style to it".

  ## Why the override is written `!`

  A slot's class lands inside the kit's own template, where the component's rules are descendant
  selectors: `chelekom-table`'s default `padding: "small"` emits `[&_table_.table-header]:px-4`,
  which is 0-2-1 against a plain `p-[8px]`'s 0-1-0 on the very same `<th>`. Without the bang the
  panel writes a rule that loses to the component's own default every time.
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

  @card ~S"""
  <div class="card">
    <h3 :for={h <- @header} class={["title", h[:class]]}>{render_slot(h)}</h3>
    {render_slot(@inner_block)}
  </div>
  """

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
      name: "slotty",
      site_id: site.id,
      template: @card,
      slots: [%{"name" => "header", "attrs" => [%{"name" => "class", "type" => "any"}]}]
    )

    page =
      create_page!(
        site_id: site.id,
        template:
          ~s(<.component component_name="slotty" site="localhost"><:header>Head</:header>body</.component>)
      )

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, admin("slot-style@example.com")), site: site, page: page}
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

  defp open_builder(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    _settled = render_async(view)
    view
  end

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token

  defp canvas(conn, view) do
    {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
    {canvas, html}
  end

  defp editor(view),
    do: elem(MishkaCmsCore.Runtime.PageBuilder.EditorSession.fetch(token(view)), 1)

  defp slot_node(view) do
    editor(view).tree |> Tree.walk() |> Enum.find(&(&1.kind == :slot))
  end

  describe "a style set on a slot" do
    test "reaches the slot's class on the canvas", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      slot = slot_node(view)

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => slot.id,
        "bucket" => "base",
        "prop" => "padding",
        "value" => "8px"
      })

      {_canvas, html} = canvas(conn, view)

      assert html =~ "p-[8px]!",
             "the slot's override never reached the component, so the canvas paints nothing"
    end

    # AND IT SURVIVES A SAVE. The bang has to be read back or the panel forgets the value the moment
    # the page is reopened — which is the same defect wearing the other half of its face.
    test "and is still the slot's own after a reparse", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      slot = slot_node(view)

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => slot.id,
        "bucket" => "base",
        "prop" => "padding",
        "value" => "8px"
      })

      markup =
        editor(view).tree |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize()

      {:ok, tree} = Tree.parse(markup)
      reparsed = tree |> Tree.walk() |> Enum.find(&(&1.kind == :slot))

      assert reparsed.meta[:styles] == %{base: %{"padding" => "8px"}}
    end

    # AND THE SAVED MARKUP IS WHAT A PAGE IS COMPILED FROM. The reparse above passes either way —
    # `extract_styles/2` lifts the utility back out whether or not it carries the bang — so it says
    # nothing about the document that actually ships. This one does: without the `!` the class is
    # 0-1-0 against the kit's own descendant rule and the padding an author set is on the canvas and
    # absent from every published page.
    test "and the saved document carries the bang, not only the canvas", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      slot = slot_node(view)

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => slot.id,
        "bucket" => "base",
        "prop" => "padding",
        "value" => "8px"
      })

      markup =
        editor(view).tree |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize()

      assert markup =~ "p-[8px]!",
             "the saved template drops the bang, so the published page loses the override"
    end
  end
end
