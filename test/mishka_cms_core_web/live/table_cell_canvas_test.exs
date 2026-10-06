defmodule MishkaCmsCoreWeb.Test.TableCellCanvasTest do
  @moduledoc """
  A cell is selectable, and the editor's wrapper does not fall out of the table.

  ## What the parser does with a box around a cell

  The canvas wraps every node in a `<div>` carrying its id, its drag handle and its click target.
  Between a `<tr>` and its `<td>` that `<div>` is markup no parser keeps: it is foster-parented out
  of the table. The cells reattach, so the table looks right at rest — which is why this was
  reported as something else entirely. Each wrapper becomes a full-width, zero-height orphan sitting
  above the table; `openEmpties()` inflates every orphan into a dashed strip on every dragstart, so
  the page filled with hatched bars, and the pointer landed on one — a drop aimed at the footer read
  "Inside <chelekom-td>".

  And underneath all of it the real `<td>` carried no `data-node-id` at all, so a cell could never
  be clicked.

  ## The rule, which is not a list of three components

  `Containment.parent_restricted?/1` is read off the structural pairs the module already holds: a tag
  whose every permitted parent refuses a `div` cannot have one put around it. The canvas asks it of
  the component's OWN RENDER rather than of the kit entry, so a kit whose cell is called something
  else is covered without being named — which is what these three locally-defined components stand
  for. The kit's `chelekom-tr`, `-td` and `-th` are checked against the shipped bundle below.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.PageBuilder.Containment
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"

  @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  @components %{
    "cell-table" => ~S|<table class={@class}><tbody>{render_slot(@inner_block)}</tbody></table>|,
    "cell-row" =>
      ~S|<!-- what dev's HEEx annotation looks like --><tr class={@class}>{render_slot(@inner_block)}</tr>|,
    "cell-cell" => ~S|<td style="color:red" class={@class}>{render_slot(@inner_block)}</td>|,
    # `chelekom-button-group`'s shape: a parent that joins whatever is immediately inside it.
    "joined-group" =>
      ~S|<div class={["[&>*]:rounded-none [&>*]:border-0", @class]}>{render_slot(@inner_block)}</div>|,
    "joined-child" => ~S|<button class={@class}>press</button>|,
    # And one that does not, so the wrapper is still there for everything else.
    "plain-group" => ~S|<div class={@class}>{render_slot(@inner_block)}</div>|,
    # A component that owns its own DOM — a carousel, a filterable gallery — says so this way.
    "own-dom" =>
      ~S|<div id={@id} phx-hook="Something" phx-update="ignore" class={@class}>frozen</div>|
  }

  @document """
  <.component component_name="cell-table" site="localhost">
    <.component component_name="cell-row" site="localhost">
      <.component component_name="cell-cell" site="localhost">Ada</.component>
    </.component>
  </.component>
  <.component component_name="joined-group" site="localhost">
    <.component component_name="joined-child" site="localhost"></.component>
    <.component component_name="joined-child" site="localhost"></.component>
  </.component>
  <.component component_name="plain-group" site="localhost">
    <.component component_name="joined-child" site="localhost"></.component>
  </.component>
  <.component component_name="own-dom" site="localhost" id="od"></.component>
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

    for {name, template} <- @components do
      create_component!(
        name: name,
        site_id: site.id,
        template: template,
        attrs: [
          %{"name" => "class", "type" => "any", "opts" => %{"default" => nil}},
          %{"name" => "id", "type" => "string", "opts" => %{"default" => nil}}
        ]
      )
    end

    page = create_page!(site_id: site.id, template: @document)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, admin("table-cell-canvas@example.com")), site: site, page: page}
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

  defp index_of(html, needle) do
    case :binary.match(html, needle) do
      {at, _length} -> at
      :nomatch -> flunk("#{needle} is not in the frame at all")
    end
  end

  defp canvas_html(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    _settled = render_async(view)
    token = :sys.get_state(view.pid).socket.assigns.token
    {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token}")
    html
  end

  describe "the frame around a table" do
    # THE SYMPTOM, WHICH IS NOT A STRING IN THE MARKUP. A `<div>` written inside a `<tbody>` is not
    # there once the document is parsed: the parser moves it ahead of the `<table>` and reattaches
    # the row behind it, so the table reads perfectly and the node's own element is an empty box
    # sitting above it. Both halves are asserted, because either alone passes with the bug in place.
    test "leaves nothing of a row or a cell outside the table", %{conn: conn, page: page} do
      html = canvas_html(conn, page)
      table = index_of(html, "<table")

      for name <- ~w(cell-row cell-cell) do
        assert index_of(html, ~s(data-component="#{name}")) > table,
               "#{name}'s element was foster-parented out of the table"
      end
    end

    test "and draws no empty box for a node that has content", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      refute html =~ ~r/<div[^>]*data-component="cell-(row|cell)"[^>]*>\s*<\/div>/,
             "an orphaned wrapper is what every dragstart inflates into a dashed strip"
    end

    test "and the cell is the node, so it can be clicked", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      assert html =~ ~r/<td[^>]*\sdata-node-id="[^"]+"/, "the cell carries no id to select it by"
      assert html =~ ~r/<tr[^>]*\sdata-node-id="[^"]+"/, "the row carries no id to select it by"
      assert html =~ ~r/<td[^>]*\sdraggable="true"/
      assert html =~ ~r/<td[^>]*\sphx-click="select"/
      assert html =~ ~r/<td[^>]*\sdata-kind="component"/
    end

    test "the cell keeps the style its own component wrote, once", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      assert [cell] = Regex.run(~r/<td[^>]*data-component="cell-cell"[^>]*>/, html)
      assert cell =~ "color:red"
      assert length(Regex.scan(~r/\sstyle="/, cell)) == 1, "two style attributes is one style"
    end

    # The table itself is an ordinary element, so nothing about it changes.
    test "a root a div may hold is still wrapped", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      assert html =~ ~r/<div[^>]*\sdata-component="cell-table"/
      refute html =~ ~r/<table[^>]*\sdata-node-id=/
    end

    test "every node is still drawn exactly once", %{conn: conn, page: page} do
      html = canvas_html(conn, page)
      ids = Regex.scan(~r/data-node-id="([^"]+)"/, html) |> Enum.map(&List.last/1)

      assert length(ids) == length(Enum.uniq(ids))
      assert length(ids) >= 3
    end
  end

  # A PARENT THAT JOINS WHAT IS INSIDE IT. `chelekom-button-group` writes
  # `[&>*]:rounded-none [&>*]:border-0` — the element immediately inside, which was the editor's
  # wrapper and not the button. Three separately rounded buttons on the canvas, one joined control
  # on the published page.
  describe "a parent that styles its own children" do
    test "has them as its own children, not the editor's boxes", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      assert html =~ ~r/<button[^>]*\sdata-component="joined-child"/,
             "the button is not the node, so the parent's rules land on a box instead of it"
    end

    # THE LAST CHILD HAS TO BE THE LAST CHILD. A run of indentation before the closing tag was an
    # element too, so `[&>*:not(:last-child)]:border-r` put the divider on the final button as well
    # and the group ended in a stray line.
    test "and the last one in it really is the last child", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      assert [_whole, inside] =
               Regex.run(~r/data-component="joined-group"[^>]*>(.*?)<\/div><\/div>/s, html)

      refute inside =~ ~r/data-ws="true"[^>]*><\/span>\s*$/,
             "a whitespace element sits after the last button, so the last button is not last"

      assert String.ends_with?(String.trim_trailing(inside), "</button>")
    end

    test "and a parent that does not keeps the box", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      assert html =~ ~r/<div[^>]*data-component="plain-group"/

      assert Regex.scan(~r/<div[^>]*data-component="joined-child"/, html) != [],
             "nothing else changed about how an ordinary component is drawn"
    end
  end

  # A COMPONENT MUST NOT FREEZE ITSELF EITHER. `phx-update="ignore"` tells LiveView the DOM inside
  # belongs to the component's own JavaScript — right on a published page, where a carousel's hook is
  # mid-animation and a diff would tear it. On the canvas it means the author's every change is
  # written into the document, accepted by the server, drawn in the Inspector and never redrawn here:
  # the first render of that component is the last one. The two of the kit's that carry it are a
  # gallery and a carousel, which is to say the two whose content is a list an author adds to.
  describe "a component that owns its own DOM" do
    test "is not frozen while it is being edited", %{conn: conn, page: page} do
      html = canvas_html(conn, page)

      assert html =~ ~s(data-component="own-dom"), "the fixture is not on the page"
      assert html =~ "frozen", "the fixture did not render, so this asserts nothing"
      refute html =~ "could not render"

      refute html =~ ~s(phx-update="ignore"),
             "the canvas can never redraw what it has just changed"
    end
  end

  describe "the rule the canvas asks" do
    test "covers what the kit actually puts in a table" do
      roots =
        @bundle
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("components")
        |> Map.new(&{&1["name"], &1["template"]})

      for name <- ~w(chelekom-tr chelekom-td chelekom-th) do
        [_whole, tag] = Regex.run(~r/\A\s*<([a-z]+)/, roots[name])

        assert Containment.parent_restricted?(tag),
               "#{name} draws a <#{tag}> and the canvas would wrap it"
      end
    end

    test "and leaves alone what a div may hold", %{} do
      for tag <- ~w(div span table section img li) do
        assert Containment.parent_restricted?(tag) == (tag == "li")
      end
    end

    # THE ONE PLACE THE TWO MEET. `#pb-canvas-chrome`'s overlay rules are written as descendant
    # selectors — `data-pb-overlay` on the editor's wrapper, the `hidden` on the component's own
    # root a level down — so a component that is BOTH concealed and stamped would have both on the
    # same element and the rule would no longer reach it. No kit ships one, and this says so rather
    # than leaving it to be discovered when one does.
    test "nothing that gets stamped is an overlay", do: assert(stamped_overlays() == [])

    defp stamped_overlays do
      @bundle
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("components")
      |> Enum.filter(fn entry ->
        case Regex.run(~r/\A\s*<([a-zA-Z][a-zA-Z0-9-]*)/, entry["template"] || "") do
          [_whole, tag] -> Containment.parent_restricted?(tag) and PaletteEntry.concealed?(entry)
          nil -> false
        end
      end)
      |> Enum.map(& &1["name"])
    end
  end
end
