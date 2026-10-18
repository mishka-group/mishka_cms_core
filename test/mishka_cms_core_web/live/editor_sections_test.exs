# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.EditorSectionsTest do
  @moduledoc """
  One editor, four documents — and the same battery run against each of them.

  The `MishkaCmsCoreWeb.Test.BuilderLive.*` tests cover the editor in depth on a PAGE, which is the
  section every feature was built against. That is exactly why the other three kept shipping with
  holes in them: a layout's root was not in the frame, an error page's status strip moved the tab
  and not the document, and nothing had ever asked whether a component could be edited at all. Each
  of those was a feature that works — on a page.

  So this file is deliberately a MATRIX rather than a set of section tests. Every describe below runs
  the identical sequence against `page`, `layout`, `error-page` and `component`, on the same markup,
  and asserts the same outcome. A feature that only works on a page fails here in three places and
  names them.

  What differs legitimately between sections is asserted too, and only where it is real:

    * a **layout** wraps a page through `@inner_content`, so its fixture carries the slot and its
      publish gate refuses without it (`MishkaCmsCore.Runtime.PageBuilder.LayoutSlot`);
    * an **error page** keeps a list of `%{status, template, layout}`, so "the template" is one entry
      of it and a save replaces that entry rather than an attribute;
    * a **component** keeps no drafts at all — publishing is its only persistence, which
      `MishkaCmsCore.Runtime.PageBuilder.Drafts` states and the editor reports honestly.

  The Assistant is out of scope here on purpose: it does not edit the document. The Audit rail is
  asked one thing only — that it agrees with what the editor just did, because a finding the editor's
  own gate refuses to act on is a blocker nothing can clear.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.ElementScopes
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive

  require Ash.Query

  @password "Password123!"

  # ONE DOCUMENT, FOUR RESOURCES. Every section opens on this markup so an assertion means the same
  # thing in all four columns; a layout gets the slot it cannot legally be without.
  @body ~s(<section id="root"><h1>Title</h1><p>Body text</p></section>)
  @layout_body ~s(<body class="page"><main>{@inner_content}</main>#{@body}</body>)

  @sections [:page, :layout, :error_page, :component]

  setup %{conn: conn} do
    SiteState.clear()
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

  # ---- the four documents ------------------------------------------------------------------

  defp record!(:page, site), do: create_page!(site_id: site.id, template: @body)
  defp record!(:layout, site), do: create_layout!(site_id: site.id, template: @layout_body)

  defp record!(:error_page, site),
    do:
      create_error_page!(
        site_id: site.id,
        error_pages: [%{"status" => 404, "template" => @body, "layout" => %{}}]
      )

  defp record!(:component, site),
    do: create_component!(site_id: site.id, name: "matrix-box", template: @body)

  defp path(:error_page), do: "error-page"
  defp path(section), do: to_string(section)

  defp resource(:page), do: MishkaCmsCore.Runtime.Page
  defp resource(:layout), do: MishkaCmsCore.Runtime.Layout
  defp resource(:error_page), do: MishkaCmsCore.Runtime.ErrorPage
  defp resource(:component), do: MishkaCmsCore.Runtime.Component

  defp open(conn, section, site) do
    record = record!(section, site)
    {open_record(conn, section, record), record}
  end

  defp open_record(conn, section, record) do
    {:ok, view, _html} =
      live(conn, "/admin/dashboard/runtime/builder/#{path(section)}/#{record.id}")

    view
  end

  # WHAT THE SECTION ACTUALLY WROTE. Three keep a `template`; an error page keeps a list, and the
  # editor replaces one entry of it — so reading `template` back would answer nil for the one section
  # whose save is not an attribute write, and every publish assertion would pass by accident.
  defp saved_template(section, record) do
    {:ok, reloaded} =
      Ash.get(resource(section), record.id, action: :master_get, authorize?: false)

    case section do
      :error_page ->
        reloaded.error_pages
        |> Enum.find(&((&1["status"] || &1[:status]) == 404))
        |> then(&(&1["template"] || &1[:template]))

      _attribute ->
        reloaded.template
    end
  end

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token
  defp actor(view), do: :sys.get_state(view.pid).socket.assigns.current_user
  defp editor(view), do: elem(EditorSession.fetch(token(view)), 1)
  defp tree(view), do: editor(view) |> Map.fetch!(:tree)
  defp source(view), do: view |> tree() |> Serializer.serialize()
  defp nodes(view), do: view |> tree() |> Tree.walk()
  defp node_with_tag(view, tag), do: Enum.find(nodes(view), &(&1.tag == tag))

  # The invitation as the builder itself writes it, off the live socket's own assigns.
  defp share_url(view), do: BuilderLive.share_url(:sys.get_state(view.pid).socket.assigns)

  defp drafts_of(error_page, actor),
    do: MishkaCmsCore.Runtime.PageBuilder.Drafts.list("error-page", error_page, actor)

  defp live_error_page!(error_page) do
    {:ok, reloaded} =
      Ash.get(resource(:error_page), error_page.id, action: :master_get, authorize?: false)

    reloaded
  end

  # An error page keeps one template per status, so an assertion about a template has to say which
  # status it is reading — landing under the wrong one is the whole hazard here. A draft and the live
  # row hold the same list, so both are read the same way.
  defp by_status(%{error_pages: entries}) do
    Map.new(entries, fn entry ->
      {entry["status"] || entry[:status], entry["template"] || entry[:template]}
    end)
  end

  # A DRAFT CARRYING WORK ON TWO STATUSES — what an error page's draft exists to be. Built the way
  # the editor builds one: the 404 is saved under a name, and the next sitting opens that draft from
  # the sheet on the 500 and updates it by name, which is the collision banner's "Update it".
  # Returns the view looking at the 500, and the draft both sittings wrote to.
  defp two_status_draft!(conn, error_page) do
    base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"

    {:ok, four, _html} = live(conn, base <> "?status=404")

    render_click(four, "op", %{
      "kind" => "set_attr",
      "node_id" => node_with_tag(four, "h1").id,
      "name" => "class",
      "value" => "edited-404"
    })

    render_click(four, "save_as_draft", %{"label" => "Both"})
    draft_id = editor(four) |> Map.fetch!(:draft_id)

    {:ok, five, _html} = live(conn, base <> "?status=500")
    render_click(five, "draft_sheet", %{})
    render_click(five, "open_draft", %{"id" => draft_id})

    render_click(five, "op", %{
      "kind" => "set_attr",
      "node_id" => node_with_tag(five, "h1").id,
      "name" => "class",
      "value" => "edited-500"
    })

    render_click(five, "save_as_draft", %{"label" => "Both", "draft_id" => draft_id})

    {five, draft_id}
  end

  defp publish!(view) do
    render_click(view, "set_stage", %{"stage" => "published"})
    render_click(view, "apply_stage", %{})
  end

  defp list_url(:page), do: "/admin/dashboard/runtime/pages"
  defp list_url(:layout), do: "/admin/dashboard/runtime/layouts"
  defp list_url(:error_page), do: "/admin/dashboard/runtime/error-pages"

  defp draft_before_code!(view, class) do
    render_click(view, "op", %{
      "kind" => "set_attr",
      "node_id" => node_with_tag(view, "h1").id,
      "name" => "class",
      "value" => class
    })

    render_click(view, "save_as_draft", %{"label" => "Before the code"})
    editor(view) |> Map.fetch!(:draft_id)
  end

  defp save_code!(view, tab, row) do
    html = render_click(view, "save_code", %{"tab" => tab, "entry" => %{"0" => row}})
    assert html =~ "Saved to the", "the code drawer did not save the #{tab}"
  end

  # The preview bar on the section's own list — the one place a draft is published as a draft,
  # rather than folded into the editor's own Publish.
  defp publish_from_list!(conn, section, record, draft_id) do
    {:ok, list, _html} = live(conn, list_url(section))

    send(list.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
    render_async(list, 5_000)
    render_click(list, "preview_select_draft", %{"id" => draft_id})
    render_click(list, "preview_publish_draft", %{})
  end

  defp code_names(section, record, tab) do
    {:ok, reloaded} =
      Ash.get(resource(section), record.id, action: :master_get, authorize?: false)

    reloaded
    |> Map.get(String.to_existing_atom(tab))
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, :name) || Map.get(&1, "name")))
  end

  defp more!(view, id) do
    unless has_element?(view, id), do: view |> element("#pb-more-btn") |> render_click()
    view |> element(id) |> render_click()
  end

  # ---- the battery -------------------------------------------------------------------------

  for section <- @sections do
    describe "#{section}: opening" do
      test "parses its own markup into the tree", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        assert node_with_tag(view, "h1"), "the document did not reach the editor"
        assert node_with_tag(view, "p")
        assert has_element?(view, "#pb-root")
      end

      test "and names the section it is editing", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        assert editor(view) |> Map.fetch!(:section) ==
                 String.replace(unquote(to_string(section)), "-", "_")
      end
    end

    describe "#{section}: the tree operations" do
      test "set_text rewrites a run of words", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)
        h1 = node_with_tag(view, "h1")

        render_click(view, "op", %{
          "kind" => "set_text",
          "node_id" => hd(h1.children),
          "text" => "Rewritten"
        })

        assert source(view) =~ "Rewritten"
      end

      test "set_attr writes an attribute", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => node_with_tag(view, "p").id,
          "name" => "data-probe",
          "value" => "yes"
        })

        assert source(view) =~ ~s(data-probe="yes")
      end

      test "duplicate and delete both land", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)
        before = Enum.count(nodes(view), &(&1.tag == "p"))

        render_click(view, "op", %{
          "kind" => "duplicate",
          "node_id" => node_with_tag(view, "p").id
        })

        assert Enum.count(nodes(view), &(&1.tag == "p")) == before + 1

        render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
        assert Enum.count(nodes(view), &(&1.tag == "p")) == before
      end

      test "insert places new markup", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "op", %{
          "kind" => "insert",
          "parent_id" => node_with_tag(view, "section").id,
          "template" => ~s(<span class="inserted">new</span>)
        })

        assert source(view) =~ "inserted"
      end

      test "undo steps back and redo steps forward again", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
        refute source(view) =~ "Body text"

        more!(view, "#pb-undo")
        assert source(view) =~ "Body text", "undo did not restore the element"

        more!(view, "#pb-redo")
        refute source(view) =~ "Body text", "redo did not re-apply the delete"
      end
    end

    describe "#{section}: styling" do
      test "an override lands in the bucket it was written for", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)
        id = node_with_tag(view, "h1").id

        render_click(view, "op", %{
          "kind" => "set_style",
          "node_id" => id,
          "bucket" => "mobile",
          "prop" => "font-size",
          "value" => "2rem"
        })

        styles = view |> tree() |> Tree.get(id) |> Map.fetch!(:meta) |> Map.get(:styles, %{})

        assert get_in(styles, [:mobile, "font-size"]) == "2rem",
               "the override did not reach the mobile bucket"
      end

      test "and comes out as a responsive utility in the saved source", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "op", %{
          "kind" => "set_style",
          "node_id" => node_with_tag(view, "h1").id,
          "bucket" => "mobile",
          "prop" => "font-size",
          "value" => "2rem"
        })

        assert source(view) =~ "max-[560px]:[font-size:2rem]"
      end

      test "reset_styles clears the bucket again", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)
        id = node_with_tag(view, "h1").id

        render_click(view, "op", %{
          "kind" => "set_style",
          "node_id" => id,
          "bucket" => "base",
          "prop" => "opacity",
          "value" => "0.5"
        })

        render_click(view, "op", %{
          "kind" => "reset_styles",
          "node_id" => id,
          "bucket" => "base"
        })

        styles = view |> tree() |> Tree.get(id) |> Map.fetch!(:meta) |> Map.get(:styles, %{})
        assert Map.get(styles, :base, %{}) == %{}
      end
    end

    describe "#{section}: the clipboard" do
      test "copy and paste put a second one on the document", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
        render_click(view, "copy", %{})
        render_click(view, "paste", %{})

        assert Enum.count(nodes(view), &(&1.tag == "p")) >= 2
      end
    end

    describe "#{section}: the layers rail" do
      test "locking and hiding are recorded against the node", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)
        id = node_with_tag(view, "p").id

        render_click(view, "toggle_lock", %{"id" => id})
        render_click(view, "toggle_hidden", %{"id" => id})

        session = editor(view)

        assert MapSet.member?(session.locked, id), "the node was not locked"
        assert MapSet.member?(session.hidden, id), "the node was not hidden"
      end
    end

    describe "#{section}: find and replace" do
      test "replaces text across the document", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "find_query", %{"find" => "Body text", "replace" => "Swapped"})
        render_click(view, "replace_all", %{})

        assert source(view) =~ "Swapped"
        refute source(view) =~ "Body text"
      end
    end

    describe "#{section}: element CSS and interactions" do
      test "an element's own CSS is compiled and rides the session", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "save_element_css", %{
          "node_id" => node_with_tag(view, "h1").id,
          "css" => "color: rebeccapurple;"
        })

        assert editor(view) |> Map.fetch!(:element_css) =~ "rebeccapurple"
      end

      test "an on-click interaction is written as a real command", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "save_interaction", %{
          "node_id" => node_with_tag(view, "p").id,
          "action" => "toggle_class",
          "class" => "is-open"
        })

        assert source(view) =~ "phx-click"
        assert source(view) =~ ~s|JS.toggle_class("is-open"|

        # `to:` is the element's OWN scope, so an interaction can never reach something the author
        # did not point it at.
        assert source(view) =~ "to: \".pb-"
      end
    end

    describe "#{section}: the canvas" do
      test "renders the document and answers a selection", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        {:ok, canvas, html} =
          live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

        assert html =~ "Title"
        assert html =~ "Body text"

        id = node_with_tag(view, "h1").id
        render_click(canvas, "select", %{"id" => id})

        assert editor(view) |> Map.fetch!(:selection) == id
      end

      test "and the direction switch reaches it", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        {:ok, canvas, _html} =
          live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

        render_click(view, "set_dir", %{"dir" => "rtl"})
        assert render(canvas) =~ ~s(dir="rtl")
      end
    end

    describe "#{section}: publishing" do
      test "writes the edit back to where the section keeps it", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site)

        render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => node_with_tag(view, "h1").id,
          "name" => "class",
          "value" => "published-probe"
        })

        publish!(view)

        assert saved_template(unquote(section), record) =~ "published-probe"
      end
    end
  end

  # ---- these are Phoenix templates, in all four ------------------------------------------------

  # WHAT THESE DOCUMENTS ACTUALLY ARE. Every one of the four is compiled as HEEx and served by
  # Phoenix — so the editor is not editing HTML, it is editing a Phoenix template, and a construct it
  # cannot carry is a construct an author loses by opening the editor once. The round trip is the
  # whole contract: parse to a tree, serialise back, and the compiler must still accept it.
  #
  # Asserted per SECTION rather than once, because the four reach the parser by different routes —
  # three read an attribute and an error page reads one entry of a list — and a section that mangles
  # the trip mangles it silently.
  @phoenix_vocabulary [
    {"an assign", ~s|<p>{@title}</p>|},
    {"the old interpolation form", ~s|<p><%= @title %></p>|},
    {"a comprehension", ~s|<ul><%= for item <- @items do %><li>{item}</li><% end %></ul>|},
    {"a conditional", ~s|<div><%= if @shown do %><b>yes</b><% end %></div>|},
    {"an :if attribute", ~s|<div :if={@shown}>shown</div>|},
    {"a :for attribute", ~s|<div :for={item <- @items}>{item}</div>|},
    {"a function component", ~s|<.link navigate="/next">Next</.link>|},
    {"a JS command binding", ~s|<button phx-click={JS.toggle(to: "#panel")}>Open</button>|},
    {"a LiveView hook", ~s|<div id="probe" phx-hook="Clipboard" data-x="1">Copy</div>|},
    {"a form with a field",
     ~s|<form phx-submit="save"><input name="email" type="email" /></form>|},
    {"an expression attribute", ~s|<div class={@variant} id={@id}>x</div>|},
    {"a bare boolean attribute", ~s|<input disabled name="n" />|},
    {"an HTML comment", ~s|<div><!-- keep me --></div>|},
    {"a character reference", ~s|<p>&copy; 2026 &mdash; Mishka</p>|}
  ]

  for section <- @sections do
    describe "#{section}: the Phoenix template survives" do
      for {what, markup} <- @phoenix_vocabulary do
        test "#{what}", %{conn: conn, site: site} do
          markup = unquote(markup)
          record = record_with(unquote(section), site, markup)
          view = open_record(conn, unquote(section), record)

          # The serialiser normalises whitespace and the `{…}` form, so the contract is that the
          # template still COMPILES and still says the same things — not that it is byte-identical.
          out = source(view)

          assert {:ok, _tree} = Tree.parse(out), "the round trip produced unparseable HEEx"

          tokens = significant(markup)

          assert tokens != [],
                 "this case asserts nothing — `significant/1` found no meaning in #{markup}"

          for token <- tokens do
            assert String.contains?(out, token),
                   "#{token} did not survive the round trip: #{out}"
          end
        end
      end
    end
  end

  # The parts of a construct that carry meaning — the expression, the binding, the name. Attribute
  # ORDER and quoting are the serialiser's to choose; these are not.
  defp significant(markup) do
    ~r/(<!--.*?-->|@[a-z_]+|phx-[a-z]+|:[a-z]+=|JS\.[a-z_]+|<\.[a-z]+|&[a-z]+;|for [a-z]+ <-|if @[a-z_]+|disabled|name="[a-z]+")/
    |> Regex.scan(markup, capture: :first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp record_with(:page, site, markup), do: create_page!(site_id: site.id, template: markup)

  defp record_with(:layout, site, markup),
    do: create_layout!(site_id: site.id, template: markup <> ~s(<main>{@inner_content}</main>))

  defp record_with(:error_page, site, markup),
    do:
      create_error_page!(
        site_id: site.id,
        error_pages: [%{"status" => 404, "template" => markup, "layout" => %{}}]
      )

  defp record_with(:component, site, markup),
    do:
      create_component!(
        site_id: site.id,
        name: "vocab-#{System.unique_integer([:positive])}",
        template: markup
      )

  # ---- a document that belongs to no site --------------------------------------------------------

  # A GLOBAL LAYOUT OR COMPONENT IS EVERY SITE'S. It carries no `site_id`, which is the whole point —
  # all sites use it and only a master edits it — and the Assets sheet's live updates were guarded on
  # `media.site_id == editor.site_id`. `Media` declares `allow_nil? false` on its site, so against a
  # global document's nil that comparison can NEVER be true: an upload landed, the flash said
  # "Uploaded …", and the gallery and the folder rail did not move until the page was reloaded.
  describe "the Assets sheet on a global document" do
    for section <- [:layout, :component] do
      test "a #{section} with no site of its own still hears an upload", %{conn: conn, site: site} do
        record =
          case unquote(section) do
            :layout -> create_layout!(template: @layout_body)
            :component -> create_component!(name: "global-box", template: @body)
          end

        view = open_record(conn, unquote(section), record)

        assert editor(view) |> Map.fetch!(:site_id) == nil,
               "this fixture is not global, so it proves nothing"

        # Opening the sheet is what reads the folders, and the rail has to have been read before a
        # broadcast can add to it — `refresh_folders/1` leaves an unopened sheet alone rather than
        # loading one nobody is looking at.
        render_click(view, "open_sheet", %{"sheet" => "assets"})
        render_async(view)

        folder =
          create_media_category!(
            site_id: site.id,
            name: "Heard#{System.unique_integer([:positive])}"
          )

        send(
          view.pid,
          %Phoenix.Socket.Broadcast{
            topic: "media_category",
            event: "create",
            payload: %Ash.Notifier.Notification{
              resource: MishkaCmsCore.Runtime.MediaCategory,
              data: folder,
              action: %{name: :create, type: :create}
            }
          }
        )

        # `refresh_folders/1` only runs when the guard passes, so the new folder appearing in the
        # rail IS the guard passing.
        names =
          :sys.get_state(view.pid).socket.assigns.media_categories
          |> Map.fetch!(:result)
          |> Enum.map(& &1.name)

        assert folder.name in names,
               "the rail never heard the folder, so an upload would not show either"
      end
    end
  end

  # ---- the document's own root ------------------------------------------------------------------

  # A LAYOUT'S ROOT IS `<body>`, AND A DOCUMENT HOLDS ONE. Wrapping it wrote
  # `<div><body>…</body></div>`, duplicating it gave the layout two bodies, and a paste beside it
  # landed markup after `</body>` — all of which the canvas drew as ordinary divs, because it
  # substitutes a `div` for a document tag so the frame can hold it at all. Nothing refused any of it.
  describe "the root of a layout" do
    test "cannot be wrapped, and says why", %{conn: conn, site: site} do
      {view, _record} = open(conn, :layout, site)
      root = node_with_tag(view, "body")

      html = render_click(view, "ctx", %{"action" => "wrap", "node_id" => root.id})

      assert html =~ "the document itself"
      refute source(view) =~ "<div><body", "the layout root was wrapped"
    end

    test "nor duplicated", %{conn: conn, site: site} do
      {view, _record} = open(conn, :layout, site)
      root = node_with_tag(view, "body")

      render_click(view, "op", %{"kind" => "duplicate", "node_id" => root.id})

      assert Enum.count(nodes(view), &(&1.tag == "body")) == 1,
             "the layout ended up with two <body> roots"
    end

    # And a page's root, which is ordinary content, still does both.
    test "while a page's root still wraps", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)
      root = node_with_tag(view, "section")

      render_click(view, "ctx", %{"action" => "wrap", "node_id" => root.id})

      assert source(view) =~ "<div><section"
    end
  end

  # ---- forms are a page's, not every section's -------------------------------------------------

  # ONLY A PAGE COMPILES A FORM. Dropping a bare field wraps it in `<.form for={assigns[:form_form]}
  # phx-change="form-<token>-validate" phx-submit="form-<token>-submit">` — and
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.build_page_forms/1` is the only compiler that
  # emits `__page_forms__/0` and those two handlers. On a layout, an error page or a component that
  # wrapper is bound to an assign nothing supplies and events nothing handles, and the editor said
  # "Wrapped it in a form, because a field on its own submits nothing" while doing it.
  describe "placing a bare field" do
    for section <- [:layout, :error_page, :component] do
      test "is left alone in a #{section}, which compiles no form handlers", %{
        conn: conn,
        site: site
      } do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "drop", %{
          "kind" => "insert",
          "parent_id" => node_with_tag(view, "section").id,
          "index" => "1",
          "template" => ~s(<input type="text" name="field" />)
        })

        out = source(view)
        assert out =~ ~s(<input type="text"), "the field was not placed at all"
        refute out =~ "<.form", "a form nothing on this section compiles was wrapped around it"
        refute out =~ "phx-change"
        refute out =~ "assigns[:form_form]"
      end

      # AND THE AUDIT HAS TO AGREE WITH THE DROP. It called that deliberately bare field a blocker,
      # and its Fix comes back through the same gate the drop does and answers `:none` — the rail
      # swung over to the Assistant instead of editing. Writing the form by hand only traded it for
      # `form-no-destination`, which says visitors are thanked and code can receive the form: not
      # here.
      test "and the audit does not ask for a form in a #{section} either", %{
        conn: conn,
        site: site
      } do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "drop", %{
          "kind" => "insert",
          "parent_id" => node_with_tag(view, "section").id,
          "index" => "1",
          "template" => ~s(<input type="text" name="field" />)
        })

        view |> element("#pb-rail-audit") |> render_click()

        refute has_element?(view, "#pb-audit-group-forms"),
               "the Forms group ran where a form cannot exist"

        refute has_element?(view, ~s([data-rule="field-no-form"]))
      end

      # WHAT HTML ITSELF IS WRONG ABOUT STILL RUNS HERE. A search box in a header is ordinary markup
      # on any of these three, and a form with no way to send it is broken wherever it was written —
      # that Fix inserts a button rather than routing back through the gate the drop above obeys.
      test "but a form with nothing to send it is still reported in a #{section}", %{
        conn: conn,
        site: site
      } do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "drop", %{
          "kind" => "insert",
          "parent_id" => node_with_tag(view, "section").id,
          "index" => "1",
          "template" => ~s(<form action="/search"><input type="text" name="q" /></form>)
        })

        view |> element("#pb-rail-audit") |> render_click()

        assert has_element?(view, "#pb-audit-group-forms")
        assert has_element?(view, ~s([data-rule="form-no-submit"]))
      end
    end

    # And a page, which does compile them, still gets the wrapper and the note.
    test "is wrapped in a page, which does", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)

      render_click(view, "drop", %{
        "kind" => "insert",
        "parent_id" => node_with_tag(view, "section").id,
        "index" => "1",
        "template" => ~s(<input type="text" name="field" />)
      })

      out = source(view)

      assert out =~ "<.form"
      assert out =~ ~r/phx-change="form-[a-z2-7]{5}-validate"/
    end

    # And where a form does compile, a field left loose is still the blocker it always was.
    test "and a loose field on a page is still reported", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section id="root"><input type="text" name="field" /></section>)
        )

      view = open_record(conn, :page, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert has_element?(view, "#pb-audit-group-forms")
      assert has_element?(view, ~s([data-rule="field-no-form"]))
    end
  end

  # ---- a gesture aimed at a node that has gone -------------------------------------------------

  # TWO PEOPLE, ONE DOCUMENT — or one person and a panel that has not caught up. The editor is shared
  # over a session channel, so a node can be deleted between the moment a panel is drawn and the
  # moment a button on it is pressed. Attaching or detaching a hook matched `{:ok, tree}` on a write
  # that answers `{:error, _}` for a node that is gone, so the stale click raised and took the whole
  # editing session — every unsaved edit in it — down with it.
  describe "a stale gesture" do
    test "attaching a hook to a deleted node does not take the editor down", %{
      conn: conn,
      site: site
    } do
      {view, _record} = open(conn, :page, site)
      gone = node_with_tag(view, "p").id

      render_click(view, "op", %{"kind" => "delete", "node_id" => gone})
      refute source(view) =~ "Body text"

      render_click(view, "save_hook", %{"node_id" => gone, "hook" => "GlobalClipboard"})

      assert render(view) =~ "pb-root", "the editor did not survive a stale hook gesture"
    end

    test "and neither does detaching one", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)
      gone = node_with_tag(view, "p").id

      render_click(view, "op", %{"kind" => "delete", "node_id" => gone})
      render_click(view, "save_hook", %{"node_id" => gone, "hook" => ""})

      assert render(view) =~ "pb-root"
    end
  end

  # ---- the element-CSS gate --------------------------------------------------------------------

  describe "a plugin that refuses an element's CSS" do
    setup do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: MishkaCmsCore.Test.Plugins.BuilderElementCssGate,
          event: "builder:element_css:before_save",
          extension: :mishka_installer,
          status: :started
        })

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile(
          "builder:element_css:before_save",
          :start,
          false
        )

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(
          :name,
          MishkaCmsCore.Test.Plugins.BuilderElementCssGate,
          false
        )
      end)

      :ok
    end

    # The refusal branch answered `{socket, tree}` — not a handler return at all — so a gate doing
    # exactly what it exists to do took the editor down instead of reporting.
    test "is reported, and the editor survives it", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)

      html =
        render_click(view, "save_element_css", %{
          "node_id" => node_with_tag(view, "h1").id,
          "css" => "color: forbidden;"
        })

      assert html =~ "refused"
      assert render(view) =~ "pb-root", "the editor did not survive the refusal"
    end

    test "and an allowed one still writes", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)

      render_click(view, "save_element_css", %{
        "node_id" => node_with_tag(view, "h1").id,
        "css" => "color: teal;"
      })

      assert editor(view) |> Map.fetch!(:element_css) =~ "teal"
    end
  end

  # ---- the element-CSS stage -------------------------------------------------------------------

  # THE ROW IS THE LIVE SITE. Writing one recompiles the site bundle, and this had no stage gate at
  # all: a colour applied under a chip reading Draft changed the page for every visitor, on any
  # element already wearing a scope class — and neither drafts nor history carry element CSS, so
  # there was no way back to the published look.
  describe "element CSS follows the stage" do
    setup %{conn: conn, site: site} do
      {view, record} = open(conn, :page, site)

      {:ok,
       view: view,
       record: record,
       owner: ElementScopes.owner("page", record.id),
       actor: actor(view),
       heading: node_with_tag(view, "h1")}
    end

    test "draft-stage CSS is held until publish", ctx do
      %{view: view, site: site, owner: owner, actor: actor, heading: heading} = ctx

      html =
        render_click(view, "save_element_css", %{
          "node_id" => heading.id,
          "css" => "color: rebeccapurple;"
        })

      assert html =~ "goes live when you publish", "the flash did not say where the style went"

      assert html =~ "Held in this editing session",
             "the flash did not say where the style is until then"

      assert ElementCss.all(actor, site.id, owner) == %{}, "draft-stage CSS reached the live row"
      assert editor(view).staged_element_css, "nothing was held for the publish"
      assert editor(view).element_css =~ "rebeccapurple", "the canvas was not shown the rule"

      publish!(view)

      assert [body] = Map.values(ElementCss.all(actor, site.id, owner))
      assert body =~ "rebeccapurple", "publishing did not write the held rule"
      refute editor(view).staged_element_css, "the hold outlived the publish that wrote it"
    end

    test "publish-stage CSS is written where the author is looking", ctx do
      %{view: view, site: site, owner: owner, actor: actor, heading: heading} = ctx

      render_click(view, "set_stage", %{"stage" => "published"})

      html =
        render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "color: teal;"})

      refute html =~ "goes live when you publish"
      assert [body] = Map.values(ElementCss.all(actor, site.id, owner))
      assert body =~ "teal", "the live row was not written under a chip reading Publish"
    end

    # THE HOLD IS NOT A PLACE WORK GOES MISSING FROM. Nothing but the publish writes it to a row, so
    # every route that leaves a draft behind — a reload, Start fresh, opening another draft — has to
    # leave it alone: the markup of that sitting is a Drafts row and survives, and dropping the CSS
    # beside it would make the reload the one gesture that deletes an author's work outright.
    test "a reload mid-draft keeps the style the draft has not published", ctx do
      %{conn: conn, view: view, site: site, owner: owner, actor: actor, heading: heading} = ctx

      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "color: teal;"})

      # A draft of this sitting is what a plain reload detaches from — an autosave is enough.
      render_click(view, "save_as_draft", %{"label" => "Sitting"})
      assert editor(view).draft_id, "the sitting never got a draft to be detached from"

      reloaded = open_record(conn, :page, ctx.record)

      assert editor(reloaded).staged_element_css, "the reload threw the held style away"
      assert editor(reloaded).element_css =~ "teal", "the canvas came back without the style"
      assert ElementCss.all(actor, site.id, owner) == %{}, "the reload published it instead"

      # Carrying on with the draft is what puts the markup wearing the class back, and the publish
      # that writes that markup is the one that writes the rule.
      render_click(reloaded, "continue_draft", %{})
      publish!(reloaded)

      assert [body] = Map.values(ElementCss.all(actor, site.id, owner))
      assert body =~ "teal", "the style did not survive to the publish that writes it"
    end

    test "going back to the live page keeps the style for the next publish", ctx do
      %{view: view, site: site, owner: owner, actor: actor, heading: heading} = ctx

      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "color: teal;"})
      publish!(view)
      published = ElementCss.all(actor, site.id, owner)

      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "color: red;"})

      assert ElementCss.all(actor, site.id, owner) == published,
             "a draft edit changed the published style"

      render_click(view, "save_as_draft", %{"label" => "Reds"})
      html = render_click(view, "start_fresh", %{})

      assert ElementCss.all(actor, site.id, owner) == published,
             "leaving the draft published its style"

      assert html =~ "still held for your next publish",
             "the flash left the pending style unexplained"

      assert editor(view).staged_element_css, "leaving the draft threw the held style away"
    end

    # ONE SESSION, TWO BROWSERS — `?session=` invites a second editor and reopening the same URL
    # resumes the same session. The publish is whichever tab presses it, and it has to write every
    # element both of them styled rather than the map its own mount read.
    test "a second browser publishes the styles both of them applied", ctx do
      %{conn: conn, view: view, site: site, owner: owner, actor: actor, heading: heading} = ctx

      second = open_record(conn, :page, ctx.record)

      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "color: teal;"})

      render_click(second, "save_element_css", %{
        "node_id" => node_with_tag(second, "p").id,
        "css" => "color: hotpink;"
      })

      publish!(second)

      bodies = actor |> ElementCss.all(site.id, owner) |> Map.values() |> Enum.join("\n")
      assert bodies =~ "hotpink", "the publishing browser's own style was not written"
      assert bodies =~ "teal", "the other browser's style was dropped by the publish"
    end

    # THE ROW IS NOT THIS TAB'S TO REWRITE. One row holds the document's element CSS and everyone
    # writes into it — an error page's other four statuses, a second editor, the Stylesheets page
    # where it is an ordinary stylesheet — so anything that wrote back the map it read at mount
    # deleted every rule written since. Both writers are here because it is one rule for both: the
    # Apply under a chip reading Publish, and the publish that folds a draft's held CSS in.
    test "neither writer rewrites the row as it was at mount", ctx do
      %{view: view, site: site, owner: owner, actor: actor, heading: heading} = ctx

      paragraph = node_with_tag(view, "p")

      render_click(view, "save_element_css", %{"node_id" => paragraph.id, "css" => "color: teal;"})

      publish!(view)
      scope = Tree.scope(editor(view).tree, paragraph.id)

      # Somebody else writes the row this tab is holding a copy of.
      {:ok, _row} = ElementCss.put(actor, site.id, owner, scope, "color: hotpink;")

      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "color: navy;"})

      bodies = actor |> ElementCss.all(site.id, owner) |> Map.values() |> Enum.join("\n")
      assert bodies =~ "navy", "the Apply under a chip reading Publish wrote nothing"
      assert bodies =~ "hotpink", "the Apply wrote back the row as it was at mount"

      # And again against the publish that folds the hold in, rather than the Apply.
      {:ok, _row} = ElementCss.put(actor, site.id, owner, scope, "color: olive;")

      render_click(view, "set_stage", %{"stage" => "draft"})

      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "color: maroon;"})

      publish!(view)

      bodies = actor |> ElementCss.all(site.id, owner) |> Map.values() |> Enum.join("\n")
      assert bodies =~ "maroon", "the held style was not published"
      assert bodies =~ "olive", "the publish wrote back the row as it was at mount"
    end
  end

  # ---- the code drawer ------------------------------------------------------------------------

  # HELPERS ARE PART OF THE DOCUMENT, in all four. A page also carries `events` and `infos`; a layout,
  # an error page and a component carry `helpers` alone — and `write_code/2` hardcoded
  # `MishkaCmsCore.Runtime.Page`, looking the record up by the id of whatever was open. So saving a
  # helper while editing a layout asked for a PAGE with the layout's id, found none, and the save
  # failed for three of the four sections.
  for section <- [:page, :layout, :error_page, :component] do
    describe "#{section}: the code drawer" do
      test "a helper is saved to the document being edited", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site)

        render_click(view, "save_code", %{
          "tab" => "helpers",
          "entry" => %{
            "0" => %{"name" => "greet", "args" => "name", "code" => ~s|"hi " <> name|}
          }
        })

        {:ok, reloaded} =
          Ash.get(resource(unquote(section)), record.id, action: :master_get, authorize?: false)

        names = Enum.map(reloaded.helpers || [], &(Map.get(&1, :name) || Map.get(&1, "name")))

        assert "greet" in names,
               "the helper never reached this section's own record"
      end

      # A REFUSAL THE AUTHOR CANNOT SEE IS A SAVE THAT LOOKED LIKE IT WORKED. The fault was recorded
      # on an assign that no panel renders, so a helper that will not compile left the drawer looking
      # exactly like one that saved.
      test "and a helper that will not compile says so", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site)

        render_click(view, "save_code", %{
          "tab" => "helpers",
          "entry" => %{"0" => %{"name" => "broken", "args" => "", "code" => "def ("}}
        })

        assert has_element?(view, "#flash-error", "broken:"), "the refusal was silent"

        {:ok, reloaded} =
          Ash.get(resource(unquote(section)), record.id, action: :master_get, authorize?: false)

        names = Enum.map(reloaded.helpers || [], &(Map.get(&1, :name) || Map.get(&1, "name")))
        refute "broken" in names, "unparseable code was written to the record"
      end
    end
  end

  # CODE IS WRITTEN TO THE LIVE ROW, AND A DRAFT ONLY EVER HOLDS A COPY OF IT. The code drawer saves
  # straight to the document, while a draft forks every field of the document — its code included —
  # at the moment it is taken. Publishing that draft from the list's preview bar wrote the copy back
  # over the row: code written after the draft was taken was deleted without a word, and code
  # changed since made the publish itself refuse, because the publish writes as nobody and nobody
  # may add code.
  @code_rows %{
    page: [
      {"events", %{"name" => "kept_handler", "code" => "{:noreply, socket}"}},
      {"infos", %{"name" => ":kept_tick", "code" => "{:noreply, socket}"}},
      {"helpers", %{"name" => "kept_helper", "args" => "name", "code" => ~s|"hi " <> name|}}
    ],
    layout: [
      {"helpers", %{"name" => "kept_helper", "args" => "name", "code" => ~s|"hi " <> name|}}
    ],
    error_page: [
      {"helpers", %{"name" => "kept_helper", "args" => "name", "code" => ~s|"hi " <> name|}}
    ]
  }

  for section <- [:page, :layout, :error_page] do
    describe "#{section}: publishing a draft taken before the code drawer saved" do
      test "keeps code written after the draft was taken", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site)
        draft_id = draft_before_code!(view, "drafted-markup")

        for {tab, row} <- @code_rows[unquote(section)], do: save_code!(view, tab, row)

        assert publish_from_list!(conn, unquote(section), record, draft_id) =~
                 "Published to the live"

        assert saved_template(unquote(section), record) =~ "drafted-markup",
               "the draft's own markup was not published"

        for {tab, row} <- @code_rows[unquote(section)] do
          assert row["name"] in code_names(unquote(section), record, tab),
                 "publishing the draft deleted the #{tab} saved after it was taken"
        end
      end

      test "still publishes, and keeps code changed after the draft was taken", %{
        conn: conn,
        site: site
      } do
        {view, record} = open(conn, unquote(section), site)

        for {tab, row} <- @code_rows[unquote(section)], do: save_code!(view, tab, row)

        draft_id = draft_before_code!(view, "drafted-markup")

        for {tab, row} <- @code_rows[unquote(section)],
            do: save_code!(view, tab, Map.update!(row, "name", &(&1 <> "_changed")))

        assert publish_from_list!(conn, unquote(section), record, draft_id) =~
                 "Published to the live"

        assert saved_template(unquote(section), record) =~ "drafted-markup",
               "the draft's own markup was not published"

        for {tab, row} <- @code_rows[unquote(section)] do
          assert code_names(unquote(section), record, tab) == [row["name"] <> "_changed"],
                 "publishing the draft put back the #{tab} it was taken with"
        end
      end
    end
  end

  # A CODE TAB'S BOXES ARE FORM FIELDS AND NOTHING POSTS THEM UNTIL SOMETHING SUBMITS. Switching tabs
  # used to be a plain `phx-click`, so the form was re-rendered from the last SAVED state and
  # whatever was in it went with it — watched in the editor: fill in a handler, click Messages, come
  # back, and the handler is empty; Save then answers "this handler has no code" about a box that was
  # full a moment ago.
  describe "moving between code tabs" do
    test "the tab itself submits the form it is leaving", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)

      render_click(view, "open_source", %{"tab" => "events"})
      html = render(view)

      assert html =~ ~s(id="pb-sourcetab-infos")

      # The three attributes that make it carry the form with it. `go` is the SUBMIT BUTTON'S own
      # value, which a browser sends only for the button that submitted — so Save carries no
      # destination and there is no leftover state to reset.
      assert html =~ ~s(form="pb-code-form")
      assert html =~ ~s(name="go")
      assert html =~ ~s(value="infos")
    end

    test "and what was typed is still there on the way back", %{conn: conn, site: site} do
      {view, record} = open(conn, :page, site)

      render_click(view, "open_source", %{"tab" => "events"})

      render_submit(view, "save_code", %{
        "tab" => "events",
        "go" => "infos",
        "entry" => %{"0" => %{"name" => "typed_never_saved", "code" => "{:noreply, socket}"}}
      })

      html = render_click(view, "source_tab", %{"tab" => "events"})

      assert html =~ "typed_never_saved", "the handler was lost between one tab and the next"

      # AND IT IS A STASH, NOT A SAVE. Leaving a tab is not a decision to write, and running the
      # compile check over a half-written handler would report a fault about a sentence somebody is
      # still in the middle of.
      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, record.id, action: :master_get, authorize?: false)

      names = Enum.map(reloaded.events || [], &(Map.get(&1, :name) || Map.get(&1, "name")))

      refute "typed_never_saved" in names, "switching tabs wrote to the record"
    end
  end

  # ---- a component is for the other three ----------------------------------------------------

  # A COMPONENT IS NOT A DOCUMENT SOMEBODY VISITS. Its whole purpose is to be placed inside the other
  # three, so editing one is only half of it — the half every other test here covers. These are the
  # other half: what the editor writes has to come back out of the palette and render where it is
  # put, or a component editor is a text box that changes nothing anyone sees.
  describe "a component, once edited, is placeable in" do
    setup %{site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "placeable-card",
          template: ~s(<article class="card"><h2>Card</h2></article>)
        )

      %{component: component}
    end

    for host <- [:page, :layout, :error_page] do
      test "a #{host}, and the palette offers it", %{conn: conn, site: site, component: component} do
        {view, _record} = open(conn, unquote(host), site)
        render_async(view)

        assert has_element?(view, "#pb-comp-placeable-card"),
               "the component is not in this section's palette"

        view |> element("#pb-comp-placeable-card") |> render_click()
        render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

        placed = Enum.find(nodes(view), &(&1.kind == :component))
        assert placed, "nothing was placed"

        # Placed as a CALL, not as a copy of its markup — that is what makes it one component
        # rather than a snapshot of one.
        assert source(view) =~ "placeable-card"
        assert source(view) =~ ".component"

        refute source(view) =~ ~s(<article class="card">),
               "the component's markup was inlined instead of called"

        assert saved_after_publish(view, unquote(host), component)
      end
    end

    defp saved_after_publish(view, _host, _component) do
      publish!(view)
      true
    end

    test "and the canvas renders what it resolves to", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)
      render_async(view)

      view |> element("#pb-comp-placeable-card") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "placeable-card"
    end

    # A COMPONENT CANNOT BE MADE OUT OF ITSELF. The palette is "every component this site can place",
    # and while one is open in the editor it is in that list — so it could be dropped into its own
    # template. The module that would produce calls itself for as long as the machine allows: the
    # canvas's heap ceiling ends the iframe, and a published one ends the request.
    test "but never inside itself", %{conn: conn, site: site, component: component} do
      view = open_record(conn, :component, component)
      render_async(view)

      refute has_element?(view, "#pb-comp-placeable-card"),
             "the component being edited was offered as something to put inside it"

      names = view |> editor() |> Map.fetch!(:components) |> Enum.map(& &1.name)
      refute "placeable-card" in names

      # And a sibling component is still offered — this removes one row, not the panel.
      other = create_component!(site_id: site.id, name: "other-card", template: "<div>x</div>")
      assert other

      view = open_record(conn, :component, component)
      render_async(view)

      assert has_element?(view, "#pb-comp-other-card")
    end

    # AND THE EDIT REACHES THEM. A component is published once and every document calling it changes,
    # which is the reason to have components at all.
    test "an edit published on the component is what the palette then offers", %{
      conn: conn,
      site: site,
      component: component
    } do
      view = open_record(conn, :component, component)

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => hd(node_with_tag(view, "h2").children),
        "text" => "Rewritten card"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Component, component.id,
          action: :master_get,
          authorize?: false
        )

      assert reloaded.template =~ "Rewritten card"

      {page_view, _record} = open(conn, :page, site)
      render_async(page_view)

      entry =
        page_view
        |> editor()
        |> Map.fetch!(:components)
        |> Enum.find(&(&1.name == "placeable-card"))

      assert entry, "the palette lost the component"
      assert entry.template =~ "Rewritten card", "the palette served a stale copy"
    end
  end

  # THE PREVIEW'S STYLESHEET IS CACHED UNDER THE RECORD'S TOKEN and only compiled when that key is
  # absent, which is what makes opening one cheap. It also meant a document published with new
  # utility classes went on being previewed against the CSS of the version before it — the new
  # classes had no rules at all, so the preview looked broken and the markup was blamed.
  describe "publishing drops the preview stylesheet" do
    for section <- [:page, :layout, :error_page] do
      test "for a #{section}", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site)

        {:ok, loaded} =
          Ash.get(resource(unquote(section)), record.id, action: :master_get, authorize?: false)

        assert is_binary(loaded.preview_token)

        MishkaCmsCore.Runtime.States.AssetsState.save(%{
          id: loaded.preview_token,
          type: "css",
          value: ".stale{}",
          hash: "deadbeef",
          updated_at: DateTime.utc_now()
        })

        render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => node_with_tag(view, "h1").id,
          "name" => "class",
          "value" => "mt-9"
        })

        publish!(view)

        refute MishkaCmsCore.Runtime.States.AssetsState.exists?(loaded.preview_token, "css"),
               "the preview kept the stylesheet of the version before this publish"
      end
    end
  end

  # THE TOKENIZER IS NOT THE COMPILER, and neither is the serializer. `Tree.parse/1` takes `{@a + }`
  # happily — the braces delimit an expression and the expression is a token to it. `to_heex/1` reads
  # every expression on the way out and catches that one; what neither of them reads is the HEEx
  # itself, so `<div :foo={@a}>` — a special attribute that does not exist — survives both and is
  # refused by the engine that has to build the module.
  #
  # A PAGE was the only section protected, by `Validations.PageCodeCompiles` on its own actions.
  # Layouts, error pages and components have no such validation, so for three of the four the editor
  # is the last place this can be caught before the site stops compiling.
  describe "markup that will not compile" do
    @unparseable ~s(<section id="root"><h1>Title</h1><p>{@a + }</p></section>)
    @uncompilable ~s(<section id="root"><h1>Title</h1><div :foo={@a}>x</div></section>)

    # The layout still has to render the page it wraps, or the OTHER publish gate refuses it first and
    # this test would pass for the wrong reason.
    @uncompilable_layout ~s(<body class="page"><main>{@inner_content}</main><div :foo={@a}>x</div><h1>Title</h1></body>)

    # SEEDED PAST THE ACTIONS, BECAUSE THE ACTIONS NOW REFUSE IT.
    # `Validations.TemplateCompiles` closed the front door on all four resources, so a document like
    # this can no longer be CREATED — which is the point of it. What it cannot do is unmake the rows
    # already in a database from before it existed, and those are exactly the documents somebody
    # opens the editor to fix. `Ash.Seed.seed!/2` writes through the data layer and past every
    # action, which is the only honest way to reproduce one.
    defp broken_record!(section, site) do
      Ash.Seed.seed!(resource(section), Map.merge(seed_defaults(), broken_attrs(section, site)))
    end

    # Seeding skips the CHANGES as well as the validations, and `preview_token` is minted by one of
    # them under a NOT NULL column.
    defp seed_defaults,
      do: %{preview_token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}

    defp broken_attrs(:layout, site),
      do: %{
        name: "broken-layout-#{System.unique_integer([:positive])}",
        path: "/broken-#{System.unique_integer([:positive])}",
        template: @uncompilable_layout,
        site_id: site.id
      }

    defp broken_attrs(:page, site),
      do: %{
        name: "broken-page-#{System.unique_integer([:positive])}",
        title: "Broken Page",
        path: "/broken-#{System.unique_integer([:positive])}",
        template: @uncompilable,
        site_id: site.id
      }

    defp broken_attrs(:error_page, site),
      do: %{
        name: "broken-error-#{System.unique_integer([:positive])}",
        path: "/broken-#{System.unique_integer([:positive])}",
        error_pages: [%{"status" => 404, "template" => @uncompilable, "layout" => %{}}],
        site_id: site.id
      }

    defp broken_attrs(:component, site),
      do: %{
        name: "broken-#{System.unique_integer([:positive])}",
        template: @uncompilable,
        site_id: site.id
      }

    # AND THE FRONT DOOR REALLY IS SHUT, on every one of them — which is what makes the tests below
    # about legacy rows rather than about a hole anyone can still write through.
    for section <- @sections do
      test "a #{section} like this cannot be created through its own actions", %{site: site} do
        assert_raise Ash.Error.Invalid, fn ->
          create!(unquote(section), site, @uncompilable, @uncompilable_layout)
        end
      end
    end

    defp create!(:page, site, markup, _layout),
      do: create_page!(site_id: site.id, template: markup)

    defp create!(:layout, site, _markup, layout),
      do: create_layout!(site_id: site.id, template: layout)

    defp create!(:error_page, site, markup, _layout),
      do:
        create_error_page!(
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => markup, "layout" => %{}}]
        )

    defp create!(:component, site, markup, _layout),
      do:
        create_component!(
          site_id: site.id,
          name: "boundary-#{System.unique_integer([:positive])}",
          template: markup
        )

    for section <- @sections do
      test "and a #{section} that arrived broken is not published", %{conn: conn, site: site} do
        record = broken_record!(unquote(section), site)
        view = open_record(conn, unquote(section), record)

        assert node_with_tag(view, "h1"), "the document did not reach the editor"

        publish!(view)

        assert render(view) =~ "will not compile",
               "the editor published markup the compiler refuses"

        assert saved_template(unquote(section), record) == stored_broken(unquote(section)),
               "the broken markup was rewritten to the live record anyway"
      end
    end

    defp stored_broken(:layout), do: @uncompilable_layout
    defp stored_broken(_section), do: @uncompilable

    for section <- @sections do
      test "the source window refuses it in a #{section}", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)
        before = source(view)

        render_click(view, "apply_source", %{"source" => @unparseable})
        assert source(view) == before, "the document was replaced with markup that cannot compile"

        render_click(view, "apply_source", %{"source" => @uncompilable})
        assert source(view) == before, "the document was replaced with markup HEEx refuses"
      end

      test "and so does the element pane in a #{section}", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)
        before = source(view)

        render_click(view, "apply_element_heex", %{
          "node_id" => node_with_tag(view, "p").id,
          "source" => ~s(<p>{@a + }</p>)
        })

        assert source(view) == before, "one element was replaced with markup that cannot compile"
      end

      # AND A GOOD ONE STILL GOES THROUGH — a gate that refuses everything is not a gate.
      test "while markup that does compile still applies in a #{section}", %{
        conn: conn,
        site: site
      } do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "apply_source", %{
          "source" => ~s(<section id="root"><h1>Title</h1><p>{@thing}</p></section>)
        })

        assert source(view) =~ "{@thing}"
      end
    end

    # ONE ENTRY IS BROKEN, NOT THE DOCUMENT. The recovery screen is the only door into markup the
    # tokenizer refuses, and it has no session to ask which status is open — so it has to ask the
    # URL. Asking the default instead put the 404's markup in the box for a broken 500, wrote the
    # correction back over the live 404, and left the 500 exactly as unopenable as it was.
    @untokenizable ~s(<div><p>unclosed</div>)

    test "recovering an error page mends the status it was opened on", %{conn: conn, site: site} do
      record =
        Ash.Seed.seed!(
          resource(:error_page),
          Map.merge(seed_defaults(), %{
            name: "broken-500-#{System.unique_integer([:positive])}",
            path: "/broken-#{System.unique_integer([:positive])}",
            error_pages: [
              %{"status" => 404, "template" => @body, "layout" => %{}},
              %{"status" => 500, "template" => @untokenizable, "layout" => %{}}
            ],
            site_id: site.id
          })
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{record.id}"
      {:ok, view, html} = live(conn, base <> "?status=500")

      assert has_element?(view, "#pb-recover")
      assert html =~ "unclosed", "the screen offered an entry that was not the broken one"

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#pb-recover-form")
               |> render_submit(%{"template" => ~s(<section id="root"><h1>Mended</h1></section>)})

      assert to == base <> "?status=500", "the way back dropped the status it just mended"

      by_status = by_status(live_error_page!(record))

      assert by_status[500] =~ "Mended"
      assert by_status[404] == @body, "the correction landed on the status nobody opened"
    end
  end

  # ---- what legitimately differs -------------------------------------------------------------

  describe "the differences that are real" do
    test "a component keeps no drafts, and the editor says so rather than doing nothing", %{
      conn: conn,
      site: site
    } do
      {view, _record} = open(conn, :component, site)

      refute has_element?(view, "#pb-draft-target"),
             "a component has no draft target to choose"

      assert MishkaCmsCore.Runtime.PageBuilder.Drafts.resource("component") == nil
    end

    # AND IT SAYS SO RATHER THAN DOING NOTHING. The stage control still offers Draft — it is one
    # control for four sections — so asking for one has to come back with the reason and the way
    # round it, not with a silent no-op that reads as a save.
    test "and asking a component for a draft reports why it cannot", %{conn: conn, site: site} do
      {view, _record} = open(conn, :component, site)

      render_click(view, "set_stage", %{"stage" => "draft"})
      html = render_click(view, "apply_stage", %{})

      assert html =~ "A component has no drafts"
      assert html =~ "Publish"
    end

    for section <- [:page, :layout, :error_page] do
      test "a #{section} keeps drafts, and saving one writes a row", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site)

        render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => node_with_tag(view, "h1").id,
          "name" => "class",
          "value" => "drafted"
        })

        render_click(view, "save_as_draft", %{"label" => "A named draft"})

        assert has_element?(view, "#pb-draft-target")
        assert editor(view) |> Map.fetch!(:draft_id)
      end

      # THE OTHER HALF OF A DRAFT IS READING IT BACK. `ErrorPageDraft` keeps `error_pages`, not a
      # `template`, so the write went nowhere and `EditorSession.edit_draft/2` — which matches on
      # `%{template: t}` — had nothing to match: saving, reopening and forking were all broken for
      # the one section whose draft is not an attribute.
      test "a #{section} draft is read back with the edit in it", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site)

        render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => node_with_tag(view, "h1").id,
          "name" => "class",
          "value" => "drafted-edit"
        })

        render_click(view, "save_as_draft", %{"label" => "Round trip"})
        draft_id = editor(view) |> Map.fetch!(:draft_id)
        assert draft_id, "nothing was written to open again"

        # A FRESH EDITOR, the way coming back tomorrow is.
        {:ok, reopened, _html} =
          live(conn, "/admin/dashboard/runtime/builder/#{path(unquote(section))}/#{record.id}")

        render_click(reopened, "draft_sheet", %{})
        render_click(reopened, "open_draft", %{"id" => draft_id})

        assert source(reopened) =~ "drafted-edit"
        assert editor(reopened) |> Map.fetch!(:draft_id) == draft_id
      end

      # Forking COPIES, it does not switch: the flash says "Copied to …" and the author stays where
      # they were, which is the point of taking a copy of a draft you are not currently in.
      test "and forking a #{section} draft leaves both on the list", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site)

        render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => node_with_tag(view, "h1").id,
          "name" => "class",
          "value" => "forked-from"
        })

        render_click(view, "save_as_draft", %{"label" => "Original"})
        draft_id = editor(view) |> Map.fetch!(:draft_id)

        render_click(view, "draft_sheet", %{})
        assert render_click(view, "fork_draft", %{"id" => draft_id}) =~ "Copied to"

        actor = actor(view)

        labels =
          unquote(to_string(section))
          |> String.replace("_", "-")
          |> MishkaCmsCore.Runtime.PageBuilder.Drafts.list(record, actor)
          |> Enum.map(& &1.label)

        assert "Original" in labels
        assert Enum.any?(labels, &String.contains?(&1, "copy")), "the copy was not written"
        assert editor(view) |> Map.fetch!(:draft_id) == draft_id, "forking moved the author"
      end
    end

    # A COPY OF A DRAFT IS A COPY OF THE DRAFT, not of the document underneath it. Every field but
    # the open template was read from the live record, so a copy carried the page as it stands today
    # — and an error page's draft is a snapshot of every status, so the copy put the published markup
    # back over all four the author was not looking at, under a flash saying it had been copied.
    test "forking an error-page draft keeps the statuses the author is not looking at", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => @body, "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      {five, draft_id} = two_status_draft!(conn, error_page)

      render_click(five, "draft_sheet", %{})
      assert render_click(five, "fork_draft", %{"id" => draft_id}) =~ "Copied to"

      copy =
        error_page
        |> drafts_of(actor(five))
        |> Enum.find(&String.contains?(&1.label, "copy"))

      assert copy, "the copy was not written"
      assert by_status(copy)[500] =~ "edited-500"

      assert by_status(copy)[404] =~ "edited-404",
             "the fork put the published 404 back over the draft's"
    end

    # AND SO DOES SAVING IT UNDER ANOTHER NAME. It is the same create reached from inside the
    # document instead of from the drafts table, and it was losing the same work with the same flash.
    test "and so does saving that draft under another name", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => @body, "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      {five, _draft_id} = two_status_draft!(conn, error_page)

      render_click(five, "save_as_draft", %{"label" => "Under another name"})

      renamed =
        error_page
        |> drafts_of(actor(five))
        |> Enum.find(&(&1.label == "Under another name"))

      assert renamed, "the new name wrote no row"
      assert by_status(renamed)[500] =~ "edited-500"

      assert by_status(renamed)[404] =~ "edited-404",
             "saving under a new name put the published 404 back over the draft's"
    end

    # AND THE LIVE PAGE IS NOT A DRAFT TO COPY. The sitting holds a draft row of its own from the
    # first save on, so "save under a new name" was copying THAT — the page's fields as they stood
    # when it was written — and a Configuration save made since was missing from the new draft and
    # put back the moment anyone published it. Only a draft the author OPENED is another document.
    test "and saving a page under a new name keeps settings changed since the last one", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: @body, section: "blog")
      view = open_record(conn, :page, page)

      render_click(view, "save_as_draft", %{"label" => "Before the move"})
      assert editor(view) |> Map.fetch!(:draft_id), "the sitting holds no draft to be copied from"

      moved =
        page
        |> Ash.Changeset.for_update(:master_update, %{section: "company"},
          actor: actor(view),
          authorize?: false
        )
        |> Ash.update!(authorize?: false)

      render_click(view, "open_settings", %{})
      send(view.pid, {:form_saved, :update, moved})
      render(view)

      render_click(view, "save_as_draft", %{"label" => "After the move"})

      copy =
        "page"
        |> MishkaCmsCore.Runtime.PageBuilder.Drafts.list(moved, actor(view))
        |> Enum.find(&(&1.label == "After the move"))

      assert copy, "the new name wrote no row"

      assert copy.section == "company",
             "the new draft carried the section from before the Configuration save"
    end

    # ONE ROW, FIVE DOCUMENTS. An error page's element CSS is keyed by the record, not by the status,
    # so all five statuses write into one stylesheet row — and the prune that runs on publish keeps
    # only the scopes present in the tree that happens to be OPEN. Publishing the 500 therefore
    # deleted every rule the author had written on the 404, silently and permanently.
    test "publishing one error-page status keeps the other status's element CSS", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"

      # A rule written on the 404 …
      {:ok, four, _html} = live(conn, base <> "?status=404")

      render_click(four, "save_element_css", %{
        "node_id" => node_with_tag(four, "h1").id,
        "css" => "color: rebeccapurple;"
      })

      owner = "error-page-#{error_page.id}"
      actor = actor(four)

      # Published, so the scope class the rule is keyed to reaches the stored 404 template — an
      # unsaved rule has no home in the record and is orphaned already.
      publish!(four)

      four_rules = MishkaCmsCore.Runtime.PageBuilder.ElementCss.all(actor, site.id, owner)
      assert map_size(four_rules) == 1, "the 404's rule was not written"

      # … and then the 500 is opened and published.
      {:ok, five, _html} = live(conn, base <> "?status=500")

      render_click(five, "save_element_css", %{
        "node_id" => node_with_tag(five, "h1").id,
        "css" => "color: teal;"
      })

      publish!(five)

      after_publish = MishkaCmsCore.Runtime.PageBuilder.ElementCss.all(actor, site.id, owner)

      for {scope, _body} <- four_rules do
        assert Map.has_key?(after_publish, scope),
               "publishing the 500 deleted the 404's element CSS"
      end
    end

    # NOTHING BUILDS A WRITE OUT OF A MOUNT-TIME SNAPSHOT. An error page's save is the whole
    # `error_pages` list with ONE entry replaced, and the list it was copied from was `@record` — the
    # record as this LiveView found it when it mounted. Two statuses open at once is the ordinary way
    # to edit an error page (the strip is a link per status, and each opens its own session), so the
    # second tab to publish wrote every other status back as it had been before the first tab
    # published: the 404 the author had just shipped was silently reverted, and both publishes had
    # reported success.
    #
    # The two tabs are opened BEFORE either publishes on purpose. Opening the 500 afterwards hands it
    # a record that already carries the 404's edit, which is the case that always worked and the
    # reason this went unnoticed.
    test "publishing one error-page status leaves a status published from another tab alone", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"

      {:ok, four, _html} = live(conn, base <> "?status=404")
      {:ok, five, _html} = live(conn, base <> "?status=500")

      render_click(four, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(four, "h1").id,
        "name" => "class",
        "value" => "four-oh-four"
      })

      publish!(four)

      assert by_status(live_error_page!(error_page))[404] =~ "four-oh-four",
             "the 404 tab did not publish"

      render_click(five, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(five, "h1").id,
        "name" => "class",
        "value" => "five-hundred"
      })

      publish!(five)

      by_status = by_status(live_error_page!(error_page))

      assert by_status[500] =~ "five-hundred"

      assert by_status[404] =~ "four-oh-four",
             "publishing the 500 put the 404 back as it was before it was published"
    end

    # AND THE PRUNE READS THE SAME RECORD, which nothing had ever asked it to prove. It keeps the
    # rules whose scope class some template of this record still wears, so a sibling template read
    # from a mount-time snapshot is a sibling missing whatever classes have been minted in it since —
    # and the rules behind them go from the one row all five statuses share. `sibling_trees/2` takes
    # the record the save just wrote for exactly this reason, and until the write stopped reverting
    # that sibling there was no way to tell whether it did.
    test "and the element CSS of a status published from another tab survives it", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"

      {:ok, four, _html} = live(conn, base <> "?status=404")
      {:ok, five, _html} = live(conn, base <> "?status=500")

      owner = "error-page-#{error_page.id}"
      actor = actor(four)

      render_click(four, "save_element_css", %{
        "node_id" => node_with_tag(four, "h1").id,
        "css" => "color: rebeccapurple;"
      })

      publish!(four)

      four_rules = MishkaCmsCore.Runtime.PageBuilder.ElementCss.all(actor, site.id, owner)
      assert map_size(four_rules) == 1, "the 404's rule was not written"

      render_click(five, "save_element_css", %{
        "node_id" => node_with_tag(five, "h1").id,
        "css" => "color: teal;"
      })

      publish!(five)

      after_publish = MishkaCmsCore.Runtime.PageBuilder.ElementCss.all(actor, site.id, owner)

      for {scope, _body} <- four_rules do
        assert Map.has_key?(after_publish, scope),
               "the 500's publish pruned the 404 against the record it mounted on"
      end

      assert map_size(after_publish) == 2, "the 500's own rule did not survive its publish"
    end

    # AND THE WRITE DOES NOT FALL BACK OFF THE STATUS IT IS ON. Reading the stored record at write
    # time means the editor can now find its own status gone — the error-page form edits the
    # collection as a whole, so a colleague can remove one — and "which entry should the editor open"
    # answers the 404 for anything it cannot find. Answering that HERE would put the work on the 404
    # and destroy it. The entry is written back instead.
    test "a status removed while its tab was open is appended, not landed on the 404", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      {:ok, _without_500} =
        error_page
        |> live_error_page!()
        |> Ash.Changeset.for_update(
          :master_update,
          %{
            error_pages: [
              %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}}
            ]
          },
          actor: actor(view)
        )
        |> Ash.update(actor: actor(view))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "five-hundred"
      })

      publish!(view)

      by_status = by_status(live_error_page!(error_page))

      assert by_status[500] =~ "five-hundred", "the removed status was not written back"

      refute by_status[404] =~ "five-hundred",
             "the write fell back to the 404 and put the 500's markup on it"
    end

    # THE SHAREABLE LINK HAS TO CARRY THE STATUS. An error page holds one template per status and the
    # editor is on exactly one of them; without `?status=` the preview fell back to its default, so
    # an author previewing the 500 they were editing was shown the 404.
    test "the shareable preview link carries the status being edited", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      # The link only appears once there is a draft to share.
      render_click(view, "save_as_draft", %{"label" => "Shareable"})

      href =
        view
        |> element("#pb-preview-tab")
        |> render()
        |> then(&Regex.run(~r/href="([^"]+)"/, &1, capture: :all_but_first))
        |> hd()

      assert href =~ "/_preview/error_page/"
      assert href =~ "?status=500", "the link previews whatever status the record defaults to"
    end

    test "and the offline page's link carries it as offline", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => "offline", "template" => ~s(<h1>Soon</h1>), "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=offline")

      render_click(view, "save_as_draft", %{"label" => "Shareable"})

      href =
        view
        |> element("#pb-preview-tab")
        |> render()
        |> then(&Regex.run(~r/href="([^"]+)"/, &1, capture: :all_but_first))
        |> hd()

      assert href =~ "/_preview/error_page/"
      assert href =~ "?status=offline", "the link previews the 404 instead of the offline page"
    end

    # And a section with one template gains no query string it has no use for.
    test "while a layout's link carries none", %{conn: conn, site: site} do
      {view, _record} = open(conn, :layout, site)

      render_click(view, "save_as_draft", %{"label" => "Shareable"})

      href =
        view
        |> element("#pb-preview-tab")
        |> render()
        |> then(&Regex.run(~r/href="([^"]+)"/, &1, capture: :all_but_first))
        |> hd()

      assert href =~ "/_preview/layout/"
      refute href =~ "?status="
    end

    test "a layout will not publish without the slot it exists for", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @layout_body)

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      slot = Enum.find(nodes(view), &(&1.kind == :eex))
      render_click(view, "op", %{"kind" => "delete", "node_id" => slot.id})

      assert publish!(view) =~ "Not published"
    end

    # A DRAFT OF AN ERROR PAGE IS A SNAPSHOT OF ALL FIVE, and the autosave has to put the edit in the
    # one being looked at. The session carries the status for exactly this — without it the write
    # fell back to the default entry, so working on the 500 quietly rewrote the 404.
    test "an error page's draft records the status being edited, not the default one", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      assert editor(view) |> Map.fetch!(:status) == 500, "the session did not record the status"

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "edited-on-500"
      })

      render_click(view, "save_as_draft", %{"label" => "Five hundred"})

      by_status = by_status(hd(drafts_of(error_page, actor(view))))

      assert by_status[500] =~ "edited-on-500"
      assert by_status[404] =~ "Not found", "the edit landed on the wrong status"
    end

    # AND SO DOES THE DRAFT WRITTEN ON THE WAY OUT. "Keep it as a draft" is the one control whose
    # whole purpose is not to lose work, and it reached past the wrapper every other draft write goes
    # through — so it left the status off the call, and the 500 the author was editing was filed
    # under 404, over a 404 they never opened. Publishing that draft afterwards put the 500's markup
    # on the site's 404, and the flash on the way out said the work had been kept.
    test "and so does the one written by leaving in publish mode", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      # Publish mode is the stage the leave prompt exists for: it writes nothing as you work, so the
      # draft under test here is the one that button makes and the only one of this sitting.
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "edited-on-500"
      })

      # Read while the editor is still standing: leaving takes it down, and the actor with it.
      recorded = actor(view)
      assert drafts_of(error_page, recorded) == [], "publish mode wrote before the button was hit"

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/error-pages"})
      view |> element("#pb-leave-save") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/error-pages")

      by_status = by_status(hd(drafts_of(error_page, recorded)))

      assert by_status[500] =~ "edited-on-500"
      assert by_status[404] =~ "Not found", "the way out filed the edit under the wrong status"
    end

    # AND KEYING ON THE STATUS MUST NOT COST THE RESUME, which is what stops a reload throwing work
    # away. Reopening the SAME status has to land back in the same session; a different status is a
    # different document and gets its own.
    #
    # The tree is what is asserted on, not the markup: an autosave may have turned the work into a
    # draft by now, and reopening deliberately detaches to the live template with that draft offered
    # by the bar — see `own_session_or_open/5`. The session identity is the thing under test.
    test "reopening the same status lands in the same session, another status does not", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => ~s(<h1>Not found</h1>), "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"
      {:ok, view, _html} = live(conn, base <> "?status=500")

      {:ok, same, _html} = live(conn, base <> "?status=500")
      assert token(same) == token(view), "the same status opened a different session"

      {:ok, other, _html} = live(conn, base <> "?status=404")
      refute token(other) == token(view), "two statuses shared one session"

      assert source(other) =~ "Not found"
      assert editor(other) |> Map.fetch!(:status) == 404
    end

    test "an error page publishes into the status entry it opened on", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => @body, "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "five-hundred"
      })

      publish!(view)

      by_status = by_status(live_error_page!(error_page))

      assert by_status[500] =~ "five-hundred"
      assert by_status[404] =~ "Body text", "the other status was written over"
    end

    # AND SO DOES ONE OPENED BY INVITATION. `?session=<token>` joins the session someone else is in
    # and carries nothing else — no `?status=`, because the status is the SESSION'S and the invited
    # browser is not choosing one. The editor asked the URL anyway and got the default back, so a
    # co-editor sat on the 500 the canvas showed them and published it over the live 404.
    test "an error page joined by invitation publishes into the status the session is on", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => @body, "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"
      {:ok, host, _html} = live(conn, base <> "?status=500")
      {:ok, guest, _html} = live(conn, base <> "?session=#{token(host)}")

      assert token(guest) == token(host), "the invitation opened a session of its own"

      render_click(guest, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(guest, "h1").id,
        "name" => "class",
        "value" => "joined-on-500"
      })

      publish!(guest)

      by_status = by_status(live_error_page!(error_page))

      assert by_status[500] =~ "joined-on-500"
      assert by_status[404] =~ "Body text", "the guest published onto a status nobody opened"
    end

    # AN ADDRESS THAT NAMES BOTH IS TWO ANSWERS TO ONE QUESTION. A token points at a canvas and
    # `?status=` names an entry; when they disagree the reader asked for the 404 in words, so the
    # token is refused and the 404 opens on its own rather than the host's 500 being handed over.
    test "a token that disagrees with an explicit status is refused", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => @body, "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"
      {:ok, host, _html} = live(conn, base <> "?status=500")
      {:ok, guest, _html} = live(conn, base <> "?session=#{token(host)}&status=404")

      refute token(guest) == token(host), "the token overrode the status that was asked for"
      assert editor(guest).status == 404
      assert source(guest) =~ "Body text"

      render_click(guest, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(guest, "h1").id,
        "name" => "class",
        "value" => "asked-for-404"
      })

      publish!(guest)

      by_status = by_status(live_error_page!(error_page))

      assert by_status[404] =~ "asked-for-404"
      assert by_status[500] == ~s(<h1>Boom</h1>), "the host's status was written over"
    end

    # THE INVITATION HAS TO SAY WHICH ENTRY, not only which session. A token is alive for as long as
    # the session is, and a link pasted into a chat is followed later — with the status in it the
    # canvas that opens is the one the inviter was on either way.
    test "the invitation link carries the status the session is on", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => @body, "layout" => %{}},
            %{"status" => 500, "template" => ~s(<h1>Boom</h1>), "layout" => %{}}
          ]
        )

      base = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"
      {:ok, host, _html} = live(conn, base <> "?status=500")

      url = share_url(host)
      assert url =~ "session=#{token(host)}"
      assert url =~ "status=500"

      {:ok, guest, _html} = live(conn, url)
      assert token(guest) == token(host), "the link it hands out does not join the session"

      # And once the session is gone the status is the only answer left in it.
      EditorSession.close(token(host))

      {:ok, late, _html} = live(conn, url)
      refute token(late) == token(host)
      assert editor(late).status == 500
      assert source(late) =~ "Boom", "a late invitation opened the default entry"
    end

    # The page an offline site shows is an entry too, and an invitation to it lands on it.
    test "an invitation to the offline page names it", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => "offline", "template" => "<h1>Soon</h1>", "layout" => %{}}
          ]
        )

      {:ok, host, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=offline")

      url = share_url(host)
      assert url =~ "session=#{token(host)}"
      assert url =~ "status=offline"
    end

    # And a section with one template gains no query string it has no use for.
    test "while a page's invitation carries none", %{conn: conn, site: site} do
      {view, _record} = open(conn, :page, site)

      url = share_url(view)

      assert url =~ "session=#{token(view)}"
      refute url =~ "status="
    end

    # NOR DOES A DOCUMENT THAT DOES NOT EXIST. An error page being made has no entries, so the
    # status there is the default standing in for nothing — a reader sent to `?status=404` is being
    # told about an entry the inviter has not written.
    test "nor does an error page nobody has created yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/error-page")

      assert share_url(view) ==
               "/admin/dashboard/runtime/builder/error-page?session=#{token(view)}"
    end

    # AND A TOKEN THAT IS NOT ONE YET IS NOT AN INVITATION. `:token` is `false` until the socket
    # connects, and `?session=false` hands a colleague a session that never existed; the bare
    # address opens the document, which is the half of the offer that still means something.
    test "and the render before the socket connects names no session" do
      assert BuilderLive.share_url(%{
               section: "error-page",
               record: %{id: "0b1d"},
               token: false,
               editor: %{status: 500}
             }) == "/admin/dashboard/runtime/builder/error-page/0b1d"
    end
  end
end
