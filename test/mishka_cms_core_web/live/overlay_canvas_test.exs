defmodule MishkaCmsCoreWeb.Test.OverlayCanvasTest do
  @moduledoc """
  A dialog on the canvas: shut by default, open while it is selected, held open by the pin.

  ## What was wrong

  Two things at once, and they masked each other.

  Every component that renders its own content closed was held OPEN for the whole session. A page
  with a dialog, a drawer and a dropdown on it drew all three over the content they belong to,
  permanently, and the author could not see the page they were building.

  And the kit's overlays dismiss themselves on a click outside — `phx-click-away` on
  `chelekom-modal`'s focus wrap, and the same on the drawer and the dropdown. On the canvas EVERY
  click is outside: selecting the heading beside a dialog, a row in the layers rail, the page
  itself. Each one ran the component's own cancel sequence and shut the thing being edited, and the
  only way back was the eye on the layers row, off and then on again. Reported as: put a modal on a
  page, click anywhere, it disappears.

  ## What is pinned here

  That the wrapper carries a label while the overlay is shut (the chip an author clicks), that the
  pin and only the pin writes `data-pb-reveal`, that the self-closing bindings are gone from what
  the editor draws, and that a visitor gets none of it.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  require Ash.Query

  @password "Password123!"

  # The shape of `chelekom-modal`: `hidden` on the root, and a focus wrap that cancels on a click
  # away and on Escape. Both halves matter — the first is what makes the palette call it an overlay,
  # the second is what used to shut it under the author's pointer.
  @stored ~S"""
  <div id={@id} data-pb-open={show_modal(@id)} class="relative z-50 hidden">
    <div class="fixed inset-0" aria-hidden="true"></div>
    <div phx-click-away="cancel" phx-window-keydown="cancel" phx-key="escape" class="hidden">
      {render_slot(@inner_block)}
    </div>
  </div>
  """

  @drawn ~S(<div class="relative z-50 hidden"><div phx-click-away="cancel" phx-window-keydown="cancel" phx-key="escape" class="hidden">Body</div></div>)

  setup %{conn: conn} do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    create_component!(site_id: site.id, name: "acme-dialog", template: @stored)
    define_component!("acme-dialog", site, @drawn)

    page =
      create_page!(
        site_id: site.id,
        template:
          ~s(<div id="wrap"><h1>Hello</h1><.component component_name="acme-dialog" site="#{site.name}" id="d1">Body</.component></div>)
      )

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, create_admin("boss@example.com")), site: site, page: page}
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

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
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

  defp open_builder(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    render_async(view)
    view
  end

  defp canvas(conn, view) do
    {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
    {canvas, html}
  end

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token

  defp editor(view), do: elem(EditorSession.fetch(token(view)), 1)

  # THE WRAPPER'S OWN OPENING TAG. Asserting on the whole document cannot tell an attribute apart
  # from the `#pb-canvas-chrome` rule that names it in a selector, and every one of these attributes
  # appears in both places.
  defp wrapper(html) do
    html
    |> String.split("<")
    |> Enum.find("", &String.contains?(&1, ~s(data-component="acme-dialog")))
  end

  defp dialog_id(view) do
    editor(view).tree
    |> Tree.walk()
    |> Enum.find(&(Node.component_name(&1) == "acme-dialog"))
    |> Map.fetch!(:id)
  end

  describe "an overlay while it is shut" do
    test "says what it is instead of collapsing to nothing", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      assert wrapper(html) =~ ~s(data-pb-overlay="dialog"),
             "a shut dialog draws no box of its own, so the wrapper has to carry the label"
    end

    test "is not held open until somebody asks", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      refute wrapper(html) =~ "data-pb-reveal",
             "every overlay on the page used to be forced open for the whole session"
    end

    test "and nothing else on the page gets a chip", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      chips =
        html
        |> String.split("<")
        |> Enum.count(&String.contains?(&1, "data-pb-overlay="))

      assert chips == 1, "the page holds one overlay and a heading, a wrap and a body beside it"
    end
  end

  # A FLOATING PANEL IS AN OVERLAY TOO, and it hides itself differently from a dialog.
  #
  # `chelekom-tooltip`, `chelekom-popover` and `chelekom-dropdown-content` each put their panel
  # behind the bare `hidden` ATTRIBUTE and nothing else — no hiding class, no dialog role, no
  # click-away, because those live on the parent. So the reveal above never matched them, the scrim
  # rule meant for a modal's backdrop force-closed them on top of that, and an author who selected
  # one saw the trigger and no panel at all.
  describe "a floating panel" do
    setup %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)
      {:ok, chrome: html}
    end

    test "is opened by the same reveal a dialog is", %{chrome: chrome} do
      assert chrome =~ "[hidden])",
             "the reveal names hiding CLASSES only, so a panel hidden by the attribute stays shut"
    end

    test "and the rule that hides a backdrop leaves the panel alone", %{chrome: chrome} do
      assert chrome =~ ~S|[aria-hidden="true"]:not([data-floating-content])|,
             "the scrim rule was hiding the panel the reveal had just opened"
    end

    # `chelekom-dropdown-content`'s shape, which is the one none of the other signals reach: a bare
    # `hidden`, `role="menu"`, and no dialog role, no click-away, no hiding class — those all live on
    # the parent dropdown. Without a chip there is no wrapper, so no reveal reaches it however the
    # CSS reads.
    test "and the kit's own word for a panel is what makes it an overlay" do
      panel = %{
        "name" => "acme-menu",
        "template" =>
          ~S|<div id={@id} role="menu" data-floating-content="true" aria-hidden="true" hidden class="absolute">{render_slot(@inner_block)}</div>|
      }

      assert PaletteEntry.concealed?(panel)
    end
  end

  # PINNED TO THE VIEWPORT IS THE PROBLEM; POSITIONED IS NOT. The chrome un-pins a dialog while it is
  # being edited, because a dialog fixed to the viewport covers the page it belongs to. `.absolute`
  # was swept into that rule with `.fixed`, and it is ordinary layout inside a component's own box —
  # a carousel is in the concealed set, so selecting one un-positioned its own prev and next buttons
  # and both fell into a heap in the top-left corner.
  describe "what the chrome un-pins" do
    setup %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)
      {:ok, chrome: html}
    end

    test "a dialog fixed to the viewport is put back in the flow", %{chrome: chrome} do
      assert chrome =~ ~r/\)\s*\.fixed \{ position: static/,
             "a selected dialog will pin itself over the page it belongs to"
    end

    test "and an element merely positioned inside the component is left alone", %{chrome: chrome} do
      refute chrome =~ ~r/:is\(\.fixed, \.absolute\)/,
             "a carousel's own controls are absolute, and this drops them in the corner"
    end
  end

  # AN OPEN BUTTON THAT DOES NOTHING IS WORSE THAN NO BUTTON. A component may be written as two
  # alternative roots with exactly one of them rendering, and the editor cannot know which. So it
  # may only promise what every root agrees on.
  describe "the commands a component declares" do
    test "are read off every root, not the first one" do
      both = %{
        "name" => "acme-both",
        "template" =>
          ~S|<span :if={@inline} data-pb-open="x"></span><div :if={!@inline} data-pb-open="x"></div>|
      }

      only_first = %{
        "name" => "acme-first",
        "template" => ~S|<span :if={@inline} data-pb-open="x"></span><div :if={!@inline}></div>|
      }

      assert PaletteEntry.opens(both) == %{"show" => "data-pb-open"}

      assert PaletteEntry.opens(only_first) == %{},
             "the tooltip declared its commands on the branch its default does not draw"
    end

    test "and the kit's floating components declare them on both" do
      entries =
        [:code.priv_dir(:mishka_cms_core), "cms_ui_kits", "chelekom.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("components")
        |> Map.new(&{&1["name"], &1})

      for name <- ~w(chelekom-tooltip chelekom-popover) do
        assert PaletteEntry.opens(entries[name]) != %{},
               "#{name} offers an Open button its rendered root cannot answer"
      end
    end
  end

  describe "the pin" do
    test "holds it open, and letting go shuts it again", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      id = dialog_id(view)

      render_click(view, "toggle_pinned", %{"id" => id})
      assert EditorSession.pinned?(editor(view), id)

      {_canvas, html} = canvas(conn, view)
      assert wrapper(html) =~ ~s(data-pb-reveal="true")

      render_click(view, "toggle_pinned", %{"id" => id})
      refute EditorSession.pinned?(editor(view), id)

      {_canvas, html} = canvas(conn, view)
      refute wrapper(html) =~ "data-pb-reveal"
    end

    test "is offered on an overlay and on nothing else" do
      assert Panels.overlay?(%{name: "acme-dialog", concealed?: true})
      refute Panels.overlay?(%{name: "acme-card", concealed?: false})
      refute Panels.overlay?(%{name: "acme-card"})
      refute Panels.overlay?(nil)
    end

    # A pinned id whose node has gone is an id that would be pinned again by whatever is minted next.
    test "does not outlive the node it points at", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      id = dialog_id(view)

      render_click(view, "toggle_pinned", %{"id" => id})
      render_click(view, "op", %{"kind" => "delete", "node_id" => id})

      refute EditorSession.pinned?(editor(view), id)
    end
  end

  describe "a component's own dismissal" do
    test "does not run on the canvas", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      refute html =~ "phx-click-away",
             "a click anywhere on the canvas is a click away from the dialog being edited"

      refute html =~ "phx-window-keydown"
    end

    test "still runs for a visitor", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      render_click(view, "toggle_preview", %{})

      {_canvas, html} = canvas(conn, view)

      assert html =~ "phx-click-away", "preview is what a visitor gets, whole"
      refute html =~ "data-pb-overlay=", "and none of the editor's chrome"
    end

    test "and nothing else the component wrote is touched", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      assert html =~ ~s(phx-key="escape"),
             "only the two bindings that dismiss are dropped, not the attributes around them"
    end
  end
end
