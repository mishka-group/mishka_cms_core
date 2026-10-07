defmodule MishkaCmsCoreWeb.Test.BuilderLiveTest do
  @moduledoc """
  End-to-end tests for the visual page builder, driven through the real LiveView.

  Everything here is asserted by stable `pb-*` DOM id, which is the house rule and also the thing
  that makes this suite survive a restyle. The React editor had no test of this kind at any level,
  which is how it shipped with a save endpoint that was never routed.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.ErrorAddress
  alias MishkaCmsCore.Runtime.PageBuilder.CodeAccess
  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck
  alias MishkaCmsCore.Runtime.PageBuilder.Conditions
  alias MishkaCmsCore.Runtime.PageBuilder.Drafts
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageBuilder.Interface
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.PageStarter
  alias MishkaCmsCore.Runtime.PageBuilder.SeoSettings
  alias MishkaCmsCore.Runtime.PageBuilder.Blocks
  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.BuilderBlockPlugin, as: BlockPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderJsHookPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderPageStarterPlugin, as: PageStarterPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderFormCreatedProbe, as: FormCreatedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderFormCustomizedProbe, as: FormCustomizedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderFormRenamedProbe, as: FormRenamedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarInvokedProbe, as: ToolbarInvokedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarProbe, as: ToolbarProbe
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @password "Password123!"
  @template ~s(<section id="hero"><h1>Contact Us</h1><p>Reach out any time.</p></section>)

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    page = create_page!(site_id: site.id, template: @template)

    # `SiteState` is process-global ETS, not sandboxed, so a cached site outlives this test's
    # transaction. Leaving "localhost" behind breaks any sibling that asserts a host does NOT
    # resolve — which is exactly how it broke ApiTenantLookupPlugTest.
    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, create_admin("boss@example.com")), site: site, page: page}
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

  # A REAL USER WITH NOTHING GRANTED. `create_admin/2` assigns `*`, which passes every policy in
  # the CMS; what is wanted here is an actor the resource has no reason to allow.
  defp create_user_without_permissions(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    user
  end

  # A fresh conn on a site's own address, the test host unless told — the setup's conn is already
  # signed in as the master.
  defp build_conn_for_host(host \\ "localhost") do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Save moved off the top bar into the ••• menu when the header was matched to the prototype: the
  # editor autosaves, so the bar has a stage control where the prototype has one and nothing else.
  defp save!(view), do: more!(view, "#pb-save")

  # Writing the live record is Publish, and Publish is two gestures: the stage is chosen, then the
  # button beside it carries it out.
  defp publish!(view) do
    render_click(view, "set_stage", %{"stage" => "published"})
    render_click(view, "apply_stage", %{})
  end

  # THE MODAL OPENS BEFORE ITS EXAMPLES ARE CURATED (`assign_async(:examples, …)` in
  # `show_examples`), so a test that inserts, picks or reads a variant straight after the click is
  # racing that read — and on a busy run loses it: `insert_example` finds no example at its index and
  # quietly inserts nothing. Awaited once, here.
  defp show_examples!(view, name) do
    render_click(view, "show_examples", %{"name" => name})
    render_async(view)
  end

  defp undo!(view), do: more!(view, "#pb-undo")
  defp redo!(view), do: more!(view, "#pb-redo")

  # The ••• button TOGGLES, so opening an already-open menu closes it — two menu actions in a row
  # then fail to find the second item.
  defp more!(view, id) do
    unless has_element?(view, id), do: view |> element("#pb-more-btn") |> render_click()
    view |> element(id) |> render_click()
  end

  # The palette is read asynchronously so the editor paints before 183 components arrive. Every test
  # that looks at a palette card, or at anything the components feed (the inspector's property list,
  # the canvas's site binding), needs them to have landed — so the helper awaits them once, here,
  # rather than each test remembering to.
  # A SECOND PERSON, not a second tab. Two tabs of one account resume the SAME editing session and
  # share its topic, so they would prove nothing about the thread reaching somebody it has no session
  # with. `System.unique_integer/1` keeps the address unique across a run.
  defp colleague(conn) do
    email = "colleague#{System.unique_integer([:positive])}@example.com"
    log_in(conn, create_admin(email))
  end

  defp open_builder(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    {:ok, view, render_async(view)}
  end

  # THE STUDIO'S OWN ASYNC STARTS WHEN THE SHEET OPENS, which is after `open_builder/2` has already
  # awaited the editor's. The token list is a Gervaz table and the generated export is built from an
  # assign that lands with it, so a test that reads either of them straight after the click is
  # reading a skeleton — and whether it passes depends on how warm the run is. Three of the tests
  # below passed in a full run of this file and failed on their own.
  defp open_studio(conn, page) do
    {:ok, view, _html} = open_builder(conn, page)
    view |> element("#pb-studio") |> render_click()
    _settled = render_async(view)
    view
  end

  # THE ROW AS IT REALLY IS, read back through the same actor the editor writes with. Reading it
  # with `nil` answers `%{}` whatever is in the database — which makes "the rule is gone" pass for
  # the wrong reason, and is how the first version of these two tests fooled itself.
  defp stored_element_css(view, page) do
    actor = :sys.get_state(view.pid).socket.assigns.current_user
    ElementCss.all(actor, page.site_id, "page-#{page.id}")
  end

  # Autosave is a no-op while nothing has changed, so there has to be an edit for it to write.
  defp autosave!(view) do
    render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
    _written = render_async(view)
    editor(view).draft_id
  end

  # A DRAFT WRITE HELD OPEN, so a test can put an edit between the write starting and its answer and
  # have that order every run rather than on a slow machine. The plugin passes every write through
  # until this process is the one registered to be told about them.
  defp pause_draft_writes do
    Process.register(self(), MishkaCmsCore.Test.Plugins.BuilderDraftPausePlugin.waiter())

    register_plugin(
      MishkaCmsCore.Test.Plugins.BuilderDraftPausePlugin,
      "builder:draft:before_save"
    )
  end

  # EVERY DRAFT WRITE REFUSED AT THE GATE, which is the state the tests using this are about: what
  # the editor does with a draft an extension would not let it write.
  defp refuse_draft_writes,
    do:
      register_plugin(
        MishkaCmsCore.Test.Plugins.BuilderDraftGatePlugin,
        "builder:draft:before_save"
      )

  # And the announcement on the other side of the write, sent here because it is made in the
  # LiveView's process rather than this one.
  defp watch_draft_announcements do
    Process.register(self(), MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe.waiter())

    register_plugin(
      MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe,
      "builder:draft:after_save"
    )
  end

  # A plugin registered for the length of one test, exactly as an extension registers one.
  defp register_plugin(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  # The resume bar is computed once, at mount, and only for a session that has no draft of its own —
  # so the work has to be left behind by a session that is then closed.
  defp resumable_session(conn, page) do
    {:ok, first, _html} = open_builder(conn, page)
    autosave_id = autosave!(first)
    EditorSession.close(token(first))

    {:ok, view, _html} = open_builder(conn, page)
    {autosave_id, view}
  end

  # The canvas renders a runtime component by resolving the module the compilers WOULD have built for
  # it — a name hashed from the component name plus its site. Putting a module at that hashed name by
  # hand keeps these tests about the resolution itself, without booting the whole compile pipeline.
  defp history_rows(page) do
    MishkaCmsCore.Runtime.PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(source_id == ^page.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  # A change on the live page's own branch, written as `actor` the way the editor writes one.
  defp record_change(page, actor, label) do
    MishkaCmsCore.Runtime.PageBuilderEvent
    |> Ash.Changeset.for_create(
      :create,
      %{
        id: Ecto.UUID.generate(),
        source_type: :page,
        source_id: page.id,
        site_id: page.site_id,
        label: label,
        kind: :content,
        op: :set_text,
        target: "<h1>",
        author_type: :human
      },
      tenant: page.site_id,
      actor: actor,
      authorize?: false
    )
    |> Ash.create!(actor: actor, authorize?: false)
  end

  # An assistant's change on the live page's own branch, asked for by `actor`.
  defp record_assistant_change(page, actor, label) do
    MishkaCmsCore.Runtime.PageBuilderEvent
    |> Ash.Changeset.for_create(
      :create,
      %{
        id: Ecto.UUID.generate(),
        source_type: :page,
        source_id: page.id,
        site_id: page.site_id,
        label: label,
        kind: :content,
        op: :set_text,
        target: "<h1>",
        author_type: :ai,
        prompt: "add social proof",
        backend: "claude"
      },
      tenant: page.site_id,
      actor: actor,
      authorize?: false
    )
    |> Ash.create!(actor: actor, authorize?: false)
  end

  # The avatar row's letters: yours first, then everyone else's.
  defp avatars(view),
    do:
      view
      |> element("#pb-avatars")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pb-avatars > span")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp history_author(view, row),
    do:
      view
      |> element("#pb-history-author-#{row.id}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  defp snapshots do
    MishkaCmsCore.Runtime.PageBuilderSnapshot
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.read!(authorize?: false)
  end

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token

  defp example_path(token, name, index),
    do: "/admin/dashboard/runtime/builder-canvas/#{token}/example/#{name}/#{index}"

  defp editor_messages(view), do: :sys.get_state(view.pid).socket.assigns.ai_messages

  # An element's own opening tag, for asserting on ITS classes rather than its children's.
  defp opening_tag(html), do: html |> String.split(">", parts: 2) |> hd()

  # A palette entry as the panel sees it, for asserting on what the card would draw.
  defp entry(view, name) do
    view |> editor() |> Map.fetch!(:components) |> Enum.find(&(&1.name == name))
  end

  defp editor(view), do: elem(EditorSession.fetch(token(view)), 1)

  # THE ON-CLICK FORM AND NOTHING ELSE. `render(view)` is the whole editor, where `value="is-open"`
  # appears in the Attributes list too — an assertion against the whole page passes for the wrong
  # reason and keeps passing when the box it is about has gone.
  defp inspector_html(view) do
    case view |> render() |> String.split(~s(id="pb-act-form-), parts: 2) do
      [_before, rest] -> rest |> String.split("</form>", parts: 2) |> hd()
      [_none] -> ""
    end
  end

  # A component that declares one required property and one required slot, and one optional property
  # beside them — the smallest shape that can tell the marked apart from the unmarked.
  defp needy(site) do
    create_component!(
      site_id: site,
      name: "needful",
      template:
        ~s|<figure><img src={@src} alt={@alt} /><figcaption>{render_slot(@caption)}</figcaption></figure>|,
      attrs: [
        %{"name" => "src", "type" => "string", "opts" => %{"required" => true}},
        %{"name" => "alt", "type" => "string", "opts" => %{}}
      ],
      slots: [%{"name" => "caption", "opts" => %{"required" => true}, "attrs" => []}]
    )
  end

  defp needful_node(view),
    do:
      view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :component))

  # OPEN, NOT TOGGLED. `default_expanded/1` already opens the roots and the level below them, so a
  # page whose only root is the component under test starts open — and `toggle_expand` would shut it.
  defp expand!(view, id) do
    open? = view |> element(~s([data-layer-row="#{id}"])) |> render() =~ ~s(data-open="true")
    unless open?, do: render_click(view, "toggle_expand", %{"id" => id})
    :ok
  end

  # Every row the layers rail offers as a drop target, by the id a drop would resolve to.
  defp rail_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter("[data-layer-row]")
    |> LazyHTML.attribute("data-layer-row")
    |> Enum.uniq()
  end

  # Which width the frame is showing. Session state on the LiveView rather than in the document, so
  # it is read the same way the canvas hrefs are.
  defp device(view), do: :sys.get_state(view.pid).socket.assigns.device

  defp breakpoint(view), do: :sys.get_state(view.pid).socket.assigns.breakpoint

  # The compiled bundles the frame is served. Read off the LiveView rather than out of its HTML,
  # because the `<link>` is rendered by the root layout — see the canvas tests for why it moved.
  defp css_hrefs(view), do: :sys.get_state(view.pid).socket.assigns.canvas_css_hrefs

  defp newest_history_row(page) do
    MishkaCmsCore.Runtime.PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(source_id == ^page.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # The sheet's kind pills are Gervaz's own filter form, so they are driven as a form change rather
  # than as bespoke clicks — the table owns what a filter means.
  # The table re-reads on a filter change, so the answer arrives after the change rather than in it.
  defp filter_history(view, kind) do
    view
    |> element("#pb-history-table_page_builder_events-filter")
    |> render_change(%{"kind" => kind})

    render_async(view)
  end

  # The page's code fragments live on the LiveView rather than in the editing session: they are Page
  # attributes, not part of the tree, and they ride the page's own Save.
  defp fragments(view), do: :sys.get_state(view.pid).socket.assigns.fragments

  # The palette stays mounted and hides, so "is the palette showing?" is a class question rather than
  # an existence one — see the `hidden` attr on `Panels.palette/1`.
  defp palette_hidden?(view) do
    assert has_element?(view, "#pb-palette"), "the palette stays mounted"
    has_element?(view, ~s(#pb-palette[data-showing="false"]))
  end

  # The signed-in user as the LiveView holds it — what `Drafts` needs to read the same rows the
  # editor does. Read BEFORE an action that navigates away, because the process goes with it.
  defp actor(view), do: :sys.get_state(view.pid).socket.assigns.current_user

  # A REFRESH, not a second tab. The editing session lives in ETS and deliberately outlives the
  # LiveView, so reopening while the first one is still mounted models TWO editors on one document —
  # both of them autosaving — rather than one person pressing reload. Stopping the process first is
  # what a closed tab does: `terminate/2` announces the close and leaves the session alone.
  defp reopen(view, conn, page) do
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000

    {:ok, again, _html} = open_builder(conn, page)
    again
  end

  # The document is rendered by the canvas LiveView inside the iframe, so the chrome's HTML never
  # contains it. Serializing the session tree is how a test sees what is being edited.
  # Scoped the way the Studio panel scopes it: this site's snippets plus the global ones, for this
  # editor and the document it has open.
  # JOINED THROUGH THE COMPONENT, not filtered on the version's own `site_id`: a master action is
  # required to carry no tenant, and the version row takes its site from the tenant, so a master's
  # version has none. Which component it is about is never in doubt.
  defp component_versions(site) do
    %{rows: rows} =
      MishkaCmsCore.Repo.query!(
        """
        SELECT v.id::text, v.user_id::text
        FROM component_versions v
        JOIN components c ON c.id = v.version_source_id
        WHERE c.site_id = $1
        """,
        [Ecto.UUID.dump!(site.id)]
      )

    Enum.map(rows, fn [id, user_id] -> %{id: id, user_id: user_id} end)
  end

  defp site_component_names(site) do
    site_id = site.id

    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(page: [limit: 500])
    |> Map.fetch!(:results)
    |> Enum.map(& &1.name)
  end

  defp saved_snippets(site, record) do
    MishkaCmsCore.Runtime.PageBuilder.Snippets.list(%{
      site_id: site.id,
      section: :page,
      document_id: record.id,
      actor: create_user_with_permissions!(["*"])
    })
  end

  defp editor_html(view) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize()
  end

  defp component_node(view, name) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> Tree.walk()
    |> Enum.find(&(Node.component_name(&1) == name))
  end

  defp headings(nodes), do: Enum.count(nodes, &(&1.tag == "h1"))

  defp node_parent(view, id),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id) |> Map.fetch!(:parent_id)

  # The `{@inner_content}` chip — a layout's one obligation, and the node most of these tests act on.
  defp expression_node(view),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :eex))

  defp node_with_tag(view, tag) do
    view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.tag == tag))
  end

  defp node_count(view), do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

  # WHATEVER IS ON SCREEN, both notices at once: a flash is the only place a refused command speaks
  # to the author, and which of the two it picks is not the point of the assertions below. The tags
  # come off first — Tailwind writes `hover:bg-white` into the class list, which reads exactly like
  # an inspected atom to anything looking for one.
  defp flashes(view) do
    ["#flash-info", "#flash-error"]
    |> Enum.filter(&has_element?(view, &1))
    |> Enum.map_join(" ", &(view |> element(&1) |> render() |> String.replace(~r/<[^>]*>/, "")))
    |> String.trim()
  end

  # A flash is set, never unset: nothing on the server clears one, and the hook that pushes
  # `lv:clear-flash` after the fade does not run here — so a stale sentence would answer for the
  # next command and hide a handler that went silent.
  defp clear_flashes(view) do
    for key <- ~w(info error), do: render_click(view, "lv:clear-flash", %{"key" => key})
    view
  end

  # AN INSPECTED TERM WHERE A SENTENCE BELONGS: a map, a tuple, or a bare atom reason. Every one of
  # them is an internal the author has no word for, and all three read the same way in a flash.
  defp internals?(text), do: text =~ ~r/%\{|\{:|:[a-z_]/

  # How an attribute is HELD, which is what a row that shows it can corrupt: `{:expr, source}` is a
  # binding, `{:string, text}` is words, `:boolean` is a bare attribute.
  defp attr_of(view, id, name),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id) |> Node.attr(name)

  # The value a box is offering — what the browser posts straight back when the author clicks into
  # the row and leaves it alone.
  defp field_value(view, id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id="#{id}"]))
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  # A row committed the way the browser commits one, through the form that owns it. Addressed by
  # attribute and not by `#id`: `:if` is an attribute name, and a colon in a CSS id selector is a
  # pseudo-class.
  defp commit_row(view, form_id, value),
    do: view |> element(~s(form[id="#{form_id}"])) |> render_change(%{"value" => value})

  # A value the property will take, for walking the whole vocabulary. An enumerated one must be one
  # of its own; a free-form one is never validated, so any length does.
  defp sample_style(prop), do: prop |> Styles.options() |> List.first("7px")

  # The style overrides a node actually carries — what every control in the Layout and Appearance
  # sections is a way of writing, and the only record of them there is.
  defp styles_of(view, node_id),
    do:
      view
      |> editor()
      |> Map.fetch!(:tree)
      |> Tree.get(node_id)
      |> then(&Map.get(&1.meta, :styles, %{}))

  defp declared_forms(view),
    do: view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() |> PageForms.declared()

  # A comment carries no tag, so it is found by kind instead.
  defp node_with_kind(view, kind) do
    view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == kind))
  end

  # One per row in the Studio's token list: every row has an editable value field, and only rows do.
  defp token_rows(html), do: length(String.split(html, ~s(id="pb-token-value-))) - 1

  describe "mount" do
    test "renders the editor shell", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-root")
      assert has_element?(view, "#pb-left")
      assert has_element?(view, "#pb-right")

      # The top bar has the prototype's stage split-button and no Save — the editor autosaves, and
      # "Save draft now" lives in the ••• menu, which is folded away in the markup rather than
      # fetched: `#pb-more-btn` toggles it in the browser and never reaches this process.
      assert has_element?(view, "#pb-stage")
      assert has_element?(view, "#pb-stage-menu")
      assert has_element?(view, "#pb-more-menu.hidden")
      assert view |> element("#pb-more-btn") |> render() =~ "#pb-more-menu"

      assert has_element?(view, "#pb-save")
      assert has_element?(view, "#pb-undo")
      assert has_element?(view, "#pb-redo")
    end

    # The editor takes the whole viewport, like the prototype: no admin sidebar, no admin topbar, no
    # 1340px content column. It is a `h-screen` three-column workspace, and nesting it in the admin
    # shell's scrolling, padded, width-capped `<main>` costs it the canvas and adds a second
    # scrollbar. Every other admin page keeps the shell — this is the one exception, so it is pinned.
    test "the editor is a full page: no admin sidebar, topbar or content column", %{
      conn: conn,
      page: page
    } do
      {:ok, view, html} = open_builder(conn, page)

      refute has_element?(view, "#admin-sidebar")
      refute html =~ "max-w-[1340px]"
      refute html =~ "Admin console"

      # The shell's own two contributions are still there: the theme treatment and flashes.
      assert html =~ "data-theme=dark"
      assert has_element?(view, "#pb-root")
    end

    test "an error still surfaces without the admin shell's flash group", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{"kind" => "delete", "node_id" => "nnotanode"})

      assert has_element?(view, "#flash-error")
    end

    test "parses the page's template into a session tree", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      tags = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.tag)

      assert "section" in tags
      assert "h1" in tags
      assert "p" in tags
    end

    test "embeds the canvas iframe addressed by the session token", %{conn: conn, page: page} do
      {:ok, view, html} = open_builder(conn, page)

      assert html =~ "/admin/dashboard/runtime/builder-canvas/#{token(view)}"
      assert has_element?(view, "#pb-frame-desktop")
    end

    test "every device button is present", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      for device <- ~w(frames desktop tablet mobile) do
        assert has_element?(view, "#pb-device-#{device}")
      end
    end

    test "an unknown section redirects instead of crashing", %{conn: conn} do
      assert {:error, {:redirect, _redirect}} =
               live(conn, "/admin/dashboard/runtime/builder/spreadsheet")
    end

    test "a new page opens an empty document", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")

      assert view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) == []
    end
  end

  describe "the canvas LiveView" do
    # WHAT AN EMPTY PAGE OFFERS. The dashed well this replaces told the reader to "pick a
    # component on the left", which asks someone who has never built a page to already know what the
    # first thing should be. The chooser answers that question once and then gets out of the way.
    test "an empty page offers the starter, and picking one fills it", %{conn: conn, site: site} do
      empty =
        create_page!(
          site_id: site.id,
          template: MishkaCmsCore.Runtime.PageBuilder.PageStarter.blank()
        )

      {:ok, view, _html} = open_builder(conn, empty)

      # Emptied right back out — the same state a page created with no markup opens in once its one
      # container is removed.
      render_click(view, "op", %{"kind" => "delete", "node_id" => hd(editor(view).tree.roots)})
      assert editor(view).tree.roots == []

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-page-starter"
      assert html =~ "This page is empty"
      assert html =~ "pb-starter-two"
      refute html =~ "Choose a layout", "Runtime's Layout is a different thing entirely"

      render_click(canvas, "page_starter", %{"structure" => "two"})

      tree = editor(view).tree
      assert length(tree.roots) == 1, "a structure arrives as ONE undoable insert"
      assert MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize(tree) =~ "grid-cols-2"
    end

    # AND A STARTER AN EXTENSION BROUGHT IS ONE OF THEM. The chooser has always drawn the merged
    # list, while the click was resolved against the core's four alone — so a plugin's card was a
    # button with nothing behind it: no structure, no error, and nothing in the log either.
    test "a contributed starter lays out its own structure", %{conn: conn, site: site} do
      register_plugin(PageStarterPlugin, "builder:page_starters")
      structure = PageStarterPlugin.structure()

      empty = create_page!(site_id: site.id, template: PageStarter.blank())
      {:ok, view, _html} = open_builder(conn, empty)
      render_click(view, "op", %{"kind" => "delete", "node_id" => hd(editor(view).tree.roots)})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-starter-#{structure.id}")
      assert has_element?(canvas, "#pb-starter-two"), "beside the core's own"

      canvas |> element("#pb-starter-#{structure.id}") |> render_click()

      tree = editor(view).tree
      assert length(tree.roots) == 1, "a structure arrives as ONE undoable insert"
      assert Serializer.serialize(tree) =~ "grid-cols-[2fr_1fr]"
    end

    test "an unknown structure is a no-op, not a crash", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      before = editor(view).tree
      render_click(canvas, "page_starter", %{"structure" => "no-such-thing"})
      assert editor(view).tree == before
    end

    # A page with something on it is a page someone is already working on.
    test "a page with content is not interrupted by the chooser", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ ~s(id="pb-page-starter")
    end

    # THE FORMATTER PUTS A NEWLINE BETWEEN EVERY PAIR OF CHILDREN, so a grid authored tight comes
    # back from its first save with a whitespace run between each card. Those runs are real nodes and
    # cannot be dropped — `<a>one</a> <a>two</a>` would lose its space — but a box around one is a
    # grid ITEM: an empty cell in the middle of the card row, selectable, and with nothing in the
    # layers panel to match it, because the panel has always hidden them.
    #
    # They stay in the DOM: the drop resolver counts DOM children to work out an insertion index, so
    # a child missing here shifts every index after it.
    test "indentation between tags gets no box of its own", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: "<div class=\"grid\">\n  <p>One</p>\n  <p>Two</p>\n</div>"
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      nodes = Tree.walk(editor(view).tree)
      blanks = Enum.filter(nodes, &(&1.kind == :text and &1.meta[:whitespace?]))

      assert length(blanks) == 3, "the fixture is indented, so the grid has runs around each <p>"

      for node <- blanks do
        assert html =~ ~s(data-node-id="#{node.id}"), "the run must still be a DOM child"
        refute html =~ ~s(phx-value-id="#{node.id}"), "and must not be selectable"
      end

      # `display: contents` is a rule in `#pb-canvas-ui` now rather than a `style` attribute — a
      # Content-Security-Policy has no nonce to offer an attribute — so the marker the rule is keyed
      # on is what there are three of.
      assert length(String.split(html, ~s(data-kind="text" data-ws="true"))) - 1 == length(blanks)
      assert html =~ ~s([data-ws="true"] { display: contents; })

      words = Enum.find(nodes, &(&1.kind == :text and &1.text == "One"))
      assert html =~ ~s(phx-value-id="#{words.id}"), "text with words in it is still selectable"
    end

    # AND A CONTAINER THAT HAS BEEN EMPTIED IS STILL EMPTY. Taking the last thing out of one leaves
    # the indentation that used to sit around it, so `children` reads as a list of blanks rather than
    # `[]` — and the floor that makes a 0px box droppable disappeared at the exact moment it was
    # needed most.
    test "a container holding nothing but indentation still gets a floor", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: "<section id=\"hero\">\n</section>")

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      tree = editor(view).tree
      [root] = tree.roots

      assert Tree.get(tree, root).children != [], "the fixture is meant to keep its newline"
      assert html =~ "min-height:56px", "the emptied section needs somewhere to aim"
    end

    # THE CANVAS DOES NOT WANT THE ADMIN'S STYLESHEET. It renders a SITE's document, and its own
    # chrome — the selection ring, the component chip, the "needs id" placeholder — is inline styles
    # computed from session state. It used to download all 2.5 MB of `admin.css` anyway, because one
    # `full_tailwind` assign gated the stylesheet and the two web fonts together, and the frames view
    # mounts three of these iframes at once.
    #
    # Asserted on the ASSIGNS rather than the rendered head: the root layout belongs to the host app,
    # which the test endpoint does not use. The layout's half of the contract is one `:if` per link
    # (`assigns[:admin_css]`, `assigns[:admin_fonts]`, `assigns[:live_tailwind]`), so pinning what the
    # canvas sets pins what it loads.
    # AN IFRAME IS BLANK UNTIL ITS DOCUMENT PAINTS, and the canvas frame loads a whole LiveView —
    # with nothing behind it the editor shows an empty rectangle and no reason for the wait. The
    # spinner sits UNDER the frame rather than replacing it: swapping the element out would restart
    # the load, so it could never finish.
    test "the canvas frame shows why it is empty while it loads", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert html =~ "Loading the canvas",
             "the canvas frame renders with nothing to explain the blank rectangle"
    end

    test "asks for fonts and the generator, never the admin stylesheet", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assigns = :sys.get_state(canvas.pid).socket.assigns

      refute assigns[:admin_css], "the canvas must not pull the dashboard's stylesheet"
      assert assigns[:admin_fonts], "its chrome names the admin faces in inline `font:` shorthand"
      assert assigns[:live_tailwind], "a class typed in the inspector must exist a frame later"
    end

    # THE FAST WAY TO THE ONE THING PEOPLE CHANGE. Everything else on the element toolbar acts at
    # once; layout is a choice, so the bar grows a row of shapes rather than sending the reader off
    # to the Inspector. It offers only what the component itself declares.
    test "the toolbar's layout button opens column shapes for a grid", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "tbgrid",
        template: ~s|<div class="grid">g</div>|,
        attrs: [
          %{
            "name" => "cols",
            "type" => "string",
            "opts" => %{"values" => ~w(one two three four), "default" => "two"}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-tbgrid") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-eltb-layout"), "the four-way arrow is on the toolbar"

      # The row is RENDERED with the selection and revealed in the browser — asking the server to
      # show a row already on the page would patch the toolbar and drop it out of the top layer.
      assert has_element?(canvas, "#pb-eltb-cols"), "the row ships with the selection"

      assert render(canvas) =~ "#pb-eltb-cols { display: none;",
             "and starts hidden, for the hook to open"

      assert has_element?(canvas, "#pb-eltb-cols-four")

      refute render(canvas) =~ ~s(id="pb-eltb-layout" phx-click),
             "the arrow carries no server event at all"

      # THE VALUE MUST RIDE THE BUTTON'S OWN `value`. LiveView's `extractMeta` writes
      # `meta.value = el.value` AFTER collecting `phx-value-*`, so `phx-value-value` on a button is
      # always overwritten with "". `render_click/1` sends the attribute map WITHOUT that override,
      # so it passes either way — this is the only thing that catches it.
      shape = canvas |> element("#pb-eltb-cols-four") |> render()

      assert shape =~ ~s(value="four"),
             "the shape carries its value where the browser will read it"

      refute shape =~ "phx-value-value", "and never where the browser will blank it"

      # THE PANEL MUST OUTLIVE A CHOICE. Choosing writes to the document, so the server re-renders
      # this element — and a patch takes back the `display` the hook wrote, leaving the rule's own
      # `none` underneath. The hook holds the open flag and re-applies it in `placeToolbar`, which
      # `updated()` already calls, so a reader can try six options without reopening between each
      # one. All the server may ever say is "shut"; rendering it open would fight the browser for
      # the same property.
      assert render(canvas) =~ "#pb-eltb-cols { display: none;",
             "the server always renders the panel shut and never tries to render it open"

      canvas |> element("#pb-eltb-cols-four") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Map.fetch!(:attrs)
             |> Map.new()
             |> Map.get("cols") == {:string, "four"}
    end

    # DIRECTION, SPREAD, ALIGN AND WRAP, each drawn as a picture of what it does — and each writing
    # the same `:set_style` op the Inspector writes, so the two panels cannot disagree and the
    # Tailwind class is `Styles`' business rather than the toolbar's.
    test "the layout panel writes flex classes into the chosen breakpoint", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # Direction only means something once the container is a row, so it appears with it.
      refute has_element?(canvas, "#pb-eltb-direction-flex-row")
      canvas |> element("#pb-eltb-display-flex") |> render_click()
      assert has_element?(canvas, "#pb-eltb-direction-flex-row")

      canvas |> element("#pb-eltb-justify-justify-between") |> render_click()
      canvas |> element("#pb-eltb-align-items-center") |> render_click()

      assert styles_of(view, node.id) == %{
               base: %{
                 "display" => "flex",
                 "justify" => "justify-between",
                 "align" => "items-center"
               }
             }

      # …and the same control, aimed at Mobile, writes a bucket of its own.
      canvas |> element("#pb-eltb-at-mobile") |> render_click()
      canvas |> element("#pb-eltb-direction-flex-col") |> render_click()

      assert styles_of(view, node.id)[:mobile] == %{"direction" => "flex-col"}
    end

    # Pressing the chosen one again clears it, so an element can go back to inheriting.
    test "choosing the same layout option twice clears it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      canvas |> element("#pb-eltb-display-grid") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"display" => "grid"}}

      canvas |> element("#pb-eltb-display-grid") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    # A DEAD BUTTON IS WORSE THAN NO BUTTON. Display works on any element, so the arrow always has
    # something to show; column shapes follow only when the component says which counts it lays out.
    test "a plain element still gets a layout row, without columns", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-eltb-display-flex"), "display is offered on anything"
      refute has_element?(canvas, "#pb-eltb-cols-four"), "but a section has no column count"

      canvas |> element("#pb-eltb-display-grid") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> then(& &1.meta.styles) == %{base: %{"display" => "grid"}}
    end

    # The composer is a Gervaz form: `phx-submit="save"` on the component, params under "form".
    #
    # The trailing `render/1` is not decoration. Saving sends `{:form_saved, …}` to the LiveView, and
    # the badge is recomputed when THAT is handled — one message after the submit's own reply. Without
    # a render in between, the test client is still holding the HTML from before the note existed.
    # THE THREAD RE-READS ASYNCHRONOUSLY. Gervaz loads through `start_async`, so the note is in the
    # database before it is in the HTML; `render_async/1` is the wait, and the only alternative is a
    # sleep that is either flaky or slow.
    defp post_note(view, body, type) do
      view
      |> element("#pb-comment-form")
      |> render_submit(%{"form" => %{"body" => body, "type" => type}})

      render_async(view)
    end

    # A REPLY IS POSTED WITH ONLY A BODY, on purpose. In reply mode the composer has no type select
    # — it has a hidden `information` — so passing a type here would test the test's opinion rather
    # than the form's.
    defp post_reply(view, body) do
      view
      |> element("#pb-comment-form")
      |> render_submit(%{"form" => %{"body" => body}})

      render_async(view)
    end

    # THE BADGE, READ OFF A FRESH RENDER. `element/2` renders from the HTML the test client last
    # applied a diff to, and the count changes when `{:form_saved, …}` is HANDLED — one message after
    # the event's own reply — so the element path reads the value from before the note existed.
    defp review_badge(view) do
      case Regex.run(~r/pb-review-count[^>]*>\s*(\d+)\s*</s, render(view)) do
        [_all, count] -> count
        nil -> nil
      end
    end

    # The avatar letters and the name on a note's first line.
    defp byline(view, note) do
      [avatar, name | _rest] =
        view
        |> element("#pb-comment-#{note.id} > div:first-child")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("span")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      {avatar, name}
    end

    defp note_mentions(view, note),
      do:
        view
        |> element("#pb-comment-#{note.id} > p")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="pb-mention"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    defp resolver_line(view, note),
      do:
        view
        |> element("#pb-comment-resolver-#{note.id}")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.split()
        |> Enum.join(" ")

    # What actually landed in the database, newest first — the only thing that can prove a note
    # outlives the session that wrote it.
    defp notes(site, document) do
      MishkaCmsCore.Runtime.PageBuilder.Review.list(%{
        site_id: site.id,
        section: :page,
        document_id: document.id
      })
    end

    # The builder SHELL is admin chrome and keeps all three.
    test "the builder shell keeps the admin stylesheet", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns[:admin_css]
      assert assigns[:admin_fonts]
      assert assigns[:live_tailwind]
    end

    # A heroicon is a CLASS with no glyph in the markup — `<span class="hero-wrench-screwdriver">`
    # and a CSS mask. The canvas emits the rules for the icons it is about to render, and it derived
    # them from the tree in the EDITING session, then let the preview swap the tree without swapping
    # the rules. So an example's icon appeared only when the page underneath happened to use the
    # same one: `chelekom-alert`'s maintenance example asks for `hero-wrench-screwdriver`, the page
    # did not, and the reader saw a blank space beside the heading with the class sitting there in
    # the code pane.
    test "an example's own icons get their rules, not the edited page's", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "iconic",
        template: "<div><span class={@icon}></span>{render_slot(@inner_block)}</div>",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}],
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}],
        extra: %{
          "examples" => [
            %{
              "source" =>
                ~s(<.component component_name="iconic" site="#{site.name}" icon="hero-wrench-screwdriver">Hi</.component>)
            }
          ]
        }
      )

      # The page uses a DIFFERENT icon, so nothing about it can supply the example's rule.
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="iconic" site="#{site.name}" icon="hero-bell">Page</.component></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}?name=iconic&index=0")

      assert html =~ "hero-wrench-screwdriver{",
             "the example's icon class was rendered with no rule behind it"
    end

    # The icon control is a COMBOBOX: the catalogue suggests, it does not gate. It can only ever hold
    # the sets this install registered, so an author naming a glyph from one it was never told about
    # — a second kit's own icons, a class the host ships itself — must still be able to write it
    # down. Before this the trigger was a button and the only reachable values were catalogued ones.
    test "an icon field accepts a value no installed set ships", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "iconish",
        template: "<div><span class={@icon}></span></div>",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="iconish" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_tag(view, ".component")

      render_click(view, "inspect", %{"id" => component.id})

      render_change(view, "icon_typed", %{
        "name" => "icon",
        "node_id" => component.id,
        "value" => "lucide-rocket"
      })

      edited = view |> editor() |> Map.fetch!(:tree) |> Tree.get(component.id)

      assert {"icon", {:string, "lucide-rocket"}} in edited.attrs
    end

    # Picking is a decision, so the popover has answered its question and gets out of the way. Typing
    # is not — there the list is a filter being narrowed, and closing it on every keystroke would
    # make the grid useless.
    test "picking an icon writes it and closes the picker; typing keeps it open", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "picky",
        template: "<div><span class={@icon}></span></div>",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="picky" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_tag(view, ".component")
      render_click(view, "inspect", %{"id" => component.id})

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")

      render_change(view, "icon_typed", %{
        "name" => "icon",
        "node_id" => component.id,
        "value" => "bell"
      })

      assert has_element?(view, "#pb-icon-picker-icon"), "typing must not close the list"

      render_click(view, "icon_picked", %{
        "node_id" => component.id,
        "name" => "icon",
        "value" => "hero-bell"
      })

      refute has_element?(view, "#pb-icon-picker-icon")

      edited = view |> editor() |> Map.fetch!(:tree) |> Tree.get(component.id)
      assert {"icon", {:string, "hero-bell"}} in edited.attrs
    end

    test "renders the document with the site's scope", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us"
      assert html =~ "pb-canvas-root"
      assert html =~ "data-node-id"
    end

    # A site's page routinely embeds a GLOBAL component — `<.component component_name="global-footer"
    # site="Global" />` — and the compiled module's name is hashed from that attribute. Scoping it to
    # the page's own site instead named a module nobody ever compiled, so the canvas painted the
    # runtime's red "failed to render" over a component that renders fine on the live site.
    test ~s(a component declaring site="Global" resolves the global module), %{
      conn: conn,
      site: site
    } do
      define_component!("pb-global-footer", nil, "<footer>global footer rendered</footer>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="pb-global-footer" site="Global" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "global footer rendered"
      refute html =~ "failed to render"
    end

    # A COMPONENT IS BUILT ON FIRST USE, and reading its metadata is a use. The canvas asks the
    # compiled module which attributes the component declares so a database-sourced name never mints
    # an atom — and a module that has never been built declares none, so every attribute the author
    # set was dropped and the node rendered with its defaults. The live site was unaffected, which is
    # what made it invisible: the same page looked right to a visitor and wrong to its author.
    test "a lazy component renders on the canvas WITH the attributes the author set", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          site_id: site.id,
          name: "pb-lazy-badge",
          template: ~s(<span class={"badge-" <> @tone}>lazy badge</span>),
          attrs: [%{name: "tone", type: "string", default: "quiet"}],
          precompile: false
        )

      refute Helpers.loaded?(Helpers.module_name(component.name, site.name, "Component"))

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div><.component component_name="pb-lazy-badge" site="#{site.name}" tone="loud" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      # THE FIRST PAINT, not the connected one. Rendering the component builds it as a side effect,
      # so by the second render the module exists and the attributes come back — the bug heals
      # itself one frame too late, after the author has already seen the wrong thing (or, when a
      # missing attribute makes the component raise, an error box where their component should be).
      html =
        conn
        |> get("/admin/dashboard/runtime/builder-canvas/#{token(view)}")
        |> html_response(200)

      # The component's OWN rendered markup, not the node's stored attributes — the canvas echoes
      # those into the DOM as well, so a looser match passes with the component rendering nothing.
      assert html =~ ~s(<span class="badge-loud">lazy badge</span>)
    end

    test "a component with no site attribute still resolves against the site being edited", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-site-hero", site, "<section>site hero rendered</section>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="pb-site-hero" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "site hero rendered"
      refute html =~ "failed to render"
    end

    # `Tree.Styles` lifts recognised utilities out of the authored class attribute and into
    # `meta.styles`, so rendering the authored attribute raw loses them. That dropped `flex` off a
    # nav and the menu stacked, while the SAVED template stayed correct — only serialization was
    # merging them back, so the whole suite stayed green.
    test "absorbed layout classes survive onto the canvas, not just into the save", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<header class="flex justify-between"><nav class="flex gap-6">x</nav></header>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # BOTH are absorbed now — `justify-between` joined the vocabulary with the layout panel — so
      # they come back in the serialiser's own order rather than authored-then-generated. Same
      # classes, and no two utilities here compete on specificity, so order carries nothing.
      assert html =~ ~s(class="flex justify-between")
      assert html =~ ~s(class="gap-6 flex")
    end

    test "a node with no class at all gains none", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section><p>hi</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      [_before, after_tag] = String.split(html, "<section", parts: 2)
      [opening, _rest] = String.split(after_tag, ">", parts: 2)
      refute opening =~ "class="
    end

    # The site's asset URL is keyed on its name and a content hash; a site that is inactive or has
    # never been compiled has neither, so linking it rendered the editor unstyled for exactly the
    # sites people open it on. The bytes are inlined from `AssetsState` instead.
    # The bundle is 3.6 MB on a real site. Inlining it put every byte in the document of every
    # preview the modal opened; linking it by content hash means brotli, an immutable year-long
    # cache, and a frame that paints once already styled.
    test "the canvas links the site's compiled CSS by content hash", %{conn: conn, page: page} do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: "abc",
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # THE LINK ITSELF IS IN THE ROOT LAYOUT'S `<head>` now, above the browser generator, so that
      # the classes the editor generates are appended after the bundle and win. What the canvas
      # still owes is the ADDRESS, and that is what is checked here — the test endpoint renders a
      # bare layout, so the tag is not observable from a LiveView test.
      assert css_hrefs(canvas) == ["/assets/css/__shared_base__/abc"]
      refute html =~ ".from-shared-base{color:#123456}"
    end

    # The reason the inline path still exists: a site that has never compiled has bytes in
    # `AssetsState` but no hash to address them by, and that is exactly the site someone opens the
    # editor on.
    test "a bundle with no content hash is inlined instead", %{conn: conn, page: page} do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: nil,
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-canvas-css"
      assert html =~ ".from-shared-base{color:#123456}"
      refute html =~ "/assets/css/"
    end

    # Tailwind's browser build generates a utility the moment its class appears, but only for tokens
    # it knows — without the kit's `@theme` every `text-natural-*` class comes out blank.
    test "the kit's @theme travels to the browser generator", %{
      conn: conn,
      page: page,
      site: site
    } do
      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "kit-theme",
          content: "@theme { --color-natural-x: #abcdef; }\n.other { color: red }",
          kind: :theme,
          active: true
        },
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(type="text/tailwindcss")
      assert html =~ "--color-natural-x: #abcdef;"
      # Only the @theme block travels; the rest is already in the compiled bundle.
      refute html =~ ".other { color: red }"
    end

    # THE ORDER IS THE WHOLE FIX. The site's compiled bundle is base styling and belongs in `<head>`;
    # the browser generator injects what it makes into `<head>` too, after the markup already there.
    # Rendered in THIS LiveView's template — which is `<body>` — the bundle came last and overruled
    # every class the editor generated: an author typed `pl-[30px]` onto an element whose page said
    # `px-8`, the class landed, the rule was written, and the padding did not move.
    #
    # The link lives in `root.html.heex` now, above the generator's script. What is checkable here is
    # the half that was wrong: it must not be in the frame's body any more. The test endpoint renders
    # a bare layout, so the head itself is not observable from here.
    test "the compiled bundle is not rendered into the frame's body", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ ~r|<link[^>]+rel="stylesheet"[^>]+/assets/css/|

      # The frame's own chrome is still the frame's, so this is the bundle moving out and not the
      # whole head going missing.
      assert html =~ "pb-canvas-chrome"
    end

    # A node's own LiveView bindings must not reach the frame. `phx-click` would fight the canvas's
    # selection binding, and `phx-hook` names a hook from the SITE's bundle, which this frame does not
    # load — LiveView logged "unknown hook found" in the console for every one.
    test "a node's phx-* bindings are not emitted into the canvas", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<button id="c" phx-hook="SiteClipboard" phx-click="copy" data-x="1" class="btn">Copy</button>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "SiteClipboard"
      refute html =~ ~s(phx-click="copy")
      # Everything that is not a binding still renders, and the attribute stays in the document.
      assert html =~ ~s(data-x="1")
      assert html =~ "btn"
      assert editor_html(view) =~ ~s(phx-hook="SiteClipboard")
    end

    # A link in the document must select, not navigate. `<.link navigate>` renders `data-phx-link`,
    # which LiveView's own interceptor treats as a live redirect — clicking one to select it took the
    # canvas away from the document being edited. The hook cancels it in the capture phase, before
    # that interceptor runs, and pushes the selection itself.
    test "the canvas keeps a page's links selectable rather than live", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<nav><.link navigate="/">Home</.link></nav>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # The href stays — it is the document's content, and the inspector edits it.
      assert html =~ ~s(href="/")
      # The hook is what cancels the navigation, so the canvas must be carrying it.
      assert html =~ ~s(phx-hook="PbCanvas")
    end

    test "an expired session says so rather than erroring", %{conn: conn} do
      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

      assert html =~ "session has expired"
    end

    # A `phx-click="select"` on the canvas container would fire on the way up from every node's own
    # click and immediately clear the selection that just happened. Deselecting on background clicks
    # is the hook's job precisely because it can tell whether the click landed on a node.
    test "the canvas container carries no deselect binding of its own", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # Only the container's OWN opening tag — everything up to its first `>`. Its children carry
      # `phx-click="select"` and should.
      [_before, after_id] = String.split(html, ~s(id="pb-canvas-root"), parts: 2)
      [opening_tag, _children] = String.split(after_id, ">", parts: 2)

      refute opening_tag =~ ~s(phx-click="select")
      assert opening_tag =~ ~s(phx-hook="PbCanvas")
    end

    test "a selection made in the canvas survives — it is not cleared by its own click", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(canvas, "select", %{"id" => h1.id})

      assert editor(view).selection == h1.id
      assert render(view) =~ "h1"
    end

    test "selecting in the canvas updates the chrome over PubSub", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(canvas, "select", %{"id" => h1.id})

      assert render(view) =~ "Attributes" or editor(view).selection == h1.id
      assert editor(view).selection == h1.id
    end

    # A FORM IS AUTHORED ON THIS SURFACE, so it has to render on it. Every part of one is an
    # expression the canvas refuses to evaluate: `for={assigns[:contact_form]}` reads an assign the
    # canvas does not have, `field={f[:email]}` reads a variable only a real `:let` could bind, and
    # `<.form>` itself is a function component called by `apply/3` — so it never receives the
    # defaults and the `:global` map HEEx would have built at a call site. Each of the three ends in
    # a `KeyError` inside LiveView's diff, and what the author sees is the red placeholder.
    #
    # The shape is honoured rather than the value: the bindings are parsed, a blank form field is
    # built from the form's own `as`, and the field renders carrying the input name it will really
    # submit under.
    #
    # The document is put into the SESSION rather than saved on the page, because saving compiles
    # the template for real and `input/1` is not yet among a compiled page's imports — a separate
    # question from what the canvas can draw, and the canvas resolves it through its own module list.
    test "a form with bound fields renders its real input names", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, tree} =
        Tree.parse("""
        <.form
          :let={f}
          id="contact-form"
          as={:contact}
          for={assigns[:contact_form]}
          phx-change="contact_validate"
          phx-submit="contact_submit"
        >
          <.input field={f[:name]} type="text" label="Your name" />
          <.input field={f[:email]} type="email" label="Email" />
        </.form>
        """)

      {:ok, _session} = EditorSession.put_tree(token(view), tree)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "<form", "the wrapper renders a real form element"
      assert html =~ ~s(name="contact[name]"), "the first field submits under the form's own name"
      assert html =~ ~s(name="contact[email]")
      assert html =~ ~s(id="contact_name"), "and carries the id its label points at"
      assert html =~ "Your name"
      assert html =~ "Email"

      refute html =~ "could not render", "nothing in a form is allowed to be a placeholder"

      refute html =~ "set it in the inspector to render this",
             "and no field is reported as missing the attribute the canvas synthesises"

      refute html =~ "contact_submit",
             "and the canvas still strips every binding — a form here is not a running page"

      refute html =~ "contact_validate"
    end

    # THE OTHER HALF OF THE SAME SURFACE, and the half the installed kit never reaches. All 23 of
    # Chelekom's fields take a `%Phoenix.HTML.FormField{}`, so `field={f[:email]}` is the only thing
    # the editor writes for them. A kit on the documented fallback gets the pair instead —
    # `name={f[:email].name}` and `value={f[:email].value}` — and both used to arrive as the whole
    # struct, because the key `:email` is the same fact for all three expressions and the canvas
    # resolved nothing further. `name={%Phoenix.HTML.FormField{}}` is
    # `protocol Phoenix.HTML.Safe not implemented`, which is the red box, on the surface the form is
    # authored on.
    test "a field that binds by name and value renders its real input name", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]}>) <>
              ~s(<MishkaCmsCore.Test.PairFieldComponent.text name={f[:email].name} value={f[:email].value} />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(name="contact[email]"),
             "the pair path has to reach the input name, not the struct that carries it"

      refute html =~ "could not render"
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # THE COMPONENT BUILDER COULD NOT SHOW A MODAL'S OWN CONTENTS. Every Chelekom dialog wraps its
    # title, close button and body in `<.focus_wrap id={"#{@id}-container"}>`, and opening that
    # component in the builder means rendering it with no page assigns — so `@id` folded to nothing,
    # `attr_value/1` dropped the attribute, and Phoenix met its own `focus_wrap` without the one
    # thing it declares required. `key :id not found`, raised from inside LiveView's diff and caught
    # by `contain/2` as a red box where the dialog should have been.
    test "a required attribute written as an expression renders rather than raising", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          name: "dialog-shell",
          site_id: site.id,
          template:
            ~s(<div id="wrap"><.focus_wrap id={"\#{@id}-container"}>) <>
              ~s(<h2 id="dialog-title">Are you sure?</h2></.focus_wrap></div>)
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute has_element?(canvas, ~s([data-render-error="true"])),
             "the canvas used to red-box every dialog it was asked to open"

      refute html =~ "key :id not found"

      # And the point of not refusing: what the author came to edit is on the canvas.
      assert html =~ "Are you sure?"
      assert has_element?(canvas, "#dialog-title")
    end

    # A KIT'S OPTIONAL ATTRIBUTE WITH NO DEFAULT IS A KEY ITS TEMPLATE STILL READS. Chelekom's form
    # wrapper declares `for` that way, and a wrapper bound to its page form
    # (`for={assigns[:contact_form]}`) lost the attribute on the canvas, which cannot read page
    # assigns, so every render ended in `key :for not found`.
    test "a kit attribute with no default, written as an expression, renders rather than raising",
         %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "bound-shell",
        template: ~s(<div id="bound-shell">{if @for, do: "bound", else: "not bound yet"}</div>),
        attrs: [%{"name" => "for", "type" => "any", "opts" => %{"required" => false}}]
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="bound-shell" site="#{site.name}" for={assigns[:contact_form]} /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "key :for not found"
      refute has_element?(canvas, ~s([data-render-error="true"]))
      assert has_element?(canvas, "#bound-shell", "not bound yet")
    end

    test "Chelekom's own form wrapper, wired to its page form, draws on the canvas", %{
      conn: conn,
      site: site
    } do
      wrapper =
        MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("components")
        |> Enum.find(&(&1["name"] == "chelekom-form-wrapper"))

      create_component!(
        site_id: site.id,
        name: wrapper["name"],
        template: wrapper["template"],
        attrs: wrapper["attrs"],
        slots: wrapper["slots"],
        helpers: wrapper["helpers"]
      )

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root">
            <.component component_name="chelekom-form-wrapper" site="#{site.name}" :let={f}
              id="contact-form" as={:contact} for={assigns[:contact_form]}
              phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit">
              <input id="wrapped-name" name={f[:name].name} value={f[:name].value} />
            </.component>
          </div>
          """
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "key :for not found"
      refute has_element?(canvas, ~s([data-render-error="true"]))
      assert has_element?(canvas, "form#contact-form")
    end

    # A WORKING FORM'S `for` IS SUPPLIED BY THE PAGE, so a kit that declares it required draws its
    # form. Chelekom's Simple Form does, and every one the editor wired showed "needs for" instead.
    test "Chelekom's Simple Form, wired to its page form, draws on the canvas", %{
      conn: conn,
      site: site
    } do
      rows =
        MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("components")

      for name <- ~w(chelekom-form-wrapper chelekom-simple-form),
          row = Enum.find(rows, &(&1["name"] == name)) do
        create_component!(
          site_id: site.id,
          name: name,
          template: row["template"],
          attrs: row["attrs"],
          slots: row["slots"],
          helpers: row["helpers"]
        )
      end

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root">
            <.component component_name="chelekom-simple-form" site="#{site.name}" :let={f}
              id="news-form" as={:news} for={assigns[:news_form]}
              phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">
              <input id="simple-email" name={f[:email].name} value={f[:email].value} />
            </.component>
          </div>
          """
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "needs for"
      refute has_element?(canvas, ~s([data-incomplete="true"]))
      refute has_element?(canvas, ~s([data-render-error="true"]))
      refute html =~ "failed to render"
      assert has_element?(canvas, ~s(form#news-form input#simple-email[name="news[email]"]))
    end

    test "a required `for` that is not the page's own form still says it is needed", %{
      conn: conn,
      site: site
    } do
      kit_rows!(site, chelekom_rows(~w(chelekom-simple-form)))

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="chelekom-simple-form" site="#{site.name}" for={@changeset} /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-incomplete="true"]))
      assert html =~ "needs for"
    end

    # WRITTEN IS SUPPLIED; UNWRITTEN IS NOT. A required attribute the author never wrote is a real
    # gap, and the placeholder is how they are told — the same words a kit component gets, and
    # still selectable so the click lands on the node.
    test "a required attribute nobody wrote is named rather than rendered", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><.focus_wrap>nothing named it</.focus_wrap></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-incomplete="true"]))
      assert html =~ "needs id"
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # A HALF-TYPED EXPRESSION IS NOT A CRASH. The author is editing, and `f[:email].nam` is a
    # keystroke away from `f[:email].name` — so a path the form field does not carry supplies no
    # assign, and the attribute falls back to whatever the component declared.
    test "a binding naming nothing the form field carries supplies no assign at all", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]}>) <>
              ~s(<MishkaCmsCore.Test.PairFieldComponent.text name={f[:email].name} value={f[:email].nonsense} />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(name="contact[email]")
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # WHAT THE VALIDATION SECTION WRITES HAS TO BE VISIBLE ON THE CANVAS. `required`, `minlength` and
    # `data-format` are none of them declared by `<.input>`: HEEx routes such a name into the
    # component's `:global` attribute at the call site, and the canvas has no call site, so all three
    # were dropped on the way in. The author set Required, the code drawer showed `required` written,
    # and the field on the canvas rendered exactly as it had before.
    test "a global attribute the component never declared still reaches its rendered input", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]}>) <>
              ~s(<.input field={f[:email]} type="email" label="Email" required minlength="5" data-format="email" />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(minlength="5")
      assert html =~ ~s(data-format="email")
      assert html =~ "required"
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # A RAW TAG'S BINDING IS SHOWN THE WAY THE PUBLISHED PAGE WILL SHOW IT. A checkbox bound to its
    # form carries `name={f[:agree].name}`, which reads an assign, so the canvas refused it and the
    # input rendered with NO name — correct in the stored source, blank on the surface the author
    # looks at, and indistinguishable from the unbound field the audit warns about.
    test "a raw input bound to its form renders the name the visitor will submit", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="signup-form" as={:signup} for={assigns[:signup_form]}>) <>
              ~s(<input type="checkbox" name={f[:agree].name} value="true" />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(name="signup[agree]")
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # READING THE SOURCE WHILE AUTHORING IS THE POINT OF THE DRAWER. Selecting another element is not
    # a change to the document and must not close it — an author checking what a form's markup looks
    # like had to reopen the drawer after every click.
    test "the code drawer survives selecting another element", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><p>one</p><span>two</span></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-code-strip") |> render_click()
      refute has_element?(view, "#pb-code-strip")

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "span"))

      render_click(view, "select", %{"id" => node.id})

      refute has_element?(view, "#pb-code-strip")
    end

    # The whole struct is not a string, so it is left out rather than interpolated into markup.
    test "and a raw tag bound to the struct itself is left alone", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="signup-form" as={:signup} for={assigns[:signup_form]}>) <>
              ~s(<input type="text" name={f[:agree]} />) <>
              ~s(</.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # EVERY CHELEKOM FIELD DECLARES A BARE `attr :rest, :global`, with no `:include` — so filtering
    # the canvas by `Phoenix.Component.Declarative.__global__?/3` would have kept `required` off all
    # 23 of them while the published page rendered it, which is the whole Validation section for the
    # fields people actually build forms out of.
    test "a kit's undeclared attribute reaches its rest, the way the published page renders it",
         %{
           conn: conn,
           site: site
         } do
      create_component!(
        site_id: site.id,
        name: "restfield",
        template: ~s|<input type="text" {@rest} />|,
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="restfield" required minlength="5" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(minlength="5")
      assert html =~ "required"

      refute html =~ "component_name=",
             "the wrapper's own two attributes are addressed to `.component`, not to the kit"
    end

    # A COMPONENT THAT DECLARES NO GLOBAL TAKES NOTHING EXTRA. Handing an undeclared assign to one is
    # a `KeyError` waiting inside LiveView's diff at best, and this component's whole point is that
    # `name` carries no default.
    test "a component with no global declaration is handed nothing it did not declare", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><MishkaCmsCore.Test.PairFieldComponent.text name="plain" data-wibbles="17" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "wibbles"
    end

    # A `phx-` binding names a hook that lives in the SITE's bundle, which this frame deliberately
    # does not load, and its click would fight the canvas's own selection binding. It is global as far
    # as LiveView is concerned, so only the canvas can refuse it — for a component exactly as for a tag.
    test "a component's own phx- binding is not forwarded into the frame", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.input type="text" name="plain" phx-click="author_click" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "author_click"
    end

    # AN EMPTY CONTAINER CANNOT BE FILLED IF IT IS ZERO PIXELS TALL, and a component that declares
    # its slot required could not render at all until something was already inside it.
    test "an empty component container renders and gets a floor", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<.form :let={f} as={:quote} for={assigns[:quote_form]}></.form>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "<form", "an empty form is still a form"
      assert html =~ "min-height:56px", "and is somewhere to aim at"
      refute html =~ "could not render"
    end
  end

  describe "panels" do
    test "switching the left panel to the inspector", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-palette-search")
      refute palette_hidden?(view)

      view |> element("#pb-lefttab-inspector") |> render_click()

      # HIDDEN, NOT REMOVED. The 177 cards stay in the DOM so coming back to the tab costs nothing;
      # what the reader sees is the same either way.
      assert palette_hidden?(view)
      assert render(view) =~ "Select an element on the canvas"
    end

    # STARRING NEVER REACHES THE SERVER. Which four of 177 components one author keeps reaching for
    # is not the site's data, so the star, the two chips and the recent row are the browser's from
    # end to end — the rules are tested in `assets/js/pb_prefs.test.js`. What the server owes them is
    # the handful of hooks and names they read, and that is what this pins: lose `data-name` and the
    # star has nothing to star.
    # WHAT A CARD WILL PUT ON THE PAGE, shown while the pointer rests on it.
    #
    # Everything about showing it is the client's: when to ask, where to put it, when to take it
    # away. The server renders and pushes, and these assert exactly that seam — the panel exists for
    # the hook to find, and the event answers with a document.
    # ENTER IN A STYLE FIELD USED TO RELOAD THE PAGE. A LiveView form with `phx-change` and no
    # `phx-submit` is not intercepted, so the browser applies its implicit-submission rule and does a
    # native GET to the current URL — taking the whole editing session with it.
    test "every style form can be submitted, so Enter never leaves the page", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      forms = ~r/<form[^>]*>/ |> Regex.scan(render(view)) |> List.flatten()
      style_forms = Enum.filter(forms, &(&1 =~ "pb-style-form" or &1 =~ "pb-attr-form"))

      assert style_forms != []
      for form <- style_forms, do: assert(form =~ "phx-submit")
    end

    test "and the search boxes that sit in a form do too", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      for id <- ~w(pb-find-form pb-block-search-form) do
        case Regex.run(~r/<form[^>]*id="#{id}"[^>]*>/, html) do
          nil -> :not_rendered_in_this_state
          [form] -> assert form =~ "phx-submit"
        end
      end
    end

    # A CONTRIBUTED CATEGORY NEEDS A CHIP TO REACH IT BY. The row was built from the core lists, so a
    # block an extension added under its own category could only ever be found under "all" — while
    # showing under every other filter too, because the merge happened after the filtering.
    test "the block category chips include the ones extensions brought", %{conn: conn, page: page} do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: MishkaCmsCore.Test.Plugins.BuilderBlockPlugin,
          event: "builder:blocks",
          extension: :mishka_installer,
          status: :started
        })

      :ok = MishkaInstaller.Event.EventHandler.do_compile("builder:blocks", :start, false)

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(
          :name,
          MishkaCmsCore.Test.Plugins.BuilderBlockPlugin,
          false
        )
      end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      assert has_element?(view, "#pb-blockcat-social-proof")
      assert has_element?(view, "#pb-blockcat-all")
    end

    # PUBLISH MODE KEEPS NOTHING, AND HAS TO SAY SO. Every other mode writes as you work; this one
    # deliberately does not. Silence about that is indistinguishable from a save that is failing.
    test "publish mode says out loud that changes are not being saved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-publish-bar")

      render_click(view, "set_stage", %{"stage" => "published"})
      node = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => node.id})

      assert has_element?(view, "#pb-publish-bar")
      assert has_element?(view, "#pb-publish-keep")
    end

    test "and offers a way to keep the work without publishing it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      node = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => node.id})

      view |> element("#pb-publish-keep") |> render_click()

      refute has_element?(view, "#pb-publish-bar")
    end

    # AND THE OFFER IS KEPT. The bar above is satisfied by a button that only takes the bar down, so
    # it green-lit a handler which cleared the session's `dirty?` first and left `autosave/1` —
    # which returns untouched on a clean session — nothing to write. The draft row is what says the
    # work survived, so the draft row is what this asserts.
    test "and the draft that button offers is really written", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      _written = render_async(view)

      [kept] = Drafts.list("page", page, recorded)
      assert String.starts_with?(kept.label, "Draft · ")
      refute kept.template =~ "<h1", "the draft carries the edit, not the document as it was"

      refute view |> editor() |> Map.fetch!(:dirty?),
             "and the session is clean because the write happened, not before it"
    end

    # THE BAR IS DOWN FOR ONE WRITE, NOT FOR GOOD. It hides behind a flag of its own while the draft
    # it offered is being written; a flag that stayed up would leave every later change in publish
    # mode unannounced, which is the warning this bar exists to make.
    test "and the bar comes back for the next change made in publish mode", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      view |> element("#pb-publish-keep") |> render_click()
      _written = render_async(view)
      refute has_element?(view, "#pb-publish-bar")

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})

      assert has_element?(view, "#pb-publish-bar")
    end

    # A PRESS WITH NOTHING TO KEEP MUST NOT SILENCE THE NEXT WARNING. The button is only drawn while
    # there is work, but what is drawn is one patch behind a change made in the same breath as the
    # click — so the press can arrive with a clean session, and no write starts for the flag to wait
    # on. It is armed off the write it really started, and there was none.
    test "and a press with nothing to keep leaves the warning able to appear", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "keep_as_draft", %{})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      assert has_element?(view, "#pb-publish-bar")
    end

    # A REFUSED WRITE PUTS THE BAR BACK. Taking it down is a claim that the work is kept, so it may
    # only outlive the press if the draft really was written. The editor says so in words too, but
    # the bar is the thing on screen for the rest of the sitting.
    test "and a draft write that fails leaves the bar saying so", %{conn: conn, page: page} do
      refuse_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      settled = render_async(view)

      assert Drafts.list("page", page, recorded) == [], "the gate refused, so nothing was written"
      assert has_element?(view, "#pb-publish-bar")
      assert settled =~ "Autosave is failing"
    end

    # AND NOTHING IS CALLED KEPT THAT WAS NOT WRITTEN. The canvas stays live for the whole round
    # trip — serialize, parse back, format, then the write — so an edit can land while the draft is
    # away being written, and it is not in that draft. Clearing `dirty?` for it anyway left work in
    # no draft at all, with the bar down and the leave prompt silent: the state this button exists
    # to abolish, reached by the button itself.
    test "and an edit made while that draft is being written is not called kept", %{
      conn: conn,
      page: page
    } do
      pause_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      assert_receive {:draft_write_paused, writing}, 2_000

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
      send(writing, :release)
      _written = render_async(view)

      [kept] = Drafts.list("page", page, recorded)
      assert kept.template =~ "<p", "the write carried the document it serialized, and only that"

      assert view |> editor() |> Map.fetch!(:dirty?),
             "the edit it could not carry is still unkept work"

      assert has_element?(view, "#pb-publish-bar")
    end

    # AND A SECOND PRESS IS NOT SWALLOWED. A press arriving while the first write runs is queued
    # rather than overlapped, and the queue was replayed through `autosave/1` — which refuses
    # publish mode outright, so the retry died where it stood and the ••• menu's "Save draft now"
    # could be pressed all afternoon in publish mode for one row that never moved.
    test "and a press made during that write is written when it finishes", %{
      conn: conn,
      page: page
    } do
      pause_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      view |> element("#pb-publish-keep") |> render_click()
      assert_receive {:draft_write_paused, first}, 2_000

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
      render_click(view, "save", %{})
      send(first, :release)

      assert_receive {:draft_write_paused, queued}, 2_000
      send(queued, :release)
      _written = render_async(view)

      [kept] = Drafts.list("page", page, recorded)
      refute kept.template =~ "<h1"
      refute kept.template =~ "<p", "the queued write carried the document as it had become"

      refute view |> editor() |> Map.fetch!(:dirty?)
      refute has_element?(view, "#pb-publish-bar")
    end

    # ONE SITTING, ONE ROW. The retry reads the draft to update off the socket's copy of the
    # session, and `mark_saved/2` only puts the new `draft_id` on the stored one — so a retry that
    # ran before that copy caught up saw no draft at all and made a second row for the same work.
    test "and a queued write updates the draft the first one made", %{conn: conn, page: page} do
      pause_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      assert_receive {:draft_write_paused, first}, 2_000
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
      send(first, :release)

      assert_receive {:draft_write_paused, queued}, 2_000
      send(queued, :release)
      _written = render_async(view)

      assert [_one] = Drafts.list("page", page, recorded)
    end

    # A COMPONENT IS TOLD THE TRUTH TOO. It has no draft resource, so the write this button starts
    # answers `:unsupported` and writes nothing — and the publish-mode sentence, matching first,
    # said the work had been kept anyway.
    test "and a component in publish mode is not told it was kept", %{conn: conn, site: site} do
      component =
        create_component!(
          name: "keepless",
          site_id: site.id,
          template: ~s(<div id="wrap"><h1>Hello</h1></div>)
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _settled = render_async(view)

      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      told = view |> element("#pb-publish-keep") |> render_click()
      assert told =~ "A component has no drafts"
      refute told =~ "Kept as a draft"

      _settled = render_async(view)
      assert has_element?(view, "#pb-publish-bar")
    end

    test "the hover preview panel is there for the hook to drive", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-card-preview[phx-hook='PbPaletteHover'][hidden]")
      assert has_element?(view, "#pb-card-preview [data-role='pb-card-preview-frame']")
      assert has_element?(view, "#pb-card-preview [data-role='pb-card-preview-note']")
    end

    # THE ONE TOKEN THAT MUST NEVER BE THERE. The frame holds a component's own markup, which is
    # authored in the CMS and therefore untrusted; `allow-same-origin` is granted so the panel can
    # read the drawn height and size itself to it, and that is only safe while nothing inside can
    # run. Add `allow-scripts` beside it and the frame can reach straight into the admin session.
    test "and the frame it draws into can never run scripts", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert html =~ ~s|sandbox="allow-same-origin"|
      refute html =~ "allow-scripts"
    end

    test "asking for a preview answers with a document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => "<p>a paragraph</p>"})

      assert_push_event(view, "pb:card-preview", %{template: template, html: html})
      assert template == "<p>a paragraph</p>"
      assert html =~ "<p>a paragraph</p>"
    end

    # A component that needs configuring says so, rather than showing an empty box that reads as a
    # broken component.
    test "and a template that will not render answers with the reason", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => "<p>{@nothing_supplies_this}</p>"})

      assert_push_event(view, "pb:card-preview", %{note: note})
      assert is_binary(note) and note != ""
    end

    test "an empty ask is ignored rather than rendered", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => ""})

      refute_push_event(view, "pb:card-preview", %{})
    end

    test "the palette carries what the star and recent rows need", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "starrable",
        template: ~s|<div class="p-4">hi</div>|
      )

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-palette[phx-hook='PbPalettePrefs'][data-scope]")
      assert has_element?(view, "#pb-palette-fav[data-pb-prefchip='fav']")
      assert has_element?(view, "#pb-palette-recent[data-pb-prefchip='recent']")
      assert has_element?(view, "[data-role='pb-count']")

      # Both empty states ship hidden — the server cannot know whether anything is starred.
      assert has_element?(view, "#pb-palette-empty-fav[hidden]")
      assert has_element?(view, "#pb-palette-empty-recent[hidden]")

      cell = view |> element("[data-role='pb-compcell']") |> render()
      assert cell =~ ~s(data-name=)
      assert cell =~ ~s(data-role="pb-fav")

      # NO `phx-click` ON THE STAR. It sits on top of the tile that places the component; an event
      # here would be a round trip, and a re-render of the tile under the pointer.
      star = view |> element("[data-role='pb-fav']") |> render()
      refute star =~ "phx-click"
    end

    # Clicking an element ON THE CANVAS means "work on this", so the chrome swings to its form. The
    # canvas is a second LiveView, so what reaches this one is the session broadcast — which is what
    # the test drives, origin and all.
    test "a canvas click opens the inspector, a panel selection does not", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      token = view |> editor() |> Map.fetch!(:token)

      {:ok, _session} = EditorSession.select(token, section.id, :panel)
      refute palette_hidden?(view)

      {:ok, _session} = EditorSession.select(token, section.id, :canvas)
      assert palette_hidden?(view)
      assert has_element?(view, "#pb-bp-mobile")
    end

    # The grip drags locally and reports once, so the bounds have to reach the browser: without
    # data-min/data-max the drag would run past the ceiling and then jump back when the server
    # clamped what it was finally told. Same numbers on both sides, from `Panels.resize_bounds/1`.
    test "the resize grips carry the same bounds the server clamps to", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      for {panel, id} <- [left: "#pb-grip-left", right: "#pb-grip-right"] do
        {min, max} = Panels.resize_bounds(panel)

        assert view |> element(id) |> render() =~ ~s(data-min="#{min}")
        assert view |> element(id) |> render() =~ ~s(data-max="#{max}")
      end

      # And the value the grip finally reports is clamped again here, because what arrives is
      # whatever the page chose to send.
      # The server's number is the FALLBACK of a custom property a drag overrides — see
      # `Panels.resize_bounds/1` and the `--pb-*` variables — so that is where the clamp shows up.
      render_click(view, "resize", %{"panel" => "left", "value" => 9_000})
      assert render(view) =~ "var(--pb-left-w, #{elem(Panels.resize_bounds(:left), 1)}px)"

      render_click(view, "resize", %{"panel" => "left", "value" => 10})
      assert render(view) =~ "var(--pb-left-w, #{elem(Panels.resize_bounds(:left), 0)}px)"
    end

    # A slot's properties are drawn from the SAME option lists the parent component's are, and the
    # panel reads `entry.features` unconditionally. Selecting any slot used to raise
    # `KeyError :features` and take the whole editor down with it.
    test "selecting a slot opens its properties instead of crashing", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "has-slots",
        template: "<div>{render_slot(@item)}</div>",
        slots: [
          %{
            "name" => "item",
            "opts" => %{"doc" => "One row"},
            "attrs" => [%{"name" => "color", "type" => "string", "opts" => %{}}]
          }
        ],
        helpers: [
          %{
            "name" => "color_variant",
            "code" => "defp color_variant(_, _), do: nil",
            "discriminators" => [%{"axis" => "color", "values" => ["primary", "danger"]}]
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="has-slots" site="#{site.name}"><:item>hi</:item></.component>),
        "parent_id" => section.id,
        "index" => "0"
      })

      slot = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :slot))
      assert slot, "the dropped component should carry a slot node"

      render_click(view, "select", %{"id" => slot.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      assert html =~ "Color"
      # The parent's option list reached the slot, so this is a picker and not a text box.
      assert html =~ "primary"
    end

    # `:global` is the component's `@rest` catch-all. Offering it wrote a literal `rest=""` into the
    # page and then rendered a control whose own copy said it did nothing.
    test "the property menu never offers the global catch-all", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "with-rest",
        attrs: [
          %{"name" => "title", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="with-rest" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "with-rest")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      html = render(view)

      # The component's own property is on the form…
      assert html =~ "Title"

      # …and its `@rest` catch-all is not a property at all: offering it wrote a literal `rest=""`
      # into the page and then drew a control whose own copy said it did nothing.
      refute html =~ ">Rest<"
      refute has_element?(view, "#pb-extra-rest")
    end

    # An icon attribute's value is a class name the Tailwind heroicons plugin resolves. Fifty-seven
    # of the kit's attributes are one, and every one used to be a text box the author had to type
    # `hero-exclamation-triangle` into from memory — a typo rendering nothing at all.
    test "an icon property offers the catalogue instead of a text box", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "iconed",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{"default" => "hero-check"}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconed" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "iconed")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # Closed, it is a chip naming the default — not an empty text input.
      assert has_element?(view, "#pb-icon-open-#{node.id}-icon")
      refute has_element?(view, "#pb-attr-icon")

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")
      assert has_element?(view, "#pb-icon-hero-academic-cap")

      # The four weights the set actually ships.
      assert has_element?(view, "#pb-icon-variant-outline")
      assert has_element?(view, "#pb-icon-variant-solid")
      assert has_element?(view, "#pb-icon-variant-mini")
      assert has_element?(view, "#pb-icon-variant-micro")

      # Searching narrows it, and the count says how much was left out.
      # THROUGH THE FIELD, which is the only thing that narrows the grid. The trigger is the input:
      # typing sets the attribute and filters the catalogue with the same keystrokes, so there is no
      # search box of its own to drive.
      render_change(view, "icon_typed", %{
        "name" => "icon",
        "node_id" => node.id,
        "value" => "arrow-up"
      })

      assert has_element?(view, "#pb-icon-hero-arrow-up")
      refute has_element?(view, "#pb-icon-hero-academic-cap")

      # Switching weight keeps the query and re-suffixes the results.
      render_click(view, "icon_variant", %{"variant" => "-solid"})
      assert has_element?(view, "#pb-icon-hero-arrow-up-solid")

      # Picking one writes it through the ordinary set_attr op, so it is undoable.
      view |> element("#pb-icon-hero-arrow-up-solid") |> render_click()

      assert Node.attr_text(component_node(view, "iconed"), "icon") == "hero-arrow-up-solid"
      assert view |> editor() |> Map.fetch!(:past) |> hd() |> Map.fetch!(:label) == "Set icon"
    end

    test "the icon picker closes on click-away", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "iconed-two",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconed-two" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "iconed-two")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")

      render_click(view, "close_icon_picker", %{})
      refute has_element?(view, "#pb-icon-picker-icon")
    end

    # BETWEEN A COMPONENT AND A WHOLE-PAGE PRESET there was nothing, so a landing page meant placing
    # a grid, a heading, a paragraph and a button and repeating it for every band down the page.
    test "a section drops in as one block", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-lefttab-blocks") |> render_click()
      assert has_element?(view, "#pb-block-features-four")

      before = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

      view |> element("#pb-block-features-four") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      after_place = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

      assert after_place > before + 20,
             "a four-across feature row is forty-odd nodes, not one"

      # …and it is ONE step, so a section leaves the way it arrived.
      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length() == before
    end

    test "the block list filters by category and by search", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      view |> element("#pb-blockcat-Footer") |> render_click()
      assert has_element?(view, "#pb-block-footer-columns")
      refute has_element?(view, "#pb-block-hero-centred")

      view |> element("#pb-blockcat-all") |> render_click()
      render_change(view, "block_query", %{"value" => "pricing"})

      assert has_element?(view, "#pb-block-pricing-three")
      refute has_element?(view, "#pb-block-hero-centred")
    end

    # Every block is plain HTML and Tailwind on purpose: one reaching for `chelekom-card` would fail
    # on an install without Chelekom, which is the assumption this whole effort has been removing.
    test "blocks depend on no kit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()
      view |> element("#pb-block-hero-centred") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      kinds =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.kind) |> Enum.uniq()

      refute :component in kinds
    end

    # A ROW OF SHAPES, NOT A WORD TO SPELL. A grid's column count was a blank text box whose
    # placeholder was the WORD "twelve", so `4` did nothing and the author had to guess `four`.
    test "a column count is picked by clicking a shape", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "colgrid",
        template: ~s|<div class="grid">g</div>|,
        attrs: [
          %{
            "name" => "cols",
            "type" => "string",
            "opts" => %{"values" => ~w(one two three four), "default" => "two"}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-colgrid") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert has_element?(view, "#pb-cols-#{placed.id}-four"),
             "every column count the kit offers is a button"

      refute has_element?(view, "#pb-cols-#{placed.id}-four input"),
             "and none of them is a text field"

      view |> element("#pb-cols-#{placed.id}-four") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Map.fetch!(:attrs)
             |> Map.new()
             |> Map.get("cols") == {:string, "four"}
    end

    # SPACING AND COLOUR ARE WHAT PEOPLE REACH FOR FIRST, and both shipped folded shut — three folds
    # and a scroll below the component's own properties. Nothing said they were there.
    test "Layout and Appearance are open the first time a node is selected", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)

      assert html =~ "Padding", "the Layout controls are on screen without unfolding anything"
      assert has_element?(view, "#pb-swatch-white"), "and so is the background swatch row"
    end

    # PRESSING THE OPEN ONE CLOSES IT. Three toggles here were written as
    # `(open == name && nil) || name`, which yields `name` when they are EQUAL — `nil || name` is
    # `name` — so the picker opened and then would not close by the control that opened it. Only
    # click-away worked, and only click-away was tested.
    test "the icon picker closes when its own field is pressed again", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "iconed-three",
        attrs: [%{"name" => "icon", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconed-three" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "iconed-three")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      assert has_element?(view, "#pb-icon-picker-icon")

      render_click(view, "toggle_icon_picker", %{"name" => "icon"})
      refute has_element?(view, "#pb-icon-picker-icon")
    end

    # Same shape, same bug: choosing the library that is already chosen clears the filter.
    test "choosing the active icon library again clears it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "icon_library", %{"library" => "heroicons"})
      assert :sys.get_state(view.pid).socket.assigns.icon_library == "heroicons"

      render_click(view, "icon_library", %{"library" => "heroicons"})
      assert is_nil(:sys.get_state(view.pid).socket.assigns.icon_library)
    end

    # The examples modal answers "show me one the kit already wrote". The wizard answers the other
    # question — "give me THIS one" — from the component's own option lists.
    test "the wizard composes a component from its options and inserts it", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "wizardly",
        template: "<div class={color_variant(@variant, @kind)}>{render_slot(@inner_block)}</div>",
        attrs: [
          %{"name" => "variant", "type" => "string", "opts" => %{"default" => "default"}},
          %{"name" => "kind", "type" => "string", "opts" => %{"default" => "natural"}}
        ],
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}],
        helpers: [
          %{
            "name" => "color_variant",
            "code" => "defp color_variant(_, _), do: nil",
            # `natural` is in the colour list because a real kit's colour axis contains its own
            # attribute's default — alert's `kind` defaults to `natural` and the axis lists all
            # thirteen. A fixture that leaves it out is testing a shape no kit ships, and the
            # plausibility guard in `pair_leftovers/3` reads exactly that fact to tell a real
            # `color` → `kind` from the generator axis it refuses on `divider`.
            "discriminators" => [
              %{"axis" => "variant", "values" => ["default", "outline"]},
              %{"axis" => "color", "values" => ["natural", "primary", "danger"]}
            ]
          }
        ],
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="wizardly" site="#{site.name}"/>)}
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      assert has_element?(view, "#pb-example-tab-wizard")

      view |> element("#pb-example-tab-wizard") |> render_click()

      # Every axis the component declares, including the colour one whose helper parameter is named
      # `color` while the attribute is `kind`.
      assert has_element?(view, "#pb-wizard-variant-outline")
      assert has_element?(view, "#pb-wizard-kind-danger")

      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "wizard_pick", %{"name" => "kind", "value" => "danger"})

      # The choices reach the SESSION, because the preview is a second LiveView in an iframe.
      assert view |> editor() |> Map.fetch!(:wizard) == %{
               "variant" => "outline",
               "kind" => "danger"
             }

      # The code pane shows exactly what Insert will place.
      html = render(view)
      assert html =~ "variant=&quot;outline&quot;"
      assert html =~ "kind=&quot;danger&quot;"

      render_click(view, "insert_wizard", %{})

      placed = component_node(view, "wizardly")
      assert Node.attr_text(placed, "variant") == "outline"
      assert Node.attr_text(placed, "kind") == "danger"

      # …and it is an ordinary node: on the history, undoable like anything else.
      assert view |> editor() |> Map.fetch!(:past) != []
    end

    # THE CHOICES LIVE IN TWO PLACES, because the preview is a second LiveView: the socket renders
    # the controls and the SESSION is what the iframe can read. Every clearing point cleared one of
    # them, so a variant picked for one component survived the modal that made it — into the next
    # component's wizard, and into a preview still composing from choices nobody could see.
    test "closing the wizard lets go of the choices in both places", %{
      conn: conn,
      page: page,
      site: site
    } do
      wizardly!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})

      assert view |> editor() |> Map.fetch!(:wizard) == %{"variant" => "outline"}

      render_click(view, "close_examples", %{})

      assert view |> editor() |> Map.fetch!(:wizard) == %{},
             "the session kept choices the closed modal made"

      assert :sys.get_state(view.pid).socket.assigns.wizard == %{}
    end

    test "and inserting from it does too", %{conn: conn, page: page, site: site} do
      wizardly!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "insert_wizard", %{})

      assert view |> editor() |> Map.fetch!(:wizard) == %{},
             "the session kept the choices an insert had already spent"
    end

    test "and opening another component's wizard starts from that component", %{
      conn: conn,
      page: page,
      site: site
    } do
      wizardly!(site)
      create_component!(site_id: site.id, name: "plainly", template: "<div>plain</div>")

      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "close_examples", %{})

      show_examples!(view, "plainly")

      assert view |> editor() |> Map.fetch!(:wizard) == %{},
             "one component's picks were carried into another component's wizard"
    end

    # THE PALETTE CARD AND THE WIZARD MUST AGREE. A preset is what a DRAG of this component places,
    # and the wizard opened on the kit's defaults instead — so the preview showed one thing, the
    # card placed another, and "make this the default" saved only what the reader had re-picked,
    # quietly dropping the rest of a preset they never meant to change.
    test "the wizard opens on this component's stored preset", %{
      conn: conn,
      page: page,
      site: site
    } do
      wizardly!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "wizardly")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})
      render_click(view, "save_preset", %{})
      render_click(view, "close_examples", %{})

      show_examples!(view, "wizardly")

      assert view |> editor() |> Map.fetch!(:wizard) == %{"variant" => "outline"},
             "the wizard opened on the kit's default while a drag would place the preset"
    end

    defp wizardly!(site) do
      create_component!(
        site_id: site.id,
        name: "wizardly",
        template: "<div class={color_variant(@variant, @kind)}>{render_slot(@inner_block)}</div>",
        attrs: [
          %{"name" => "variant", "type" => "string", "opts" => %{"default" => "default"}},
          %{"name" => "kind", "type" => "string", "opts" => %{"default" => "natural"}}
        ],
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}],
        helpers: [
          %{
            "name" => "color_variant",
            "code" => "defp color_variant(_, _), do: nil",
            "discriminators" => [
              %{"axis" => "variant", "values" => ["default", "outline"]},
              %{"axis" => "color", "values" => ["natural", "primary", "danger"]}
            ]
          }
        ],
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="wizardly" site="#{site.name}"/>)}
          ]
        }
      )
    end

    test "the wizard's preview canvas renders the composed component", %{
      conn: conn,
      page: page,
      site: site
    } do
      # The options are declared on the attributes here rather than mined from a helper: this test is
      # about the preview canvas rendering what the wizard composed, and a helper that fails to
      # compile would fail it for an unrelated reason.
      # The canvas renders a component through its COMPILED module, which a database row alone does
      # not produce inside a test.
      define_component!("previewable", site, "<div>previewed alert</div>")

      create_component!(
        site_id: site.id,
        name: "previewable",
        template: "<div class={@variant}>previewed alert</div>",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "default", "values" => ["default", "outline"]}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "outline"})

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}/wizard/previewable")

      assert html =~ "previewed alert"
      refute has_element?(canvas, "#pb-preview-bar")
    end

    # THE WIZARD LIVED BEHIND A DOOR WITH NO HANDLE. The badge that opens this modal was gated on
    # `has_examples?` — a calculation over `extra.examples` / `extra.demo_examples` — and the Wizard
    # tab is inside it. A kit shipping good `attrs` and no `extra` got a perfect palette tile, no
    # badge, and therefore no option pickers, no live preview and no Insert.
    test "a component with options but no examples still gets the badge", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "optiony",
        template: "<div class={@variant}>x</div>",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "default", "values" => ["default", "outline"]}
          }
        ],
        extra: %{}
      )

      {:ok, view, _html} = open_builder(conn, page)

      entry = Enum.find(editor(view).components, &(&1.name == "optiony"))

      refute entry[:has_examples?], "this component deliberately ships no examples"
      assert entry[:offers_options?], "but it does declare an option list"

      assert has_element?(view, "[phx-value-name=optiony][data-role=pb-variantbtn]"),
             "the badge is the only way to reach the Wizard"
    end

    # Landing a reader on an empty Examples tab would be a worse door than the one they could not
    # open before.
    test "a component with only options opens on the Wizard tab", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "wizardonly",
        template: "<div class={@variant}>x</div>",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "default", "values" => ["default", "outline"]}
          }
        ],
        extra: %{}
      )

      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "wizardonly")

      assert :sys.get_state(view.pid).socket.assigns.example_tab == :wizard
    end

    test "a component with examples still opens on Examples", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "exampley",
        template: "<div>x</div>",
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="exampley" site="#{site.name}"/>)}
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "exampley")

      assert :sys.get_state(view.pid).socket.assigns.example_tab == :examples
    end

    test "a component with no option lists gets no wizard tab", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "plainly",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{}}],
        extra: %{
          "examples" => [
            %{"source" => ~s(<.component component_name="plainly" site="#{site.name}"/>)}
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "plainly")

      refute has_element?(view, "#pb-example-tab-wizard")
    end

    # A NUMBER WRITTEN AS A STRING IS NOT A NUMBER. The stepper wrote `value="45"` onto an attribute
    # the kit declares `:integer`, which is a type error where Phoenix checks it and arithmetic on a
    # binary where it does not — a progress bar set to 45 drew a bare track and a section drew 0%,
    # so the box looked as though it did nothing. Reported for the linear bar and again for the
    # circular ones; it is every numeric attribute in the kit.
    test "a numeric property is written as an expression, not a string", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "counted",
        attrs: [
          %{"name" => "value", "type" => "integer", "opts" => %{"default" => 0}},
          %{"name" => "label", "type" => "string", "opts" => %{}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="counted" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "counted")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      view
      |> element(~s(form[phx-value-name="value"]))
      |> render_change(%{"value" => "45"})

      assert Node.attr(component_node(view, "counted"), "value") == {:expr, "45"},
             "the number went in as a string, which the component cannot do arithmetic on"

      # AND A STRING PROPERTY IS STILL A STRING. The kind is keyed on the DECLARED type, not on the
      # control, so a text box beside it is untouched.
      view
      |> element(~s(form[phx-value-name="label"]))
      |> render_change(%{"value" => "hello"})

      assert Node.attr(component_node(view, "counted"), "label") == {:string, "hello"}
    end

    # `kind="danger"` matches none of the component's clauses — they are written against the ATOM
    # `:danger` — so it falls through to the catch-all and every colour renders identically. The
    # kit's own examples write `kind={:primary}`; so must the panel.
    test "an atom property is written as an expression, not a string", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "atomic",
        attrs: [
          %{
            "name" => "kind",
            "type" => "atom",
            "opts" => %{"default" => "natural", "values" => ["natural", "danger", "success"]}
          },
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "base", "values" => ["base", "outline"]}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="atomic" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "atomic")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The control offers the bare name but carries the atom form as its value.
      html = render(view)
      assert html =~ ~s(value=":danger")
      assert html =~ ~s(phx-value-value_kind="expr")

      # Driven through the CONTROL, not by pushing the event by hand — three values make this a
      # segmented control, and the pill carries the atom form in its own `value`.
      view
      |> element(~s(button[phx-value-name="kind"][value=":danger"]))
      |> render_click()

      assert Node.attr(component_node(view, "atomic"), "kind") == {:expr, ":danger"}

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize() =~ "kind={:danger}"

      # …and the control marks it chosen, matching the stored `:danger` against the bare label.
      pill =
        render(view)
        |> String.split("<button")
        |> Enum.find(&String.contains?(&1, ~s(value=":danger")))

      assert pill, "the panel should render a pill carrying the atom form"
      assert pill =~ "bg-white"
    end

    test "a string property is still written as a string", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "stringy",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "base", "values" => ["base", "outline"]}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="stringy" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "stringy")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      refute html =~ ~s(value=":outline")
      assert html =~ ~s(value="outline")
    end

    # `kind={:danger}` is a literal like `size={5}` — parsing it is not evaluating it. Refusing atoms
    # meant the attribute never reached the component, so it rendered whatever its catch-all renders
    # and EVERY Chelekom alert came out `natural` whichever colour was chosen — including the kit's
    # own examples, which are written `kind={:primary}`.
    test "an atom expression reaches the component on the canvas", %{
      conn: conn,
      page: page,
      site: site
    } do
      define_component!("atom-canvas", site, "<div>atom canvas</div>")

      create_component!(
        site_id: site.id,
        name: "atom-canvas",
        template: "<div>atom canvas</div>",
        attrs: [%{"name" => "kind", "type" => "atom", "opts" => %{"default" => "natural"}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="atom-canvas" site="#{site.name}" kind={:danger}/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "atom-canvas")
      assert Node.attr(node, "kind") == {:expr, ":danger"}

      # The canvas is a second LiveView; what matters is that it renders the node without dropping
      # the attribute on the way in.
      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "atom canvas"
      refute html =~ "failed to render"
    end

    # A dropdown property could never be changed: `phx-change` on a bare `<select>` outside a form
    # fires no event, so 381 of the kit's attributes — `variant` and `color` among them — were inert
    # while the short ones beside them worked, because a segmented control is a button.
    test "a dropdown property applies to the document", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "droppy",
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{
              "default" => "base",
              "values" => ["base", "outline", "shadow", "bordered", "gradient", "filled"]
            }
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="droppy" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "droppy")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # Six values, so this is a dropdown rather than a segmented control.
      assert has_element?(view, ~s(form[phx-value-name="variant"] select))

      view
      |> element(~s(form[phx-value-name="variant"]))
      |> render_change(%{"value" => "outline"})

      assert Node.attr_text(component_node(view, "droppy"), "variant") == "outline"

      # …and clearing it removes the attribute rather than writing an empty string.
      view
      |> element(~s(form[phx-value-name="variant"]))
      |> render_change(%{"value" => ""})

      assert is_nil(Node.attr(component_node(view, "droppy"), "variant"))
    end

    # The site's compiled stylesheet is generated from the classes its own pages RENDER, so a
    # component's DEFAULT icon appears in no page's HTML and has no rule — `chelekom-alert` drew an
    # empty 28px box where its icon belongs. The canvas supplies the rules for the icons in play.
    test "the canvas carries the CSS for the icons it renders", %{
      conn: conn,
      page: page,
      site: site
    } do
      define_component!("iconful", site, "<div>iconful</div>")

      create_component!(
        site_id: site.id,
        name: "iconful",
        template: "<div>iconful</div>",
        attrs: [
          %{"name" => "icon", "type" => "any", "opts" => %{"default" => "hero-bell"}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="iconful" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # The DEFAULT reaches the stylesheet even though the document never names it…
      assert html =~ "pb-canvas-icons"
      assert html =~ ".hero-bell{"
      assert html =~ "background-color:currentColor"
    end

    test "an icon set on a node reaches the canvas stylesheet too", %{
      conn: conn,
      page: page,
      site: site
    } do
      define_component!("iconset", site, "<div>iconset</div>")

      create_component!(
        site_id: site.id,
        name: "iconset",
        template: "<div>iconset</div>",
        attrs: [%{"name" => "icon", "type" => "any", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="iconset" site="#{site.name}" icon="hero-rocket-launch"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ".hero-rocket-launch{"
    end

    # Committing on blur meant a change only landed when you clicked somewhere else: typing a title
    # and watching the canvas showed nothing until you clicked away. Every field is a debounced form
    # now — which is also the only shape LiveView delivers `phx-value-*` through.
    test "a text property applies as you type, without leaving the field", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "typey",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="typey" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      node = component_node(view, "typey")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The field is a form with a debounce, not a bare input that waits for blur.
      assert has_element?(view, ~s(form[phx-value-name="title"] input[phx-debounce]))

      view
      |> element(~s(form[phx-value-name="title"]))
      |> render_change(%{"value" => "Heads up"})

      assert Node.attr_text(component_node(view, "typey"), "title") == "Heads up"

      # Clearing it removes the property rather than writing an empty string.
      view
      |> element(~s(form[phx-value-name="title"]))
      |> render_change(%{"value" => ""})

      assert is_nil(Node.attr(component_node(view, "typey"), "title"))
    end

    # A design token is a declaration in the site's own theme stylesheet — `--danger-light: #de1135`
    # — and every component that resolves through it changes at once. That is the one thing the
    # Studio can do that no per-element control can, and it was sample data until now.
    test "the Studio lists the site's real tokens and writes one back", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n  --danger-light: #de1135;\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      html = render(view)

      # The site's OWN token, not the sample set.
      assert html =~ "Danger light"
      assert has_element?(view, "#pb-token-value-danger-light")

      view
      |> element("#pb-token-form-danger-light")
      |> render_change(%{"value" => "#ff0000"})

      assert MishkaCmsCore.Runtime.PageBuilder.Tokens.list(site.id)
             |> Enum.find(&(&1.key == "danger-light"))
             |> Map.fetch!(:value) == "#ff0000"
    end

    test "the swatch is a colour picker, and writing through it sets the token", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content:
              ":root {\n  --pick-full: #de1135;\n  --pick-short: #abc;\n  --pick-oklch: oklch(0.7 0.1 200);\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      # The token table loads in a Task, so the click returns before the rows exist — same reason
      # `open_builder/2` awaits after `live/2`.
      _loaded = render_async(view)

      assert has_element?(
               view,
               ~s(input#pb-token-swatch-pick-full[type="color"][value="#de1135"])
             )

      # `#abc` is `#aabbcc` — a colour input accepts only the six-digit form.
      assert has_element?(
               view,
               ~s(input#pb-token-swatch-pick-short[type="color"][value="#aabbcc"])
             )

      # `oklch(…)` IS a colour token, and a colour input cannot hold one: handing it a value it
      # cannot parse would show black and write black back on the first click. It keeps the plain
      # swatch, and its text field stays the way to edit it.
      refute has_element?(view, "#pb-token-swatch-pick-oklch")
      assert has_element?(view, "#pb-token-value-pick-oklch")

      view
      |> element("#pb-token-swatch-form-pick-full")
      |> render_change(%{"value" => "#00ff00"})

      assert MishkaCmsCore.Runtime.PageBuilder.Tokens.list(site.id)
             |> Enum.find(&(&1.key == "pick-full"))
             |> Map.fetch!(:value) == "#00ff00"
    end

    test "load more grows the list, and editing a token keeps what was loaded", %{
      conn: conn,
      page: page
    } do
      declarations =
        Enum.map_join(1..40, "\n", fn n ->
          "  --bulk-#{String.pad_leading(to_string(n), 2, "0")}: #de11#{String.pad_leading(to_string(n), 2, "0")};"
        end)

      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n#{declarations}\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      assert token_rows(render(view)) == 30

      view |> element("#pb-token-more") |> render_click()
      assert token_rows(render(view)) == 40

      # The reader built that depth by clicking. Writing a token reloads the list — and the reload
      # has to return everything they had, not drop them back to the first page.
      view
      |> element("#pb-token-swatch-form-bulk-01")
      |> render_change(%{"value" => "#00ff00"})

      assert token_rows(render(view)) == 40
    end

    test "a value a stylesheet cannot hold is refused with a reason", %{conn: conn, page: page} do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "studio-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n  --brand: #0b6f68;\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      html =
        view
        |> element("#pb-token-form-brand")
        |> render_change(%{"value" => "red; } body { display: none"})

      assert html =~ "not a value a stylesheet can hold"
    end

    test "the inspector shows the selected element", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      assert html =~ "section"
      assert html =~ ~s(data-role="pb-bptabs")
      assert html =~ "Attributes"
    end

    # TWO ELEMENTS ANSWERING TO ONE ID. Every palette entry is a worked example and an example names
    # things — the kit's delete dialog ships `id="modal-delete-page"` with `id="btn-delete-cancel"`
    # inside it. Placing one twice, which is how an author builds the second dialog, put both names
    # in the document twice: the second button then opened the FIRST dialog, and LiveView raises
    # trying to patch a container it cannot tell apart.
    test "placing the same snippet twice renumbers the copy and repoints its own wiring", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      snippet =
        ~S|<div id="modal-delete-page">Are you sure?</div>| <>
          ~S|<button id="btn-delete" phx-click={JS.exec("data-pb-open", to: "#modal-delete-page")}>Delete</button>|

      for index <- ["0", "1"] do
        render_click(view, "op", %{
          "kind" => "insert",
          "template" => snippet,
          "parent_id" => section.id,
          "index" => index
        })
      end

      tree = editor(view).tree
      written = for node <- Tree.walk(tree), {:string, id} <- [Node.attr(node, "id")], do: id

      assert Enum.sort(written) == [
               "btn-delete",
               "btn-delete-2",
               # the fixture's own <section id="hero">
               "hero",
               "modal-delete-page",
               "modal-delete-page-2"
             ]

      assert length(Enum.uniq(written)) == length(written), "no id may be claimed twice"

      # And the copy's own button opens the copy, not the dialog that was already there.
      openers =
        for node <- Tree.walk(tree),
            {:expr, source} <- [Node.attr(node, "phx-click")],
            do: source

      assert Enum.sort(openers) == [
               ~S|JS.exec("data-pb-open", to: "#modal-delete-page")|,
               ~S|JS.exec("data-pb-open", to: "#modal-delete-page-2")|
             ]
    end

    # DUPLICATE USED TO ANSWER THIS DIFFERENTLY AND WORSE: it replaced the written id with a random
    # one, so `modal-delete-page` became `phx-F_3nK…` — the author's name for the element thrown
    # away — and nothing rewrote the copy's own button, which went on opening the original.
    test "duplicating keeps the author's name for the element and takes the next number", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~S|<div id="pricing-card"><a href="#pricing-card">anchor</a></div>|,
        "parent_id" => section.id,
        "index" => "0"
      })

      card =
        editor(view).tree
        |> Tree.walk()
        |> Enum.find(&(Node.attr(&1, "id") == {:string, "pricing-card"}))

      render_click(view, "op", %{"kind" => "duplicate", "node_id" => card.id})

      tree = editor(view).tree
      written = for node <- Tree.walk(tree), {:string, id} <- [Node.attr(node, "id")], do: id

      assert Enum.sort(written) == ["hero", "pricing-card", "pricing-card-2"]

      hrefs = for node <- Tree.walk(tree), {:string, href} <- [Node.attr(node, "href")], do: href
      assert Enum.sort(hrefs) == ["#pricing-card", "#pricing-card-2"]
    end

    # A SEARCH BOX WITH NO WAY OUT. Every filtered list in the editor is filtered by a word held on
    # the SERVER, so selecting the text and deleting it is the only way back to the full list — and
    # nothing on the field said so. The ✖ is shown by `peer-placeholder-shown:hidden`, which is a
    # CSS answer to a CSS question: an input is `:placeholder-shown` exactly while it is empty.
    test "every live text field in the editor carries a clear control", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      render_click(view, "set_left_tab", %{"tab" => "blocks"})
      render_click(view, "toggle_command", %{})
      render_click(view, "open_find", %{})

      html = render(view)

      for field <- ~w(pb-palette-search pb-block-search pb-command-input pb-find-input
                      pb-replace-input) do
        assert html =~ ~s(data-for="#{field}"),
               "#{field} has no clear control"
      end

      # Shown by CSS alone, so an empty field never draws one and no round trip reveals it.
      assert html =~ "peer-placeholder-shown:hidden"
    end

    test "clicking the clear control blanks the field the server is filtering by", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      render_click(view, "palette_query", %{"value" => "zzzznothing"})
      assert view |> element("#pb-palette-search") |> render() =~ ~s(value="zzzznothing")

      view |> element(~s([data-for="pb-palette-search"])) |> render_click()

      # The box AND the query behind the list, in one round trip — clearing only the box would leave
      # the list filtered by a word no longer written anywhere.
      assert view |> element("#pb-palette-search") |> render() =~ ~s(value="")
    end

    # AND THE CONTROL MUST NOT FOCUS THE FIELD IT JUST CLEARED. LiveView never overwrites the value
    # of a focused input — `mergeFocusedInput` copies every attribute except `value` — so a
    # `JS.focus` in this chain left the box still reading the old word over a list that had gone back
    # to everything. Measured in a browser; the half-cleared state is invisible to a render test,
    # which is why the command itself is asserted here.
    test "the clear control pushes and does not focus the field", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      command =
        view
        |> element(~s([data-for="pb-palette-search"]))
        |> render()

      assert command =~ ~s([&quot;push&quot;)
      refute command =~ "focus", "focusing the field stops LiveView from clearing it"
    end

    # ONE FORM, TWO FIELDS, ONE HANDLER THAT READS BOTH. Clearing the search term by pushing only
    # `find` would have sent no `replace` at all, and the handler's `params["replace"] || ""` would
    # have thrown away the replacement text sitting in the box beside it.
    test "clearing Find leaves Replace alone, and the other way round", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_find", %{})
      render_click(view, "find_query", %{"find" => "Contact", "replace" => "Reach"})

      view |> element(~s([data-for="pb-find-input"])) |> render_click()

      assert view |> element("#pb-find-input") |> render() =~ ~s(value="")
      assert view |> element("#pb-replace-input") |> render() =~ ~s(value="Reach")

      render_click(view, "find_query", %{"find" => "Contact", "replace" => "Reach"})
      view |> element(~s([data-for="pb-replace-input"])) |> render_click()

      assert view |> element("#pb-find-input") |> render() =~ ~s(value="Contact")
      assert view |> element("#pb-replace-input") |> render() =~ ~s(value="")
    end

    # THE CHIP PROMISED AN EDITOR THAT DID NOT EXIST. An expression on the canvas carries the title
    # "edit its source in the inspector", and the inspector had nothing for one — so `{@inner_content}`
    # in a layout and `{render_slot(@inner_block)}` in a component, the two expressions those
    # documents are built on, could be selected, moved and deleted but changed only through the code
    # drawer.
    test "an expression's source is editable in the inspector", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "shell",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))
      assert expression, "the fixture has to contain an expression"

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})
      assert has_element?(view, "#pb-expr-input-#{expression.id}")

      render_change(view, "op", %{
        "kind" => "set_text",
        "node_id" => expression.id,
        "text" => "@inner_content |> raw()"
      })

      assert Tree.get(editor(view).tree, expression.id).text == "@inner_content |> raw()"
      assert {:ok, heex} = Serializer.to_heex(editor(view).tree)
      assert heex =~ "{@inner_content |> raw()}"
    end

    # A TEXT FIELD WHOSE ONLY GUIDANCE IS A PLACEHOLDER asks the author to remember the names of
    # things this editor already knows. The box stays — what goes in it is Elixir — but beside it now
    # are the names THIS document actually has, read off its own declaration rather than listed here.
    test "and the box offers what the component itself declares", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "offering",
          template: ~s|<div>{@size}</div>|,
          attrs: [%{"name" => "size", "type" => "string"}, %{"name" => "tone", "type" => "atom"}],
          slots: [%{"name" => "inner_block"}, %{"name" => "actions"}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      assert has_element?(view, "#pb-expr-offer-#{expression.id}-size")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-tone")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-actions")

      # A slot is offered as the call that RENDERS it, because naming it is not what anybody wants.
      assert view |> element("#pb-expr-offer-#{expression.id}-inner_block") |> render() =~
               "render_slot(@inner_block)"

      # And the free-text box is still there.
      assert has_element?(view, "#pb-expr-input-#{expression.id}")
    end

    test "and pressing one writes it", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "offering-write",
          template: ~s|<div>{@size}</div>|,
          attrs: [%{"name" => "size", "type" => "string"}],
          slots: [%{"name" => "actions"}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      view |> element("#pb-expr-offer-#{expression.id}-actions") |> render_click()

      assert Tree.get(editor(view).tree, expression.id).text == "render_slot(@actions)"

      # One op, so one undo back to what was typed before.
      render_click(view, "undo", %{})
      assert Tree.get(editor(view).tree, expression.id).text == "@size"
    end

    # READ OFF THE RECORD, so it follows the declaration rather than a list in the editor.
    test "offering nothing for a component that declares nothing", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "offering-nothing",
          template: ~s|<div>{@size}</div>|,
          attrs: [],
          slots: []
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      refute has_element?(view, "#pb-expr-offers-#{expression.id}")
      assert has_element?(view, "#pb-expr-input-#{expression.id}"), "the box is still there"
    end

    # An error page is handed three things on exactly the same footing as a layout's one: the
    # compiler binds `conn`, `status` and `site` before the stored template renders, unconditionally.
    # It was falling into the page's clause — which offers nothing, because a page's assigns come
    # from handlers — so the one section with guaranteed assigns was the one offered none.
    test "an error page offers the three its compiler binds", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          name: "offering-errors",
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => ~s(<div>{@status}</div>)}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      _loaded = render_async(view)
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      assert has_element?(view, "#pb-expr-offer-#{expression.id}-status")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-conn")
      assert has_element?(view, "#pb-expr-offer-#{expression.id}-site")

      # And it stops being told about handlers it cannot hold.
      html = render(view)
      assert html =~ "served by a controller"
      refute html =~ "the page's own handlers"
    end

    # A layout is handed exactly one thing and it is the thing a layout is FOR; a page's assigns come
    # from handlers this editor does not evaluate, so it offers none rather than guessing.
    test "a layout offers the one assign it is handed, and a page offers none", %{
      conn: conn,
      site: site,
      page: page
    } do
      layout =
        create_layout!(
          name: "offering-shell",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      expression = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => expression.id})

      assert has_element?(view, "#pb-expr-offer-#{expression.id}-inner_content")

      {:ok, pages, _html} = open_builder(conn, page)
      on_page = Enum.find(Tree.walk(editor(pages).tree), &(&1.kind == :eex))

      if on_page do
        render_click(pages, "set_left_tab", %{"tab" => "inspector"})
        render_click(pages, "select", %{"id" => on_page.id})
        refute has_element?(pages, "#pb-expr-offers-#{on_page.id}")
      end
    end

    # A `<%= for … do %>` owns everything nested inside it, so a text box would rewrite the block and
    # drop its children. It opens the document's code instead of offering one — on the Template tab,
    # which is where the block is, whichever tab the window was last left on.
    test "a block expression is sent to the code rather than given a box", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><%= for post <- @posts do %><p>x</p><% end %></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      block = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex_block))
      assert block, "the fixture has to contain a block expression"

      render_click(view, "open_source", %{"tab" => "styles"})
      render_click(view, "close_source", %{})

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => block.id})

      assert has_element?(view, "#pb-expr-block-note")
      refute has_element?(view, "#pb-expr-input-#{block.id}")

      view |> element("#pb-expr-block-open-code") |> render_click()

      assert has_element?(view, "#pb-source-modal")
      assert has_element?(view, "#pb-source-copy"), "the Template tab, not the one it was left on"
    end

    # WHAT AN EXPRESSION CAN NAME DEPENDS ON WHAT IS BEING EDITED, and the panel that offers them
    # has to agree: a page is never handed `@inner_content`.
    test "the element library offers the page-content slot only where it exists", %{
      conn: conn,
      site: site,
      page: page
    } do
      layout =
        create_layout!(name: "shell", site_id: site.id, template: ~s(<div>{@inner_content}</div>))

      {:ok, layout_view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      render_click(layout_view, "set_left_tab", %{"tab" => "blocks"})
      assert render(layout_view) =~ "Page content"

      {:ok, page_view, _html} = open_builder(conn, page)
      render_click(page_view, "set_left_tab", %{"tab" => "blocks"})

      page_html = render(page_view)
      refute page_html =~ "Page content"
      # The one that belongs everywhere is still there.
      assert page_html =~ "Any Elixir the document can evaluate"
    end

    # A RUNTIME COMPONENT IS BUILT ON FIRST USE, which is right — a kit of 136 must not compile 136
    # modules to open a page that places five. But the canvas walks the tree NODE BY NODE and blocks
    # on each one in turn: measured cold against the real kit, five components are 623 ms serial and
    # 358 ms asked for together, because `chelekom-button-link` alone is 295 ms of it.
    #
    # So the mount asks for all of them at once. Which components get built does not change, and
    # neither does when they are first needed — only the shape of the wait.
    test "opening the editor compiles the document's components before the canvas asks", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          name: "warm-box",
          site_id: site.id,
          template: ~S|<div class="warm">{render_slot(@inner_block)}</div>|
        )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<div id="root"><.component component_name="warm-box" site="#{site.name}">hi</.component></div>|
        )

      module = Helpers.module_name(component.name, site.name, "Component")
      :code.purge(module)
      :code.delete(module)
      refute Helpers.loaded?(module), "the fixture has to start cold"

      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      # The canvas has never mounted; the module is there because the mount asked for it.
      assert Helpers.loaded?(module),
             "the editor did not warm the components its own document uses"
    end

    test "the layers panel lists the document's elements", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-layers")
      assert render(view) =~ "section"
    end

    test "the audit rail reports a real finding, grouped and scored", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~s(<img src="a.png">),
        "parent_id" => section.id,
        "index" => "0"
      })

      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Image missing alt text"
      assert html =~ "no alt attribute"
      assert html =~ "Accessibility"
      assert html =~ "1 issue"
      # A blocker costs 12, so the ring reads 88 rather than a flat 100.
      assert html =~ "88"
      assert has_element?(view, ~s([data-rule="img-alt"]))
    end

    test "every group is shown even when it passes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      # A group that vanishes when it passes reads as a check that never ran.
      assert html =~ "Accessibility"
      assert html =~ "SEO &amp; Meta"
      assert html =~ "Performance"
      assert html =~ "healthy"
      assert html =~ "Page score"

      # SEO is measured from the page's own fields: this fixture has a description but no social
      # image and a short title, and that is exactly what the rail reports.
      assert html =~ "Open Graph image not set"
      assert html =~ "Add an og:image tag so link previews show a picture."
      refute html =~ "site default"
      assert html =~ "Title is short"
      refute html =~ "Meta description missing"
    end

    # The SEO lines read the record, not the canvas — a page that sets its tags is clean.
    test "a page with its meta tags set passes the SEO checks", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          title: String.duplicate("a", 52),
          description: "A real description for this page.",
          seo_tags: [
            %{tag: "meta", attrs: %{"name" => "description"}, content: "A real description."},
            %{tag: "meta", attrs: %{"property" => "og:image"}, content: "/img/social.png"}
          ],
          template: ~s(<div id="root"><h1>Title</h1></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      refute html =~ "Meta description missing"
      refute html =~ "Open Graph image not set"
      refute html =~ "Title is short"
    end

    # `<title>` reads the page's `title`; its `name` is the key it is filed under.
    test "the title is measured on the page's title, not its name", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          name: String.duplicate("a", 52),
          title: "Short",
          template: ~s(<div id="root"><h1>Title</h1></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Title is short"
    end

    # A layout has no `title` and names no tab, so nothing is asked about one.
    test "a layout is asked nothing about a title", %{conn: conn, site: site} do
      layout =
        create_layout!(site_id: site.id, template: ~s(<div id="shell">{@inner_content}</div>))

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _settled = render_async(view)
      view |> element("#pb-rail-audit") |> render_click()
      html = render(view)

      assert html =~ "SEO &amp; Meta"
      refute html =~ "Title is short"
      refute html =~ "Title is long"
      refute html =~ "Page has no title"
    end

    test "Fix scopes the assistant to the finding's own element", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~s(<img src="a.png">),
        "parent_id" => section.id,
        "index" => "0"
      })

      view |> element("#pb-rail-audit") |> render_click()
      view |> element(~s([data-rule="img-alt"])) |> render_click()

      html = render(view)
      assert html =~ "Write an alt attribute"
      # The offending node is selected, so the request is scoped to it.
      assert editor(view).selection
      assert has_element?(view, "#pb-ai-form")
    end

    test "a heading that skips a level is reported", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><h1>A</h1><h3>B</h3></div>))
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Heading order skips a level"
      assert html =~ "h1 is followed directly by h3"
    end

    # A field with no form around it renders perfectly and submits nothing, so the rail is the only
    # place the author can find out.
    test "a field with no form around it is a blocker in the Forms group", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>Sign up</h1><input name="email" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Forms"
      assert html =~ "This field is not inside a form"
      assert html =~ "never leaves the page"
      assert has_element?(view, ~s([data-rule="field-no-form"]))
    end

    test "the Forms group is not shown on a page with no form and no field", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Accessibility"
      refute html =~ "Every field is inside a form"
    end

    test "Fix wraps the stray field in a real form, in one undo step", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>Sign up</h1><input name="email" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()
      view |> element(~s([data-rule="field-no-form"])) |> render_click()

      assert [spec] = declared_forms(view)
      assert spec.as == "form"
      assert spec.assign == :form_form
      assert spec.id == "form"
      assert spec.change =~ ~r/^form-[a-z2-7]{5}-validate$/
      assert spec.submit =~ ~r/^form-[a-z2-7]{5}-submit$/
      assert spec.fields == [%{key: :email, type: :string, rules: []}]

      refute render(view) =~ "This field is not inside a form"

      undo!(view)

      assert declared_forms(view) == []
      assert node_with_tag(view, "input")
    end

    test "Fix appends a submit button to a form that has none", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name={f[:email].name} /></.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "This form has no submit button"

      view |> element(~s([data-rule="form-no-submit"])) |> render_click()

      [send] =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.filter(&(&1.tag == "button"))

      assert Node.attr_text(send, "type") == "submit"
      assert Node.attr_text(send, "class") =~ "bg-slate-900"
      assert node_parent(view, send.id) == node_with_tag(view, ".form").id

      refute render(view) =~ "This form has no submit button"
    end

    # A code author's Fix opens the form's On submit in the Code window; the assistant is not asked.
    test "Fix on a form nothing receives opens its On submit for a code author", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit"><input name={f[:email].name} /><button type="submit">Send</button></.form></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Nothing receives this form"

      view |> element(~s([data-rule="form-no-destination"])) |> render_click()

      assert has_element?(view, "#pb-form-handlers")
      assert [%{"name" => "q_submit"}] = fragments(view).events
      refute has_element?(view, "#pb-ai-form")
    end

    # A RULE IS NOT A FINDING. `form-no-destination` fires once per form, so naming the Fix button
    # after the rule alone put two elements with one id in the document as soon as a page had two
    # forms. `document.getElementById` answers whichever came first, so the second row's Fix drove
    # the first row's node.
    test "two forms raising one rule get one Fix button each, with ids of their own", %{
      conn: conn,
      site: site
    } do
      form = fn seed ->
        ~s(<.form :let={f} id="#{seed}-form" as={:#{seed}} for={assigns[:#{seed}_form]} ) <>
          ~s(phx-change="#{seed}_validate" phx-submit="#{seed}_submit">) <>
          ~s(<input name={f[:email].name} /><button type="submit">Send</button></.form>)
      end

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root">) <> form.("one") <> form.("two") <> ~s(</div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      ids =
        view
        |> render()
        |> then(&Regex.scan(~r/id="(pb-audit-fix-form-no-destination[^"]*)"/, &1))
        |> Enum.map(&List.last/1)

      assert length(ids) == 2
      assert length(Enum.uniq(ids)) == 2
    end

    # THE ONE PAGE WHERE THE EDITOR KNOWS BOTH CANDIDATES. Two forms used to send this Fix to the
    # assistant, which from the author's seat is a button that only changes panels.
    test "Fix moves a stray submit button into a form even when the page has two", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /><button type="submit">Send</button></.form><.form :let={g} id="signup-form" as={:signup} for={assigns[:signup_form]} phx-change="signup_validate" phx-submit="signup_submit"><input name={g[:email].name} /><button type="submit">Join</button></.form><button type="submit">Go</button></div>),
          events: [
            %{name: "contact_submit", code: "{:noreply, socket}"},
            %{name: "signup_submit", code: "{:noreply, socket}"}
          ]
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "This submit button is not inside a form"

      stray = view |> tagged("button") |> List.last()
      view |> element(~s([data-rule="submit-no-form"])) |> render_click()

      assert node_parent(view, stray.id) ==
               view |> tagged(".form") |> List.last() |> Map.fetch!(:id)

      refute has_element?(view, "#pb-ai-form")
    end
  end

  @bound_form ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /><input name="loose" /></.form></div>)

  @two_forms ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /></.form><.form :let={g} id="signup-form" as={:signup} for={assigns[:signup_form]} phx-change="signup_validate" phx-submit="signup_submit"><input name={g[:email].name} /></.form></div>)

  @strip ~s(data-role="pb-bptabs")

  # THE ENGINE WAS FINISHED AND NOTHING DREW IT. Every function under here had unit tests and no
  # caller: clicking a bound field showed State, Layout, Appearance and Behavior, and the two
  # sections that make a form a working form were not in the panel at all.
  describe "the Form and Validation sections" do
    defp tagged(view, tag),
      do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.filter(&(&1.tag == tag))

    defp node_again(view, id), do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id)

    defp inspecting(view, node) do
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
    end

    # THE REAL ROWS, the way an install writes them: the kit's own template and attributes.
    defp kit_rows!(site, rows) do
      for row <- rows do
        create_component!(
          site_id: site.id,
          name: row.name,
          template: row.template,
          attrs: row.attrs,
          slots: row.slots
        )
      end
    end

    defp chelekom_button!(site), do: kit_rows!(site, chelekom_rows(~w(chelekom-button)))

    defp pill(view), do: view |> element("#pb-form-part") |> render()

    defp kit_buttons(view),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.filter(&(Node.component_name(&1) == "chelekom-button"))

    @kit_page ~s(<div id="root"><section id="hero">) <>
                ~s(<.component component_name="chelekom-button" site="localhost">Start free</.component>) <>
                ~s(</section><.form :let={f} id="q-form" as={:q} for={assigns[:q_form]} phx-change="q_validate" phx-submit="q_submit">) <>
                ~s(<input name={f[:email].name} /><div class="card"><div class="grid"><div class="col">) <>
                ~s(<.component component_name="chelekom-button" site="localhost">Send</.component>) <>
                ~s(<.component component_name="chelekom-button" site="localhost" type="button">Preview</.component>) <>
                ~s(</div></div></div></.form></div>)

    test "the header says a kit button deep in a form is its Submit button", %{
      conn: conn,
      site: site
    } do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [_hero, send, _preview] = kit_buttons(view)

      inspecting(view, send)

      assert has_element?(view, ~s(#pb-form-part[data-part="submit"]))
      assert pill(view) =~ "Submit button"
    end

    test "and one that says type=button does not send the form", %{conn: conn, site: site} do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [_hero, _send, preview] = kit_buttons(view)

      inspecting(view, preview)

      assert pill(view) =~ "Button · does not send the form"
      refute pill(view) =~ "Submit button"
    end

    test "and one outside every form is just a Button", %{conn: conn, site: site} do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [hero, _send, _preview] = kit_buttons(view)

      inspecting(view, hero)

      assert has_element?(view, ~s(#pb-form-part[data-part="button"]))
      refute pill(view) =~ "Submit"
      refute pill(view) =~ "does not send"
    end

    test "the form is a Form, its field a Field, and a plain box says nothing", %{
      conn: conn,
      site: site
    } do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)

      inspecting(view, node_with_tag(view, ".form"))
      assert pill(view) =~ "Form"

      inspecting(view, node_with_tag(view, "input"))
      assert pill(view) =~ "Field"

      inspecting(view, node_with_tag(view, "section"))
      refute has_element?(view, "#pb-form-part")
    end

    test "no developer words ride along in a tooltip", %{conn: conn, site: site} do
      chelekom_button!(site)
      page = create_page!(site_id: site.id, template: @kit_page)
      {:ok, view, _html} = open_builder(conn, page)
      [_hero, send, _preview] = kit_buttons(view)

      inspecting(view, send)

      assert has_element?(view, "#pb-form-part")
      refute has_element?(view, "#pb-form-part[title]")
      refute has_element?(view, "#pb-form-part [title]")
    end

    # Two forms, each with its fields in a column of a grid in a card: Phoenix's own, and Chelekom's
    # Simple Form installed under another name and holding `for={%{}}` as the palette seeds it, so
    # only its markup marks it as a form.
    @deep_forms ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit">) <>
                  ~s(<div class="card"><div class="grid"><div id="contact-col"><input name={f[:email].name} /></div></div></div></.form>) <>
                  ~s(<.component component_name="acme-simple" site="localhost" :let={w} id="signup-form" for={%{}}>) <>
                  ~s(<div class="card"><div class="grid"><div id="signup-col"><input name={w[:email].name} /></div></div></div></.component></div>)

    defp renamed_forms!(site),
      do:
        kit_rows!(
          site,
          renamed_form_pair(chelekom_rows(~w(chelekom-form-wrapper chelekom-simple-form)))
        )

    defp with_dom_id(view, id),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "id") == id))

    defp drop_into(view, id, template),
      do:
        render_click(view, "drop", %{
          "template" => template,
          "parent_id" => with_dom_id(view, id).id,
          "index" => "0"
        })

    test "a form dropped into a column of another form's card is refused", %{
      conn: conn,
      site: site
    } do
      renamed_forms!(site)
      page = create_page!(site_id: site.id, template: @deep_forms)
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)

      for column <- ~w(contact-col signup-col),
          template <- [
            ~s(<.component component_name="acme-simple" site="localhost" for={%{}}></.component>),
            Elements.get("el-form").template
          ] do
        drop_into(view, column, template)

        assert flashes(view) =~ "inside another form", "#{template} into #{column}"
        clear_flashes(view)
      end

      assert node_count(view) == before
    end

    test "a field dropped into either form's column joins that form", %{conn: conn, site: site} do
      renamed_forms!(site)
      page = create_page!(site_id: site.id, template: @deep_forms)
      {:ok, view, _html} = open_builder(conn, page)

      drop_into(view, "signup-col", ~s(<input name="phone" />))
      drop_into(view, "contact-col", ~s(<input name="phone" />))

      document = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()

      assert document =~ ~s(name={w[:phone].name})
      assert document =~ ~s(name={f[:phone].name})
      assert length(tagged(view, ".form")) == 1, "no second form was made around either field"
    end

    # Another kit's contact form: its one outer element is that kit's form component and its `for`
    # is optional, so only the palette says it owns a form.
    defp acme_forms!(site) do
      create_component!(
        site_id: site.id,
        name: "acme-form",
        attrs: [%{"name" => "for", "type" => "any", "opts" => %{"required" => true}}],
        slots: [%{"name" => "inner_block"}],
        template: ~S|<.form :let={f} for={@for}>{render_slot(@inner_block, f)}</.form>|
      )

      create_component!(
        site_id: site.id,
        name: "acme-contact",
        attrs: [
          %{"name" => "for", "type" => "any", "opts" => %{}},
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => "plain", "values" => ["plain", "boxed"]}
          }
        ],
        slots: [%{"name" => "inner_block"}],
        template:
          ~S|<.component component_name="acme-form" site="localhost" :let={f} for={@for} class={@variant}>{render_slot(@inner_block, f)}</.component>|
      )
    end

    defp contact_in(tree),
      do: tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "acme-contact"))

    defp placed_contact(view), do: view |> editor() |> Map.fetch!(:tree) |> contact_in()

    test "a form calling another kit's form is carded with an empty map, and placed working", %{
      conn: conn,
      page: page,
      site: site
    } do
      acme_forms!(site)
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s(#pb-comp-acme-contact[data-template*="for={%{}}"]))

      view |> element("#pb-comp-acme-contact") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      # On a Page it then arrives working (spec 4.4): its own page assign, `:let` and names.
      assert Node.attr(placed_contact(view), "for") == {:expr, "assigns[:form_form]"}
      assert Node.attr(placed_contact(view), ":let") == {:expr, "f"}
    end

    test "and inserted from its wizard the same way", %{conn: conn, page: page, site: site} do
      acme_forms!(site)
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "acme-contact")
      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "boxed"})

      assert has_element?(view, "#pb-example-code-body", "for={%{}}")

      render_click(view, "insert_wizard", %{})

      assert Node.attr(placed_contact(view), "for") == {:expr, "assigns[:form_form]"}
      assert Node.attr_text(placed_contact(view), "variant") == "boxed"
    end

    test "and previewed from its wizard the same way", %{conn: conn, page: page, site: site} do
      acme_forms!(site)
      define_component!("acme-contact", site, "<div>contact form</div>")
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}/wizard/acme-contact")

      previewed = fn -> contact_in(:sys.get_state(canvas.pid).socket.assigns.tree) end

      assert Node.attr(previewed.(), "for") == {:expr, "%{}"}

      render_click(view, "wizard_pick", %{"name" => "variant", "value" => "boxed"})

      assert Node.attr_text(previewed.(), "variant") == "boxed"
      assert Node.attr(previewed.(), "for") == {:expr, "%{}"}
    end

    test "Validation shows on a field bound to one of its form's keys", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")

      inspecting(view, bound)

      assert has_element?(view, "#pb-section-validation")
      assert has_element?(view, "#pb-rule-required")
      assert has_element?(view, "#pb-rule-minlength")
      assert has_element?(view, "#pb-rule-pattern")
      refute has_element?(view, "#pb-section-form")
    end

    test "the form itself gets Form, and no rules of its own", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)

      inspecting(view, node_with_tag(view, ".form"))

      assert has_element?(view, "#pb-section-form")
      assert has_element?(view, "#pb-rule-seed")
      assert has_element?(view, "#pb-rule-success")
      refute has_element?(view, "#pb-section-validation")
    end

    # THE PALETTE CARD PROMISES THIS IN WORDS — "A working form with one field. Rename it in the
    # Inspector." — so the card and the panel are asserted together: a form that arrives from the
    # Forms palette is one the rename control opens on.
    test "a form dropped from the palette is one the Inspector can rename", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "section").id})
      render_click(view, "pick_block", %{"block" => "el-form"})

      inspecting(view, node_with_tag(view, ".form"))

      assert has_element?(view, "#pb-rule-seed")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      assert [%{as: "enquiry"}] = declared_forms(view)
    end

    # ABOVE THE BREAKPOINT STRIP, where the component properties are. Drawn inside it these sat under
    # "Recorded against 560px and below", and every control in them writes a plain attribute — one
    # value for the whole page. An author would have read the panel as offering a mobile-only
    # `required`, and set one that does not exist.
    test "neither section is drawn inside the breakpoint body", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")

      assert before?(inspecting(view, bound), ~s(id="pb-section-validation"), @strip)

      assert before?(
               inspecting(view, node_with_tag(view, ".form")),
               ~s(id="pb-section-form"),
               @strip
             )
    end

    defp before?(html, first, second) do
      {at, _length} = :binary.match(html, first)
      {then_at, _length} = :binary.match(html, second)

      at < then_at
    end

    # A LOOSE `<input name="loose">` IS A FIELD AND NOT A BOUND ONE, so it has no key for a rule to
    # hang off — offering rules on it would write constraints the changeset never reads.
    test "and a loose control inside the form gets neither", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [_bound, loose] = tagged(view, "input")

      inspecting(view, loose)

      refute has_element?(view, "#pb-section-validation")
      refute has_element?(view, "#pb-section-form")
    end

    test "Required writes the attribute, and turning it off takes it away", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")
      inspecting(view, bound)

      view |> element("#pb-rule-required") |> render_click()

      assert Node.attr(node_again(view, bound.id), "required") == :boolean

      # `required=""` is still required to a browser, so a rule turned off has to be deleted.
      view |> element("#pb-rule-required") |> render_click()

      assert is_nil(Node.attr(node_again(view, bound.id), "required"))
    end

    test "Min length writes minlength, and clearing it removes the rule", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      [bound, _loose] = tagged(view, "input")
      inspecting(view, bound)

      view |> element("#pb-rule-form-minlength") |> render_change(%{"value" => "5"})

      assert Node.attr_text(node_again(view, bound.id), "minlength") == "5"

      view |> element("#pb-rule-form-minlength") |> render_change(%{"value" => ""})

      assert is_nil(Node.attr(node_again(view, bound.id), "minlength"))
    end

    test "the success message is written on the form", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      view
      |> element("#pb-rule-form-success")
      |> render_change(%{"value" => "Thanks — we got it."})

      assert Node.attr_text(node_again(view, form.id), "data-success") == "Thanks — we got it."
    end

    # ONE UNDO STEP, ALL FIVE NAMES. Five ops would be five steps, and four of them would leave the
    # form's id, param name, page assign and two event names disagreeing about what this form is.
    test "renaming a form moves all five derived names together", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Sales Enquiry"})

      renamed = node_again(view, form.id)
      assert Node.attr_text(renamed, "id") == "sales_enquiry-form"
      assert Node.attr(renamed, "as") == {:expr, ":sales_enquiry"}
      assert Node.attr(renamed, "for") == {:expr, "assigns[:sales_enquiry_form]"}

      # NOTHING ANSWERS THE OLD NAMES, so the rename tags the form.
      assert Node.attr_text(renamed, "phx-change") =~ ~r/^sales_enquiry-[a-z2-7]{5}-validate$/
      assert Node.attr_text(renamed, "phx-submit") =~ ~r/^sales_enquiry-[a-z2-7]{5}-submit$/

      undo!(view)

      back = node_again(view, form.id)
      assert Node.attr_text(back, "id") == "contact-form"
      assert Node.attr(back, "as") == {:expr, ":contact"}
      assert Node.attr(back, "for") == {:expr, "assigns[:contact_form]"}
      assert Node.attr_text(back, "phx-change") == "contact_validate"
      assert Node.attr_text(back, "phx-submit") == "contact_submit"
    end

    test "a seed another form holds is refused and writes nothing", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: @two_forms)
      {:ok, view, _html} = open_builder(conn, page)
      [_first, second] = tagged(view, ".form")
      inspecting(view, second)

      html = view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Contact"})

      assert html =~ "already called"

      untouched = node_again(view, second.id)
      assert Node.attr(untouched, "as") == {:expr, ":signup"}
      assert Node.attr_text(untouched, "id") == "signup-form"
      assert Node.attr_text(untouched, "phx-submit") == "signup_submit"
    end

    # A PRE-TOKEN FORM'S HANDLER MOVES WITH IT for a code author (spec 0.8): the rename tags the
    # form, and leaving it stores the handler under the tagged name, so the custom code still runs.
    test "a code author's rename of a pre-token form carries its stored handler along", %{
      conn: conn,
      site: site
    } do
      body = "{:noreply, Phoenix.Component.assign(socket, :custom_ran, true)}"
      page = legacy_page!(site, [%{name: "contact_submit", code: body}])
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      refute has_element?(view, "#pb-rule-warning")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enq"})
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})
      render(view)

      submit = Node.attr_text(node_again(view, form.id), "phx-submit")
      assert submit =~ ~r/^enquiry-[a-z2-7]{5}-submit$/
      assert stored_names(page) == [submit]

      module = :"Elixir.RenamedPreTokenPage#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Contact",
          page_module: module,
          template: Serializer.serialize(editor(view).tree),
          events: Enum.map(stored_events(page), &%{name: &1.name, code: &1.code})
        })

      {:ok, ^module, _diagnostics} =
        MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

      assert {:noreply, %{assigns: %{custom_ran: true}}} =
               module.handle_event(submit, %{"enquiry" => %{}}, %Phoenix.LiveView.Socket{
                 assigns: %{__changed__: %{}}
               })
    end

    # THE NAME BOX COMMITS AS IT IS TYPED, and the warning is read off the form as it was before the
    # first commit, so it does not vanish with the old seed.
    test "the warning about code that mentions the form stays after the name box commits", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "save", code: "socket.assigns[:contact_form]"}])
      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, node_with_tag(view, ".form"))

      assert has_element?(view, "#pb-rule-warning")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "c"})

      assert view |> element("#pb-rule-warning") |> render() =~
               "Code someone wrote for this form stops running if you rename it."
    end

    test "a tagged form keeps its token through a rename, and raises no warning", %{
      conn: conn,
      site: site
    } do
      tagged =
        @bound_form
        |> String.replace("contact_validate", "contact-k7m2q-validate")
        |> String.replace("contact_submit", "contact-k7m2q-submit")

      page =
        create_page!(
          site_id: site.id,
          template: tagged,
          events: [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}]
        )

      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      refute has_element?(view, "#pb-rule-warning")

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      renamed = node_again(view, form.id)
      assert Node.attr_text(renamed, "phx-change") == "enquiry-k7m2q-validate"
      assert Node.attr_text(renamed, "phx-submit") == "enquiry-k7m2q-submit"
    end

    test "a rename is announced on builder:form:after_rename", %{conn: conn, site: site} do
      Process.register(self(), FormRenamedProbe.waiter())
      register_plugin(FormRenamedProbe, "builder:form:after_rename")

      page = create_page!(site_id: site.id, template: @bound_form)
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      assert_receive {FormRenamedProbe, summary}
      assert summary.node_id == form.id
      assert summary.from == "contact"
      assert summary.to == "enquiry"
      assert summary.token =~ ~r/^[a-z2-7]{5}$/
      assert summary.submit == "enquiry-#{summary.token}-submit"
      assert summary.change == "enquiry-#{summary.token}-validate"
      assert summary.resource_id == page.id

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      refute_receive {FormRenamedProbe, _unchanged}, 200
    end

    # THE STORED NAME FOLLOWS THE FORM, for whoever may write code (spec 0.8): when they leave a
    # renamed form, and at their next code Save.
    defp tagged_page!(site, events) do
      template =
        @bound_form
        |> String.replace("contact_validate", "contact-k7m2q-validate")
        |> String.replace("contact_submit", "contact-k7m2q-submit")
        |> String.replace(~s(<div id="root">), ~s(<div id="root"><h2>Hi</h2>))

      create_page!(site_id: site.id, template: template, events: events)
    end

    defp legacy_page!(site, events) do
      template = String.replace(@bound_form, ~s(<div id="root">), ~s(<div id="root"><h2>Hi</h2>))

      create_page!(site_id: site.id, template: template, events: events)
    end

    defp stored_events(page) do
      MishkaCmsCore.Runtime.Page
      |> Ash.get!(page.id, authorize?: false, tenant: page.site_id)
      |> Map.fetch!(:events)
    end

    defp stored_names(page), do: page |> stored_events() |> Enum.map(& &1.name)

    defp rename_then_leave(view, name) do
      form = node_with_tag(view, ".form")
      inspecting(view, form)
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => name})
      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})

      # The selection arrives as the session's broadcast; this render is handled after it.
      render(view)
    end

    test "a code author's stored handler takes the form's new event name on leaving it", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)

      rename_then_leave(view, "Enquiry")

      assert stored_names(page) == ["enquiry-k7m2q-submit"]
      assert [%{"name" => "enquiry-k7m2q-submit"}] = fragments(view).events
    end

    test "the stored code is read again first, so an older copy is never written back", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)

      # Another tab saves a handler after this one loaded the page.
      elsewhere = create_admin("elsewhere#{System.unique_integer([:positive])}@example.com")

      MishkaCmsCore.Runtime.Page
      |> Ash.get!(page.id, action: :master_get, actor: elsewhere)
      |> Ash.Changeset.for_update(
        :master_update,
        %{
          events: [
            %{name: "contact-k7m2q-submit", code: "{:noreply, socket}"},
            %{name: "save", code: "{:noreply, socket}"}
          ]
        },
        actor: elsewhere
      )
      |> Ash.update!(actor: elsewhere)

      rename_then_leave(view, "Enquiry")

      assert stored_names(page) == ["enquiry-k7m2q-submit", "save"]
    end

    test "staying on the form writes nothing yet", %{conn: conn, site: site} do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, node_with_tag(view, ".form"))

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      render(view)

      assert Node.attr_text(node_with_tag(view, ".form"), "phx-submit") == "enquiry-k7m2q-submit"
      assert stored_names(page) == ["contact-k7m2q-submit"]
    end

    test "a code Save stores a handler under the form's current event name", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [])
      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, node_with_tag(view, ".form"))
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      render_click(view, "add_code", %{"tab" => "events"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "entry" => %{"0" => %{"name" => "contact-k7m2q-submit", "code" => "{:noreply, socket}"}}
      })

      assert stored_names(page) == ["enquiry-k7m2q-submit"]
    end

    test "a code Save moves a pre-token form's handler to the name its rename tagged", %{
      conn: conn,
      site: site
    } do
      page = legacy_page!(site, [%{name: "contact_submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "entry" => %{"0" => %{"name" => "contact_submit", "code" => "{:noreply, socket}"}}
      })

      submit = Node.attr_text(node_again(view, form.id), "phx-submit")
      assert submit =~ ~r/^enquiry-[a-z2-7]{5}-submit$/
      assert stored_names(page) == [submit]
    end

    # THE CODE WINDOW HOLDS EDITS NOT SAVED YET. A tab switch keeps them, and leaving the form from
    # the Styles index follows them rather than replacing them with the row.
    test "unsaved code in the Code window survives leaving a renamed form", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)

      heading = node_with_tag(view, "h2")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})
      scope = Tree.scope(editor(view).tree, heading.id)

      inspecting(view, node_with_tag(view, ".form"))
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      edited = "{:noreply, Phoenix.Component.assign(socket, :edited, true)}"

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "go" => "styles",
        "entry" => %{"0" => %{"name" => "contact-k7m2q-submit", "code" => edited}}
      })

      view |> element("#pb-style-rule-go-#{scope}") |> render_click()
      render(view)

      assert stored_names(page) == ["enquiry-k7m2q-submit"]
      assert [%{"name" => "enquiry-k7m2q-submit", "code" => ^edited}] = fragments(view).events
    end

    # A READ THAT FAILS WRITES NOTHING: the tab's own copy may be older than the row. A site admin
    # reads through the archive filter, so an archived row is hidden from the editor's re-read, and
    # it is brought back for anything after it.
    #
    # THE RENAME'S OWN WRITES ARE AWAITED FIRST. It starts a draft autosave and a history flush, and
    # both read the page from their own processes; one still running when the row is archived
    # missed it before the editor did, brought it back, and the editor then wrote.
    test "a row that cannot be read again is not written from the tab's older copy", %{
      conn: conn,
      site: site
    } do
      page = tagged_page!(site, [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}])

      tenant =
        create_admin("tenant-left#{System.unique_integer([:positive])}@example.com", site.id)

      {:ok, view, _html} = conn |> log_in(tenant) |> open_builder(page)

      elsewhere = create_admin("elsewhere#{System.unique_integer([:positive])}@example.com")

      MishkaCmsCore.Runtime.Page
      |> Ash.get!(page.id, action: :master_get, actor: elsewhere)
      |> Ash.Changeset.for_update(
        :master_update,
        %{
          events: [
            %{name: "contact-k7m2q-submit", code: "{:noreply, socket}"},
            %{name: "save", code: "{:noreply, socket}"}
          ]
        },
        actor: elsewhere
      )
      |> Ash.update!(actor: elsewhere)

      inspecting(view, node_with_tag(view, ".form"))
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      _written = render_async(view)

      set_archived!(page.id, true)
      handler = "unreadable-page-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:mishka_cms_core, :repo, :query],
        &__MODULE__.restore_after_miss/4,
        %{handler: handler, page_id: page.id, editor: view.pid}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})
      render(view)

      assert :telemetry.list_handlers([:mishka_cms_core, :repo, :query])
             |> Enum.all?(&(&1.id != handler)),
             "the editor read the row again, and missed it"

      assert stored_names(page) == ["contact-k7m2q-submit", "save"]
    end
  end

  defp set_archived!(page_id, archived?) do
    MishkaCmsCore.Repo.query!(
      "UPDATE pages SET archived_at = CASE WHEN $2 THEN now() ELSE NULL END WHERE id = $1",
      [Ecto.UUID.dump!(page_id), archived?]
    )
  end

  # Brings the page back after the editor's own read missed it. A telemetry handler is global and
  # runs in whichever process made the query, so a miss from any other process is left alone.
  def restore_after_miss(
        _event,
        _measurements,
        %{source: "pages", result: {:ok, %{num_rows: 0}}},
        %{editor: editor} = config
      )
      when editor == self() do
    :telemetry.detach(config.handler)
    set_archived!(config.page_id, false)
  end

  def restore_after_miss(_event, _measurements, _metadata, _config), do: :ok

  # Without code permission the stored name stays; the handler still runs, followed by its token.
  describe "leaving a renamed form without code permission" do
    setup do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      :ok
    end

    test "writes no stored handler", %{conn: conn, site: site} do
      template =
        @bound_form
        |> String.replace("contact_validate", "contact-k7m2q-validate")
        |> String.replace("contact_submit", "contact-k7m2q-submit")
        |> String.replace(~s(<div id="root">), ~s(<div id="root"><h2>Hi</h2>))

      page =
        create_page!(
          site_id: site.id,
          template: template,
          events: [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}]
        )

      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      render_click(view, "select", %{"id" => form.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      render_click(view, "select", %{"id" => node_with_tag(view, "h2").id})
      render(view)

      assert Node.attr_text(Tree.get(editor(view).tree, form.id), "phx-submit") ==
               "enquiry-k7m2q-submit"

      reloaded =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert Enum.map(reloaded.events, & &1.name) == ["contact-k7m2q-submit"]

      refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.flash, "error"),
             "leaving the form must not try a code write this deployment refuses"
    end

    # A PRE-TOKEN FORM'S HANDLER CANNOT MOVE without code permission, so every keystroke of the
    # rename keeps the untagged names, the section says what stops, and the old name reattaches it.
    test "a pre-token form a stored handler answers keeps its untagged names", %{
      conn: conn,
      site: site
    } do
      page = legacy_page!(site, [%{name: "contact_submit", code: "{:noreply, socket}"}])
      {:ok, view, _html} = open_builder(conn, page)
      form = node_with_tag(view, ".form")
      inspecting(view, form)

      stops = "contact_submit on the Handlers tab will stop being called."
      assert view |> element("#pb-rule-warning") |> render() =~ stops

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry"})
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Enquiry Form"})

      renamed = node_again(view, form.id)
      assert Node.attr_text(renamed, "phx-submit") == "enquiry_form_submit"
      assert Node.attr_text(renamed, "phx-change") == "enquiry_form_validate"
      assert view |> element("#pb-rule-warning") |> render() =~ stops

      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Contact"})

      assert Node.attr_text(node_again(view, form.id), "phx-submit") == "contact_submit"
    end
  end

  # Two forms, each with its field and Send button in a column of a grid in a card: Phoenix's own
  # `<.form>`, and Chelekom's Form Wrapper wired as a page form.
  @two_deep_forms ~s(<div id="root"><h1>Hi</h1>) <>
                    ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div id="contact-col"><input name={f[:email].name} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>) <>
                    ~s(<.component component_name="chelekom-form-wrapper" site="localhost" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div id="news-col"><input name={w[:email].name} /></div><div class="col"><button type="submit">Join</button></div></div></div></.component></div>)

  @deep_events ~w(contact-k7m2q-validate contact-k7m2q-submit news-p3xa6-validate news-p3xa6-submit)

  defp deep_forms_page!(site, events \\ [], extra \\ []) do
    kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))
    create_page!([site_id: site.id, template: @two_deep_forms, events: events] ++ extra)
  end

  defp messages(count),
    do: Enum.map(1..count, &%{name: ":tick_#{&1}", code: "{:noreply, socket}"})

  defp handlers_tab(view) do
    view |> element("#pb-code") |> render_click()
    render_click(view, "source_tab", %{"tab" => "events"})
  end

  defp customize!(view, event, typed \\ %{}) do
    view
    |> form("#pb-code-form", typed)
    |> put_submitter("#pb-form-customize-#{event}")
    |> render_submit()
  end

  defp open_audit(view), do: view |> element("#pb-rail-audit") |> render_click()

  defp note_fix(view, form),
    do: view |> element("#pb-audit-fix-form-no-destination-#{form.id}") |> render_click()

  defp written(names), do: Enum.map(names, &%{name: &1, code: "{:noreply, socket}"})

  describe "a page's forms on the Handlers tab" do
    test "lists both deep forms, each with its On change and On submit, Automatic", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      handlers_tab(view)

      contact = with_dom_id(view, "contact-form")
      news = with_dom_id(view, "news-form")

      assert has_element?(view, "#pb-form-handlers #pb-form-handlers-#{contact.id}", "Contact")
      assert has_element?(view, "#pb-form-handlers #pb-form-handlers-#{news.id}", "News")

      for event <- @deep_events do
        assert has_element?(view, ~s(#pb-form-handler-#{event}[data-custom="false"]), "Automatic")
        assert has_element?(view, "#pb-form-customize-#{event}")
      end

      assert has_element?(
               view,
               "#pb-code-form p",
               "No custom handlers. The forms above run on their own."
             )
    end

    test "a stored handler marks its own form's event Custom, even under an older name", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["enquiry-p3xa6-submit"]))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      assert has_element?(
               view,
               ~s(#pb-form-handler-news-p3xa6-submit[data-custom="true"]),
               "Custom"
             )

      refute has_element?(view, "#pb-form-customize-news-p3xa6-submit")
      assert has_element?(view, ~s(#pb-form-handler-contact-k7m2q-submit[data-custom="false"]))
      refute has_element?(view, "#pb-code-form p", "No custom handlers")
    end

    test "a page with no form shows no forms and the usual empty note", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      refute has_element?(view, "#pb-form-handlers")
      assert has_element?(view, "#pb-code-form p", "No handlers yet.")
    end

    test "Customize keeps what was typed and adds the default code, focused, storing nothing", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["save"]))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      typed = "{:noreply, Phoenix.Component.assign(socket, :typed, true)}"
      customize!(view, "news-p3xa6-submit", %{"entry" => %{"0" => %{"code" => typed}}})

      assert [
               %{"name" => "save", "code" => ^typed},
               %{"name" => "news-p3xa6-submit", "code" => code}
             ] = fragments(view).events

      assert code ==
               ~s|IO.inspect(params, label: "news-p3xa6-submit")\n| <>
                 ~s|MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), "news-p3xa6-submit", params)|

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")
      refute has_element?(view, "#pb-code-entry-events-0[data-focus]")

      assert has_element?(
               view,
               ~s(#pb-form-handler-news-p3xa6-submit[data-custom="true"]),
               "Custom"
             )

      refute has_element?(view, "#pb-form-customize-news-p3xa6-submit")
      assert has_element?(view, "#pb-form-customize-contact-k7m2q-submit")

      assert stored_names(page) == ["save"]
    end

    test "Customize on change writes the checking default for that form alone", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      handlers_tab(view)

      customize!(view, "contact-k7m2q-validate")

      assert [%{"name" => "contact-k7m2q-validate", "code" => code}] = fragments(view).events

      assert code ==
               LiveViewCompiler.form_handler_sample(:validate, "contact-k7m2q-validate")

      assert code =~
               ~s|{:noreply, MishkaCmsCore.Runtime.PageForm.validate(socket, __page_forms__(), "contact-k7m2q-validate", params)}|

      assert has_element?(view, ~s(#pb-form-handler-news-p3xa6-validate[data-custom="false"]))
    end

    test "a second Customize of the same event adds nothing and focuses the entry", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site, written(["save"])))
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")
      [save, news] = fragments(view).events

      render_click(view, "save_code", %{
        "tab" => "events",
        "customize" => "news-p3xa6-submit",
        "entry" => %{"0" => news, "1" => save}
      })

      assert fragments(view).events == [news, save]
      assert has_element?(view, "#pb-code-entry-events-0[data-focus]")
    end

    test "Customize for an event no form names any more keeps the typing and adds nothing", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["save"]))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      render_click(view, "save_code", %{
        "tab" => "events",
        "customize" => "gone-aaaaa-submit",
        "entry" => %{"0" => %{"name" => "save", "code" => ":kept"}}
      })

      assert fragments(view).events == [%{"name" => "save", "code" => ":kept"}]
      assert [%{name: "save", code: "{:noreply, socket}"}] = stored_events(page)
    end

    test "leaving Handlers by a tab button forgets the focus, so no Messages entry takes it", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["a", "b"]), infos: messages(3))
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      customize!(view, "contact-k7m2q-submit")
      assert has_element?(view, "#pb-code-entry-events-2[data-focus]")

      view
      |> form("#pb-code-form", %{})
      |> put_submitter("#pb-sourcetab-infos")
      |> render_submit()

      assert has_element?(view, "#pb-code-entry-infos-2")
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "removing an entry forgets the focus, so the entry moving into its place does not take it",
         %{conn: conn, site: site} do
      page = deep_forms_page!(site, written(["a", "news-p3xa6-submit", "c"]))
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_source", %{
        "tab" => "events",
        "form" => with_dom_id(view, "news-form").id
      })

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")

      view |> element("#pb-code-remove-events-0") |> render_click()

      assert has_element?(view, "#pb-code-entry-events-1")
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "a refused Save forgets the focus", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site, written(["a"])))
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")
      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")

      view
      |> form("#pb-code-form", %{"entry" => %{"0" => %{"code" => "{:noreply,"}}})
      |> render_submit()

      assert flashes(view) =~ "a:"
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "leaving the window for an element forgets the focus it opened with", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["a", "news-p3xa6-submit"]))
      {:ok, view, _html} = open_builder(conn, page)
      news = with_dom_id(view, "news-form")

      render_click(view, "open_source", %{"tab" => "events", "form" => news.id})
      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")

      render_click(view, "select_from_code", %{"id" => news.id})
      refute has_element?(view, "#pb-source-modal")

      view |> element("#pb-code") |> render_click()

      assert has_element?(view, "#pb-code-entry-events-1")
      refute has_element?(view, "#pb-code-form [data-focus]")
    end

    test "Save stores the customized default, which still does not count as receiving it", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")
      view |> form("#pb-code-form") |> render_submit()

      assert [%{name: "news-p3xa6-submit", code: code}] = stored_events(page)
      assert code == LiveViewCompiler.form_handler_sample(:submit, "news-p3xa6-submit")

      view |> element("#pb-source-close") |> render_click()
      open_audit(view)

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-destination-#{with_dom_id(view, "news-form").id}"
             )
    end

    test "announces builder:form:after_customize", %{conn: conn, site: site} do
      Process.register(self(), FormCustomizedProbe.waiter())
      register_plugin(FormCustomizedProbe, "builder:form:after_customize")

      page = deep_forms_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      handlers_tab(view)

      customize!(view, "news-p3xa6-submit")

      assert_receive {FormCustomizedProbe, summary}
      assert summary.event == "news-p3xa6-submit"
      assert summary.kind == :submit
      assert summary.node_id == with_dom_id(view, "news-form").id
      assert summary.resource_id == page.id
    end
  end

  # The deep forms as a page saved before tags carries them: untagged event names.
  @legacy_deep_forms @two_deep_forms
                     |> String.replace("contact-k7m2q-", "contact_")
                     |> String.replace("news-p3xa6-", "news_")

  # A RENAME MOVES A PRE-TOKEN FORM'S OWN HANDLER AT SAVE. Until then the editor counts it under the
  # name it moves to, so nothing offers the form a second handler that would stop it moving.
  describe "a pre-token form a code author renamed, before the rename is saved" do
    test "its own handler reads Custom, and Customize and the note's Fix focus it", %{
      conn: conn,
      site: site
    } do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      stores =
        &~s|MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), "#{&1}", params, fn values -> {:ok, values} end)|

      page =
        create_page!(
          site_id: site.id,
          template: @legacy_deep_forms,
          events: [
            %{name: "contact_submit", code: stores.("contact_submit")},
            %{name: "news_submit", code: stores.("news_submit")}
          ]
        )

      {:ok, view, _html} = open_builder(conn, page)
      forms = Enum.map(~w(contact-form news-form), &with_dom_id(view, &1))

      for {form, name, index} <- Enum.zip([forms, ~w(Letters Digest), [0, 1]]) do
        inspecting(view, form)
        view |> element("#pb-rule-form-seed") |> render_change(%{"value" => name})

        submit = Node.attr_text(node_again(view, form.id), "phx-submit")
        assert submit =~ ~r/-[a-z2-7]{5}-submit$/
        assert has_element?(view, ~s(#pb-form-card-submit[data-custom="true"]), "Custom")

        view |> element("#pb-form-edit-in-code") |> render_click()

        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")
        refute has_element?(view, "#pb-form-handlers-#{form.id}[data-focus]")
        assert has_element?(view, ~s(#pb-form-handler-#{submit}[data-custom="true"]))
        refute has_element?(view, "#pb-form-customize-#{submit}")

        render_click(view, "save_code", %{
          "tab" => "events",
          "customize" => submit,
          "entry" => view |> fragments() |> Map.fetch!(:events) |> indexed()
        })

        assert length(fragments(view).events) == 2
        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")

        view |> element("#pb-source-close") |> render_click()
        open_audit(view)
        note_fix(view, form)

        assert length(fragments(view).events) == 2
        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")

        view |> form("#pb-code-form") |> render_submit()

        assert stored_names(page) ==
                 Enum.map(forms, &Node.attr_text(node_again(view, &1.id), "phx-submit"))

        assert Enum.find(stored_events(page), &(&1.name == submit)).code == stores.(submit)
        view |> element("#pb-source-close") |> render_click()
      end
    end
  end

  defp indexed(entries),
    do: entries |> Enum.with_index() |> Map.new(fn {entry, i} -> {to_string(i), entry} end)

  # A form the Handlers tab cannot list yet, because it has no name or no source: each Fix of the
  # note finishes one thing, and then the form's On submit opens in code.
  describe "the note's Fix on a form that is not finished" do
    @unfinished ~s(<div id="root"><h1>Hi</h1>) <>
                  ~s(<form id="search-form" phx-submit="search_go"><div class="card"><div class="grid"><div class="col"><input type="search" name="q" /></div><div class="col"><button type="submit">Go</button></div></div></div></form>) <>
                  ~s(<.form :let={f} id="q-form" for={assigns[:q_form]} phx-submit="q_submit"><div class="card"><div class="grid"><div class="col"><input name={f[:q].name} /></div><div class="col"><button type="submit">Ask</button></div></div></div></.form>) <>
                  ~s(<.component component_name="chelekom-form-wrapper" site="localhost" id="join-form"><div class="card"><div class="grid"><div class="col"><input name="email" /></div><div class="col"><button type="submit">Join</button></div></div></div></.component>) <>
                  ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div class="col"><input name={f[:email].name} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>) <>
                  ~s(<form id="find-form" action="/search" method="get"><div class="card"><div class="grid"><div class="col"><input type="search" name="q" /></div><div class="col"><button type="submit">Find</button></div></div></div></form></div>)

    defp unfinished_page!(site) do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))
      create_page!(site_id: site.id, template: @unfinished)
    end

    # Presses the note's Fix on the form with this DOM id until it opens the Code window, and
    # answers how many presses edited the form first.
    defp fix_until_code(view, dom_id) do
      Enum.reduce_while(0..4, nil, fn edits, _none ->
        note_fix(view, with_dom_id(view, dom_id))
        render(view)

        case has_element?(view, "#pb-source-modal") do
          true -> {:halt, edits}
          false -> {:cont, nil}
        end
      end)
    end

    test "gives each form its name, source and submit event, then opens its On submit", %{
      conn: conn,
      site: site
    } do
      page = unfinished_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      for {dom_id, clicks, event} <- [
            {"search-form", 2, "search_go"},
            {"q-form", 1, "q_submit"},
            {"join-form", 3, "join_submit"}
          ] do
        assert fix_until_code(view, dom_id) == clicks

        form = with_dom_id(view, dom_id)
        assert Node.attr_text(form, "phx-submit") == event
        assert has_element?(view, "#pb-form-handlers-#{form.id}")

        index =
          view |> fragments() |> Map.fetch!(:events) |> Enum.find_index(&(&1["name"] == event))

        assert has_element?(view, "#pb-code-entry-events-#{index}[data-focus]")

        view |> element("#pb-source-close") |> render_click()
        open_audit(view)
      end

      assert stored_events(page) == []
    end

    test "a form that posts to its own address raises no note", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, unfinished_page!(site))
      open_audit(view)

      find = with_dom_id(view, "find-form")
      refute has_element?(view, "#pb-audit-fix-form-no-destination-#{find.id}")

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-destination-#{with_dom_id(view, "q-form").id}"
             )
    end

    test "the card of a form with no name offers no Edit in Code, and says why", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, unfinished_page!(site))
      inspecting(view, with_dom_id(view, "q-form"))

      assert has_element?(
               view,
               "#pb-form-handlers-card #pb-form-card-unnamed",
               "Give this form a name above to write code for it."
             )

      refute has_element?(view, "#pb-form-edit-in-code")

      inspecting(view, with_dom_id(view, "contact-form"))

      assert has_element?(view, "#pb-form-edit-in-code")
      refute has_element?(view, "#pb-form-card-unnamed")
    end
  end

  describe "the note that nothing receives a form" do
    test "is counted against nothing: the score and summary match a page whose forms have code",
         %{
           conn: conn,
           site: site
         } do
      {:ok, noted, _html} = open_builder(conn, deep_forms_page!(site))
      open_audit(noted)

      received =
        create_page!(site_id: site.id, template: @two_deep_forms, events: written(@deep_events))

      {:ok, handled, _html} = open_builder(conn, received)
      open_audit(handled)

      assert has_element?(noted, "#pb-audit-badge-forms", "2 notes")
      assert has_element?(handled, "#pb-audit-badge-forms", "healthy")

      for id <- ~w(#pb-audit-score #pb-audit-summary) do
        assert noted |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() ==
                 handled |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      end
    end

    test "its Fix opens each deep form's own On submit, customized once, stored never", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      news = with_dom_id(view, "news-form")
      contact = with_dom_id(view, "contact-form")

      note_fix(view, news)

      assert has_element?(view, "#pb-source-modal #pb-form-handlers")
      assert [%{"name" => "news-p3xa6-submit"}] = fragments(view).events
      assert has_element?(view, "#pb-code-entry-events-0[data-focus]")

      note_fix(view, news)
      assert length(fragments(view).events) == 1

      note_fix(view, contact)

      assert [%{"name" => "news-p3xa6-submit"}, %{"name" => "contact-k7m2q-submit"}] =
               fragments(view).events

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")
      assert stored_events(page) == []
    end
  end

  describe "the Form section's handlers card, for a code author" do
    test "folds away with the Form section", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for dom_id <- ~w(contact-form news-form) do
        inspecting(view, with_dom_id(view, dom_id))
        assert has_element?(view, "#pb-form-handlers-card #pb-form-edit-in-code")

        view |> element("#pb-section-form") |> render_click()

        refute has_element?(view, "#pb-form-handlers-card")
        refute has_element?(view, "#pb-form-edit-in-code")

        view |> element("#pb-section-form") |> render_click()
        assert has_element?(view, "#pb-form-handlers-card")
      end
    end

    test "shows each deep form's two events, and Edit in Code opens its row", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)

      assert has_element?(
               view,
               ~s(#pb-form-handlers-card #pb-form-card-validate[data-custom="false"]),
               "contact-k7m2q-validate"
             )

      assert has_element?(view, ~s(#pb-form-card-submit[data-custom="false"]), "Automatic")
      refute has_element?(view, "#pb-form-card-sending")

      view |> element("#pb-form-edit-in-code") |> render_click()

      assert has_element?(view, "#pb-source-modal #pb-form-handlers-#{contact.id}[data-focus]")
      assert fragments(view).events == []
    end

    test "a form with code shows it Custom, and Edit in Code focuses that entry", %{
      conn: conn,
      site: site
    } do
      page = deep_forms_page!(site, written(["save", "news-p3xa6-submit"]))
      {:ok, view, _html} = open_builder(conn, page)
      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      assert has_element?(view, ~s(#pb-form-card-submit[data-custom="true"]), "Custom")
      assert has_element?(view, ~s(#pb-form-card-validate[data-custom="false"]), "Automatic")

      view |> element("#pb-form-edit-in-code") |> render_click()

      assert has_element?(view, "#pb-code-entry-events-1[data-focus]")
      refute has_element?(view, "#pb-form-handlers-#{news.id}[data-focus]")
    end
  end

  describe "a page's forms for someone without code permission" do
    setup do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      :ok
    end

    test "the handlers card reads two sentences and no event name", %{conn: conn, site: site} do
      {:ok, view, _html} =
        open_builder(conn, deep_forms_page!(site, written(["news-p3xa6-submit"])))

      for {id, sending} <- [
            {"contact-form",
             "When they press Send: nothing stores or sends what visitors type yet."},
            {"news-form", "When they press Send: your own code receives it."}
          ] do
        inspecting(view, with_dom_id(view, id))

        assert has_element?(
                 view,
                 "#pb-form-card-typing",
                 "While a visitor types: the fields are checked."
               )

        assert has_element?(view, "#pb-form-card-sending", sending)
        refute has_element?(view, "#pb-form-edit-in-code")
        refute has_element?(view, "#pb-form-card-submit")

        card = view |> element("#pb-form-handlers-card") |> render()
        refute card =~ ~r/k7m2q|p3xa6|validate|submit/
      end
    end

    test "a form that works as they type says where what they type goes, not when they press Send",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for dom_id <- ~w(contact-form news-form) do
        inspecting(view, with_dom_id(view, dom_id))
        view |> element("#pb-rule-how-typing") |> render_click()

        assert has_element?(
                 view,
                 "#pb-form-card-sending",
                 "What they type: nothing stores or sends what visitors type yet."
               )

        refute has_element?(view, "#pb-form-card-sending", "press Send")

        view |> element("#pb-rule-how-send") |> render_click()
        inspecting(view, with_dom_id(view, dom_id))
        assert has_element?(view, "#pb-form-card-sending", "When they press Send:")
      end
    end

    test "the sentences fold away with the Form section", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for dom_id <- ~w(contact-form news-form) do
        inspecting(view, with_dom_id(view, dom_id))
        assert has_element?(view, "#pb-form-card-sending")

        view |> element("#pb-section-form") |> render_click()
        refute has_element?(view, "#pb-form-card-sending")

        view |> element("#pb-section-form") |> render_click()
        assert has_element?(view, "#pb-form-card-sending")
      end
    end

    test "cannot open the Handlers tab, from the card's route or from the Code window", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")

      render_click(view, "open_source", %{"tab" => "events", "form" => contact.id})

      refute has_element?(view, "#pb-source-modal")
      assert flashes(view) =~ CodeAccess.refusal()
      clear_flashes(view)

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})

      assert flashes(view) =~ CodeAccess.refusal()
      assert has_element?(view, "#pb-source-form")
      refute has_element?(view, "#pb-code-form")
      refute has_element?(view, "#pb-form-handlers")

      render_click(view, "save_code", %{"tab" => "events", "customize" => "contact-k7m2q-submit"})

      assert fragments(view).events == []
    end

    test "a Code window left on a code tab still draws no code", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site, written(["save"])))
      view |> element("#pb-code") |> render_click()

      :sys.replace_state(view.pid, fn state ->
        %{state | socket: Phoenix.Component.assign(state.socket, :source_tab, :events)}
      end)

      render_click(view, "zoom_reset", %{})

      refute has_element?(view, "#pb-code-form")
      refute has_element?(view, "#pb-form-handlers")
    end

    test "the note's Fix reads a plain sentence and opens nothing", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      open_audit(view)

      note_fix(view, with_dom_id(view, "news-form"))

      refute has_element?(view, "#pb-source-modal")
      assert flashes(view) =~ "Ask whoever writes code for this site"
      refute flashes(view) =~ ~r/p3xa6|submit|handler/
      assert fragments(view).events == []
    end
  end

  # THE PAGE AREA WRITES THE PAGE'S CODE: its own type needs no code name of its own.
  describe "a page admin" do
    setup %{site: site} do
      {:ok, pages: narrow_conn(site, ["admin:dashboard:runtime:page"])}
    end

    test "opens the Handlers tab with its form and adds a handler", %{pages: pages, site: site} do
      {:ok, view, _html} = open_builder(pages, deep_forms_page!(site, written(["save"])))

      render_click(view, "open_source", %{"tab" => "events"})
      assert has_element?(view, "#pb-source-modal #pb-code-form")

      render_click(view, "add_code", %{"tab" => "events"})
      assert length(fragments(view).events) == 2
    end

    test "applies a template typed into the Template tab", %{pages: pages, page: page} do
      {:ok, view, _html} = open_builder(pages, page)
      view |> element("#pb-code") |> render_click()
      assert has_element?(view, "#pb-source-form")

      render_click(view, "apply_source", %{"source" => ~s(<div id="typed">typed</div>)})
      assert Serializer.serialize(editor(view).tree) =~ "typed"
    end

    test "corrects a broken template on the recovery screen", %{pages: pages, site: site} do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(pages, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert {:error, {:live_redirect, _to}} =
               view
               |> element("#pb-recover-form")
               |> render_submit(%{"template" => "<div><p>mended</p></div>"})

      assert Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: site.id).template ==
               "<div><p>mended</p></div>"
    end
  end

  # EACH TYPE'S BUILDER OPENS FOR ITS OWN RUNTIME AREA OR `admin:dashboard:code`, asked at mount and
  # again by the canvas, which is addressed by a session token rather than by the document.
  describe "who may open which builder" do
    test "the page area opens the page builder and not the layout builder", %{
      site: site,
      page: page
    } do
      conn = narrow_conn(site, ["admin:dashboard:runtime:page"])

      {:ok, view, _html} = open_builder(conn, page)
      assert has_element?(view, "#pb-root")

      layout = create_layout!(site_id: site.id)

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert to == "/admin/dashboard/runtime/layouts"
      assert flash["error"] =~ "permission to open the layout builder"
    end

    test "the layout area alone does not open the page builder", %{site: site, page: page} do
      conn = narrow_conn(site, ["admin:dashboard:runtime:layout"])

      for path <- [
            "/admin/dashboard/runtime/builder/page/#{page.id}",
            "/admin/dashboard/runtime/builder/page"
          ] do
        assert {:error, {:redirect, %{to: "/admin/dashboard/runtime/pages"}}} = live(conn, path)
      end
    end

    test "code opens every builder", %{site: site, page: page} do
      conn = narrow_conn(site, ["admin:dashboard:code"])

      for path <- [
            "/admin/dashboard/runtime/builder/page/#{page.id}",
            "/admin/dashboard/runtime/builder/layout/#{create_layout!(site_id: site.id).id}",
            "/admin/dashboard/runtime/builder/component/#{create_component!(site_id: site.id).id}",
            "/admin/dashboard/runtime/builder/error-page/#{create_error_page!(site_id: site.id).id}"
          ] do
        assert {:ok, _view, _html} = live(conn, path), path
      end
    end

    test "an error page, addressed error-page, opens for its own area", %{site: site} do
      error_page = create_error_page!(site_id: site.id)
      path = "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"

      assert {:ok, _view, _html} =
               live(narrow_conn(site, ["admin:dashboard:runtime:error_page"]), path)

      assert {:error, {:redirect, %{to: "/admin/dashboard/runtime/error-pages"}}} =
               live(narrow_conn(site, ["admin:dashboard:runtime:page"]), path)
    end

    test "the canvas refuses a session of a builder the reader may not open", %{
      conn: conn,
      site: site,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      path = "/admin/dashboard/runtime/builder-canvas/#{token(view)}"

      {:ok, _canvas, html} = live(narrow_conn(site, ["admin:dashboard:runtime:layout"]), path)

      assert html =~ "You do not have permission to open this builder."

      {:ok, canvas, _html} = live(narrow_conn(site, ["admin:dashboard:runtime:page"]), path)

      refute :sys.get_state(canvas.pid).socket.assigns.missing?
    end

    test "a plugin's rail is drawn for a holder of the name it names and nobody else", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(MishkaCmsCore.Test.Plugins.BuilderGatedRailProbe, "builder:rails")
      key = MishkaCmsCore.Test.Plugins.BuilderGatedRailProbe.key()

      {:ok, view, _html} = open_builder(conn, page)
      assert has_element?(view, "#pb-rail-#{key}")

      narrow = narrow_conn(site, ["admin:dashboard:runtime:page"])
      {:ok, view, _html} = open_builder(narrow, page)

      refute has_element?(view, "#pb-rail-#{key}")
      render_click(view, "set_right_tab", %{"tab" => key})
      refute has_element?(view, "#pb-gated-rail-body")
    end

    test "a plugin's Studio tab is drawn for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(MishkaCmsCore.Test.Plugins.BuilderGatedStudioProbe, "builder:studio:tabs")
      tab = "#pb-studio-" <> MishkaCmsCore.Test.Plugins.BuilderGatedStudioProbe.key()

      view = open_studio(conn, page)
      assert has_element?(view, tab)

      narrow = narrow_conn(site, ["admin:dashboard:runtime:page"])
      view = open_studio(narrow, page)
      assert has_element?(view, "#pb-studio-tokens")
      refute has_element?(view, tab)
    end

    test "a plugin's toolbar action is drawn for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(
        MishkaCmsCore.Test.Plugins.BuilderGatedToolbarProbe,
        "builder:canvas:toolbar"
      )

      button = "#pb-eltb-" <> MishkaCmsCore.Test.Plugins.BuilderGatedToolbarProbe.key()

      for {who, drawn?} <- [
            {conn, true},
            {narrow_conn(site, ["admin:dashboard:runtime:page"]), false}
          ] do
        {:ok, view, _html} = open_builder(who, page)
        render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})

        {:ok, canvas, _html} =
          live(who, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

        assert has_element?(canvas, button) == drawn?
      end
    end

    test "a plugin's command is in the palette for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(MishkaCmsCore.Test.Plugins.BuilderGatedCommandProbe, "builder:commands")
      command = "#pb-cmd-" <> MishkaCmsCore.Test.Plugins.BuilderGatedCommandProbe.key()

      for {who, drawn?} <- [
            {conn, true},
            {narrow_conn(site, ["admin:dashboard:runtime:page"]), false}
          ] do
        {:ok, view, _html} = open_builder(who, page)
        render_click(view, "toggle_command", %{})

        assert has_element?(view, "#pb-cmd-save"), "the palette is open"
        assert has_element?(view, command) == drawn?
      end
    end

    # NOTHING DRAWS A CONTRIBUTED SECTION YET: the Inspector draws its own. What the builder holds
    # for the reader is what it would draw from, so that is what is asked.
    test "a plugin's Inspector section is held for a holder of the name it names alone", %{
      conn: conn,
      site: site,
      page: page
    } do
      register_plugin(
        MishkaCmsCore.Test.Plugins.BuilderGatedSectionProbe,
        "builder:inspector:sections"
      )

      key = MishkaCmsCore.Test.Plugins.BuilderGatedSectionProbe.key()

      for {who, held?} <- [
            {conn, true},
            {narrow_conn(site, ["admin:dashboard:runtime:page"]), false}
          ] do
        {:ok, view, _html} = open_builder(who, page)
        sections = :sys.get_state(view.pid).socket.assigns.inspector_sections

        assert Enum.any?(sections, &(to_string(&1.key) == "element")), "the core's are held"
        assert Enum.any?(sections, &(to_string(&1.key) == key)) == held?
      end
    end
  end

  defp narrow_conn(site, permissions) do
    admin =
      create_admin("n#{System.unique_integer([:positive])}@example.com", site.id, permissions)

    log_in(build_conn_for_host(), admin)
  end

  describe "editing" do
    test "an attribute edit reaches the tree", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "headline"
      })

      edited = view |> editor() |> Map.fetch!(:tree) |> Tree.get(h1.id)
      assert {"class", {:string, "headline"}} in edited.attrs
    end

    test "delete removes the element and undo brings it back", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(view, "h1")

      undo!(view)
      assert node_with_tag(view, "h1")
    end

    test "redo re-applies the undone edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      undo!(view)
      redo!(view)

      refute node_with_tag(view, "h1")
    end

    test "a server-rejected drop leaves the document alone and flashes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      html =
        render_click(view, "op", %{
          "kind" => "insert",
          "template" => ~s(<div>nope</div>),
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "text and inline"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "locking an element refuses edits to it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "toggle_lock", %{"id" => h1.id})
      html = render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      assert html =~ "locked"
      assert node_with_tag(view, "h1")
    end
  end

  # Checked against the v1 prototype served at :8000, option by option.
  describe "the demo's chrome" do
    test "the palette is grouped under category headings with counts", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "grid-box", type: "layout")
      create_component!(site_id: site.id, name: "big-title", type: "text")

      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      assert html =~ "LAYOUT"
      assert html =~ "TEXT"
      assert html =~ "Global — all sites"
      assert html =~ "Tenant only"
    end

    test "the Studio chip counts the team's own tokens", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      studio = view |> element("#pb-studio") |> render()

      # The Mock seeds two custom tokens (brand-teal, screen-xl) — the demo's "+2".
      assert studio =~ "2"
    end

    # The sample findings render through the SAME card as a measured one, so a missing key crashes
    # the rail — which is exactly what happened, and only with the flag on.
    test "the audit rail renders with sample findings switched on", %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_demo_data, true)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_demo_data) end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Low contrast on muted text"
      assert html =~ "Page score"
    end

    # Sample content must never stand in for real content, and must never claim to be a record you
    # can act on. Both are checked here because the flag makes it easy to get wrong.
    # THE RECORD IS NEVER SAMPLED. The other two panels show prototype content when they are empty,
    # because an empty rail cannot be judged; the timeline does not, because a sample row there is
    # indistinguishable from somebody's actual work and the button beside it offers to restore it.
    test "the sample content never reaches the record", %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_demo_data, true)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_demo_data) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "history"})

      html = render_async(view)

      assert html =~ "No changes recorded yet"
      refute html =~ "Header made sticky"
      refute html =~ "history_revert"

      # And a real edit shows up as itself.
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      _flushed = render_async(view)

      assert render_async(view) =~ "Deleted element"
    end

    test "the sample thread yields to a real conversation", %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_demo_data, true)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_demo_data) end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()
      assert render(view) =~ "Make the header sticky and reduce its height a bit"

      view |> form("#pb-ai-form", %{"prompt" => "tighten the spacing"}) |> render_submit()

      html = render(view)
      refute html =~ "Make the header sticky and reduce its height a bit"
      assert html =~ "tighten the spacing"
    end

    # The attach menu sends the SOURCE with the prompt, so each item has to produce something real.
    test "Capture selection attaches the selected element's markup", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      view |> element("#pb-rail-assistant") |> render_click()

      view |> element("#pb-ai-attach-selection") |> render_click()

      assert has_element?(view, "#pb-ai-attachment")
      assert render(view) =~ "&lt;h1&gt; ·"

      view |> form("#pb-ai-form", %{"prompt" => "match this"}) |> render_submit()

      # It travels with the message and the composer is clear again.
      assert render(view) =~ "&lt;h1&gt; ·"
      refute has_element?(view, "#pb-ai-attachment")
    end

    test "Capture template attaches the whole document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      view |> element("#pb-ai-attach-template") |> render_click()

      assert render(view) =~ "whole template ·"
    end

    test "Add file opens the media library rather than a dead upload", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      view |> element("#pb-ai-attach-file") |> render_click()

      assert has_element?(view, "#pb-sheet")
      assert render(view) =~ "Assets"
    end

    # Every overlay had its click-away on the full-screen backdrop, where no click is ever "away".
    test "overlays carry click-away on the panel, not the backdrop", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      backdrop = view |> element("#pb-sheet") |> render()

      refute backdrop =~
               ~s(<div id="pb-sheet" data-role="pb-sheet" class="fixed inset-0 z-[80] flex justify-end bg-[#17161a]/30" phx-click-away)

      assert backdrop =~ "phx-click-away=\"close_sheet\""
    end

    # The stage control is the prototype's split button and it has two distinct looks. Publishing is
    # outward-facing, so this is the one place the published styling is checked.
    test "the stage button is violet-tinted as a draft and solid once published", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      draft = view |> element("#pb-stage") |> render()
      assert draft =~ "bg-[#f2f1fc]"
      assert draft =~ "text-[#4f4bcc]"
      assert draft =~ "Draft"
      # The dot is the autosave light; a caret would mean published.
      assert view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"

      # Selecting only SELECTS — the page is not live until the button is pressed.
      view |> element("#pb-stage-published") |> render_click()
      assert view |> element("#pb-stage") |> render() =~ "Publish"

      view |> element("#pb-stage") |> render_click()

      # AND ONCE IT IS LIVE THE CHIP FALLS BACK TO DRAFT, because publishing is an act rather than a
      # mode: whatever is done next is unpublished work again. The button stays solid — it is still
      # reporting that the page went out — and offers to keep the next work aside.
      published = view |> element("#pb-stage") |> render()
      assert published =~ "linear-gradient(140deg,#6d69e6,#4f4bcc)"
      assert published =~ "text-white"
      assert published =~ "Save draft"
      refute view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"
    end

    # The layers tree is the other way into the document, and it had three holes: a row named every
    # component ".component", a row could not be dropped onto another one, and there was no way to
    # delete a branch from it.
    test "a component row is named after the component, not the wrapper tag", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="chelekom-alert" site="Global"/></div>)
        )

      # The tree opens two levels deep on arrival, so a component one level in is already listed.
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "chelekom-alert"
      refute html =~ ">.component<"
    end

    # A DEFAULT IS NOT ALWAYS A WORD. `chelekom-banner` declares `params` with a default of
    # `%{kind: "banner"}`, and the layers row rendered it with `to_string/1` — which raises
    # `Protocol.UndefinedError` on a map and took the whole builder LiveView down the moment a banner
    # appeared in the tree. Seven of the kit's components declare a map or list default this way.
    test "a component whose attribute defaults to a map still renders its row", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "mappy",
        template: "<div>{@params[:kind]}</div>",
        attrs: [
          %{"name" => "params", "type" => "map", "opts" => %{"default" => %{"kind" => "banner"}}}
        ],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="mappy" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      assert render(view) =~ "mappy"
    end

    # Rendering the layers row was only the FIRST of eight places that stringified a default. Opening
    # the inspector went through `plain_input/1` and raised there instead — same map, same
    # `Protocol.UndefinedError`, and because a raise inside a render kills the LiveView, the author
    # saw the canvas flash and reconnect rather than an inspector.
    #
    # So this selects the node, which is what a click does, and covers every widget the eight call
    # sites belong to: a map and a list default against a text box, a colour, a link, an image and a
    # select.
    test "selecting a component with structured defaults opens the inspector", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "structy",
        template:
          "<div class={@color}><a href={@href}><img src={@src} /></a>{@params[:kind]}{@classes}{@variant}</div>",
        attrs: [
          %{"name" => "params", "type" => "map", "opts" => %{"default" => %{"kind" => "banner"}}},
          %{"name" => "classes", "type" => "list", "opts" => %{"default" => ["a", "b"]}},
          %{"name" => "color", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{"name" => "href", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{"name" => "src", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => %{"x" => 1}, "values" => ["default", "outline"]}
          }
        ],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="structy" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      component = node_with_tag(view, ".component")

      render_click(view, "inspect", %{"id" => component.id})

      # It is still alive, and it is showing the component rather than a reconnect.
      assert render(view) =~ "structy"
    end

    # A component's slots ARE its children in the tree, and each is named by the slot it fills —
    # written the way the markup writes it, `:label`, rather than as the tree's own `__label_slot`.
    test "a component's slots appear in the tree, named", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root"><.component component_name="chelekom-alert" site="Global">\
          <:label>Careful</:label></.component></div>\
          """
        )

      # Two levels are open on arrival, and a component with a slot is a branch — so both the
      # component and the slot under it are already listed.
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "chelekom-alert"
      assert html =~ ":label"
      refute html =~ "__label_slot"
    end

    # A component takes a drop only where the drop can land: it needs a slot to hold it. 120 of the
    # kit's components declare one; a component that declares none renders nothing you drop in, so
    # the tree must not offer it as a target.
    test "only a component with a slot is a drop target", %{conn: conn, site: site} do
      with_slot =
        create_component!(
          site_id: nil,
          name: "demo-card",
          slots: [%{"name" => "inner_block", "opts" => %{"required" => false}}],
          template: "<div class=\"card\">{render_slot(@inner_block)}</div>"
        )

      without = create_component!(site_id: nil, name: "demo-rule", template: "<hr class=\"r\"/>")

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root">\
          <.component component_name="#{with_slot.name}" site="Global"/>\
          <.component component_name="#{without.name}" site="Global"/>\
          </div>\
          """
        )

      {:ok, view, _html} = open_builder(conn, page)

      nodes =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :component))

      [card, rule] = Enum.sort_by(nodes, &Node.component_name/1)

      assert view |> element(~s([data-layer-row="#{card.id}"])) |> render() =~
               ~s(data-container="true")

      refute view |> element(~s([data-layer-row="#{rule.id}"])) |> render() =~
               ~s(data-container="true")
    end

    # `<:inner_block>` is not writable HEEx — the compiler answers "the slot name :inner_block is
    # reserved" — so offering it as a slot to add gave a button whose only possible outcome was that
    # error in a flash. It is the content you put IN the component, and the panel now says so.
    test "the inner block is described rather than offered as a slot to add", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-note",
        slots: [
          %{"name" => "inner_block", "opts" => %{"required" => false}},
          %{"name" => "footer", "opts" => %{"required" => false}}
        ],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-note" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      note =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => note.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # NOT CLICKED OPEN. A component with a slot to add now arrives with the group unfolded — the
      # "End section +" row on a field was the one thing a joined input could not be built without,
      # and folded, nobody found it. Clicking here would close it again.
      assert has_element?(view, "#pb-slot-add-inspector-footer")
      refute has_element?(view, "#pb-slot-add-inspector-inner_block")
      assert has_element?(view, "#pb-slot-inner-block")
      # The layers rail keeps the same rule: a ghost row for `footer`, none for the inner block.
      refute has_element?(view, "#pb-slot-add-#{note.id}-inner_block")

      # And it is still a drop target: the inner block is exactly where a drop lands.
      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => note.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure").parent_id == note.id
    end

    # WHAT CAN GO INSIDE, folded like everything else in the rail. The slot rows used to hang off the
    # component at full volume, and a component that declared NONE got a line reading
    # `__ no slots declared` — the common case, written in the tree's own vocabulary, filed under
    # `.properties`, which is not what it was about. Reported on the editor issue as "it doesn't look
    # good, it's confusing".
    test "a component's slots are a folded group, not loose rows", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-panel",
        slots: [%{"name" => "footer", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-panel" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      panel = component_node(view)
      render_click(view, "toggle_expand", %{"id" => panel.id})

      assert has_element?(view, "#pb-slots-#{panel.id}"), "the rail has no .slots group"

      refute has_element?(view, "#pb-slot-add-#{panel.id}-footer"),
             "the slot rows are open before anybody asked for them"

      view |> element("#pb-slots-#{panel.id}") |> render_click()

      assert has_element?(view, "#pb-slot-add-#{panel.id}-footer")
    end

    # Named the way it is WRITTEN. `<:footer>` is what goes in the markup; `__footer_slot` was the
    # tree's bookkeeping leaking into a label the author has to read.
    test "and a slot is labelled the way it is written in the markup", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-aside",
        slots: [%{"name" => "footer", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-aside" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      aside = component_node(view)
      render_click(view, "toggle_expand", %{"id" => aside.id})
      view |> element("#pb-slots-#{aside.id}") |> render_click()

      row = view |> element("#pb-slot-add-#{aside.id}-footer") |> render()

      assert row =~ ":footer"
      refute row =~ "__footer_slot"
    end

    # THE COMMON CASE SAYS NOTHING UNTIL ASKED. Most components declare no slots at all, and the old
    # line announced that on every one of them.
    test "a component with no slots is silent until the group is opened", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-rule",
        slots: [],
        template: "<hr />"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-rule" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      rule = component_node(view)
      render_click(view, "toggle_expand", %{"id" => rule.id})

      refute render(view) =~ "no slots declared", "the dead line is back"
      refute render(view) =~ "takes nothing inside"

      view |> element("#pb-slots-#{rule.id}") |> render_click()

      assert render(view) =~ "takes nothing inside"
    end

    defp component_node(view) do
      view
      |> editor()
      |> Map.fetch!(:tree)
      |> Tree.walk()
      |> Enum.find(&(&1.kind == :component))
    end

    # A Phoenix slot may be given more than once, and two rows called `__item_slot` tell you nothing
    # about which is which.
    test "repeated slots are numbered in the tree", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-list",
        slots: [%{"name" => "item", "opts" => %{"required" => false}}],
        template: "<ul>{render_slot(@item)}</ul>"
      )

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root"><.component component_name="demo-list" site="Global">\
          <:item>One</:item><:item>Two</:item></.component></div>\
          """
        )

      {:ok, view, _html} = open_builder(conn, page)
      list = component_node(view)

      html = render(view)
      assert html =~ ":item 1"
      assert html =~ ":item 2"

      # And the row to add a third says so rather than claiming the slot is empty. It lives in the
      # component's `.slots` group now, which is folded until it is asked for.
      view |> element("#pb-slots-#{list.id}") |> render_click()
      assert render(view) =~ "add another"
    end

    # The rule that a component needs somewhere to put a child is the SERVER's, not the browser's —
    # the tree only mirrors it, so a tampered payload has to be refused here.
    test "the server refuses a drop into a component with no slot", %{conn: conn, site: site} do
      create_component!(site_id: nil, name: "demo-hr", template: "<hr/>")

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-hr" site="Global"/><p>x</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      tree = editor(view).tree
      target = tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))
      dragged = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      html =
        render_click(view, "drop", %{
          "node_id" => dragged.id,
          "parent_id" => target.id,
          "index" => "0"
        })

      assert html =~ "does not declare a slot"
      # And nothing moved.
      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(dragged.id)
             |> Map.fetch!(:parent_id) ==
               dragged.parent_id
    end

    # A required slot is the same promise as a required property.
    test "a missing required slot blocks the save", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-collapse",
        slots: [%{"name" => "trigger", "opts" => %{"required" => true}}],
        template: "<div>{render_slot(@trigger)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-collapse" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      html = publish!(view)
      assert html =~ "Not saved"
      assert html =~ "demo-collapse.:trigger"
    end

    # A component's markup lives on the COMPONENT, not on the page — so the tree shows it in place
    # rather than sending anyone to another screen, and shows it as a window, not as rows to edit.
    test "a component's own markup is listed inside it, read-only", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: nil,
          name: "demo-footer",
          template: ~s(<footer class="f"><p>Built with MishkaCMS</p></footer>)
        )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="#{component.name}" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "demo-footer"
      # Its insides are there…
      assert html =~ "footer"

      # …but they carry none of the row actions, because editing them would rewrite the component
      # under every other page using it.
      instance =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      refute has_element?(view, "#pb-layer-delete-#{instance.id} ~ *")
    end

    test "a layers row carries what a drop needs and deletes its branch", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      row = view |> element(~s([data-layer-row="#{section.id}"])) |> render()
      assert row =~ ~s(draggable="true")
      assert row =~ ~s(data-parent-id=)
      assert row =~ ~s(data-index=)
      assert row =~ ~s(data-container="true")
      assert row =~ ~s(data-kind="tag")

      # And the delete button takes the branch with it.
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()
      view |> element("#pb-layer-delete-#{section.id}") |> render_click()
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() < before
      refute has_element?(view, ~s([data-layer-row="#{section.id}"]))
    end

    # A COUNT HAS TO MATCH THE ROWS UNDER IT. The panel has always hidden the indentation between two
    # tags, but it counted it — so an indented `<div>` announced seven children over three rows, and a
    # container holding nothing but a newline offered a chevron that opened onto nothing.
    test "a row counts the children it is going to draw", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: "<section>\n  <p>One</p>\n  <p>Two</p>\n</section>\n<div>\n</div>"
        )

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      assert length(section.children) == 5, "three runs of indentation and two paragraphs"

      row = view |> element(~s([data-layer-row="#{section.id}"])) |> render()
      assert row =~ "(2)"
      refute row =~ "(5)"
      assert row =~ ~s(phx-value-id="#{section.id}"), "and it is still expandable"

      empty = node_with_tag(view, "div")
      assert empty.children != [], "the div is holding its newline"

      empty_row = view |> element(~s([data-layer-row="#{empty.id}"])) |> render()
      refute empty_row =~ "(1)", "a container with only indentation in it has nothing to open"
      refute empty_row =~ "toggle_expand"
    end

    # ONE MENU FOR BOTH SURFACES. The canvas is a frame rendering the site's own document with none
    # of the admin stylesheet, so it forwards its right-clicks to the chrome rather than drawing a
    # second, inline-styled copy — which is why there is exactly one of these in the page and why it
    # carries no `phx-click`: the hook stamps the node and pushes the action, so opening costs
    # nothing and no patch can swap the row out mid-gesture.
    test "the right-click menu is rendered once, for both surfaces", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(
               view,
               "#pb-ctx[phx-hook='PbContextMenu'][data-target='[data-layer-row]']"
             )

      assert has_element?(view, "#pb-ctx[hidden]")

      menu = view |> element("#pb-ctx") |> render()
      refute menu =~ "phx-click"

      for action <- Panels.context_actions(), do: assert(menu =~ ~s(data-action="#{action}"))
    end

    test "an entry acts on the node it names, not on the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "ctx", %{"action" => "duplicate", "node_id" => h1.id})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> headings() == 2
    end

    # WITHOUT THIS the menu edits one element while the inspector beside it still describes another,
    # which is how you change the padding of something you are not looking at. `duplicate` is the
    # wrong entry to assert it with — a copy takes the focus, and should.
    test "opening the menu selects what it was opened on", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})

      assert editor(view).selection == h1.id
    end

    test "wrap puts the node inside a fresh container", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "ctx", %{"action" => "wrap", "node_id" => h1.id})

      wrapper = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node_parent(view, h1.id))
      assert wrapper.tag == "div"
      assert h1.id in wrapper.children
    end

    # THE HALF THE MENU ENTRY IS FOR. A link put around the words is only useful if the address can
    # then be typed, and a bare `<a>` draws no field at all — the Attributes list only lists what the
    # node carries.
    test "the link it makes has an address to fill in", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      text = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :text))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "ctx", %{"action" => "link", "node_id" => text.id})

      link = Enum.find(Tree.walk(editor(view).tree), &(&1.tag == "a"))
      assert Node.attr_text(link, "href") == "#"
      assert text.id in link.children

      assert editor(view).selection == link.id, "the link is what the author now edits"

      render_click(view, "toggle_prop_group", %{
        "group" => "section:Attributes",
        "folded" => "true"
      })

      assert has_element?(view, ~s(form[id="pb-attr-row-form-#{link.id}-href"]))
    end

    # The dead end a run of text used to be: a panel saying what it could not do and offering one way
    # out, to the element around it.
    test "a run of text offers the link from the inspector", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      text = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :text))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => text.id})
      assert has_element?(view, "#pb-text-link")

      view |> element("#pb-text-link") |> render_click()

      assert Enum.any?(Tree.walk(editor(view).tree), &(&1.tag == "a"))
    end

    test "an element the words sit in offers no such button", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})

      refute has_element?(view, "#pb-text-link")
    end

    test "styles travel between two elements", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => h1.id,
        "bucket" => "base",
        "prop" => "padding",
        "value" => "8"
      })

      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})
      render_click(view, "ctx", %{"action" => "paste_styles", "node_id" => p.id})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(p.id)
             |> Map.fetch!(:meta)
             |> then(& &1.styles.base) == %{"padding" => "8"}
    end

    # SAVING A SELECTION IS A FORM, and the form already exists. The menu opens it rather than
    # growing a second one beside it.
    test "save as snippet opens the studio on its snippets tab", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "ctx", %{"action" => "snippet", "node_id" => h1.id})

      assert :sys.get_state(view.pid).socket.assigns.sheet == :studio
      assert :sys.get_state(view.pid).socket.assigns.studio_tab == :snippets
    end

    # The action is a word off the wire. Anything the menu does not offer is dropped rather than
    # being handed to the session to interpret.
    test "an action the menu never offers is ignored", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(view, "ctx", %{"action" => "publish_everything", "node_id" => h1.id})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # THE BAR ONLY EXISTS WHILE SOMETHING IS HELD. It sits above the canvas rather than floating over
    # it, because a bar that covers the page hides the thing it is about.
    test "holding a second element opens the bulk bar", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-multi-bar")

      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "p").id})

      assert has_element?(view, "#pb-multi-bar")
      assert render(view) =~ "2 elements held"

      render_click(view, "bulk", %{"action" => "delete"})

      refute has_element?(view, "#pb-multi-bar")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> headings() == 0
    end

    test "clearing lets go without changing the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "clear_marks", %{})

      refute has_element?(view, "#pb-multi-bar")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # OVER THE PAGE'S WORDS, not its markup. A page says "Contact Us" in four places and the fifth is
    # a class called `contact-us`; renaming the company must not touch the CSS.
    test "find and replace sweeps the text and nothing else", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<section class="contact-us"><h1>Contact Us</h1><p>contact us today</p></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_find", %{})
      assert has_element?(view, "#pb-find")

      render_change(view, "find_query", %{"find" => "contact us", "replace" => "Talk to us"})

      # Two places, and the class is not one of them — the search is case-insensitive so the
      # capitalised heading counts.
      assert render(view) =~ "2 matches in 2 places"

      render_click(view, "replace_all", %{})

      heex = view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize()
      assert heex =~ "<h1>Talk to us</h1>"
      assert heex =~ "<p>Talk to us today</p>"
      assert heex =~ ~s(class="contact-us"), "a class is not a word on the page"
    end

    test "a replace-all is one undo", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><p>one</p><p>one</p><p>one</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize()

      render_click(view, "open_find", %{})
      render_change(view, "find_query", %{"find" => "one", "replace" => "two"})
      render_click(view, "replace_all", %{})

      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize() == before
    end

    test "searching for something that is not there says so", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_find", %{})
      render_change(view, "find_query", %{"find" => "zzzz", "replace" => ""})

      assert has_element?(view, "#pb-find-none")
      assert has_element?(view, "#pb-find-replace-all[disabled]")
    end

    # BESIDE TOKENS, because both are things a site defines once and every page then resolves
    # through. A class is only useful if it can reach an element, so Apply appears when something is
    # selected and appends rather than replacing — an element's own utilities are the exceptions to
    # the shared class and have to survive it.
    test "the studio carries a Classes tab that can reach the selection", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})

      assert has_element?(view, "#pb-class-form")
      assert has_element?(view, "#pb-classes-empty")

      render_submit(view, "save_class", %{"name" => "card-shell", "utilities" => "rounded-xl p-6"})

      assert has_element?(view, "#pb-class-card-shell")
      refute has_element?(view, "#pb-classes-empty")

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "apply_class", %{"name" => "card-shell"})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(h1.id)
             |> Tree.Node.attr_text("class") =~ "card-shell"
    end

    # AND A CLASS IS NOT ALWAYS A STRING TO APPEND TO. Apply read the attribute as text and wrote
    # the whole row back as one — so on `class={[@variant, "lead"]}` it put the expression's own
    # source on the element as literal words, which is not Elixir: the page stopped compiling and
    # could not be saved. The class joins the expression instead, and the computed value stays so.
    test "and a class applied over a computed one joins it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})
      render_submit(view, "save_class", %{"name" => "brand-card", "utilities" => "rounded-xl"})

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => ~S|[@variant, "lead"]|,
        "value_kind" => "expr"
      })

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "apply_class", %{"name" => "brand-card"})

      tree = view |> editor() |> Map.fetch!(:tree)

      assert Tree.classes(Tree.get(tree, h1.id)) == ["lead", "brand-card"]
      assert attr_of(view, h1.id, "class") == {:expr, ~S|[@variant, "lead", "brand-card"]|}
      assert CodeCheck.template(Serializer.serialize(tree)) == :ok
    end

    test "a name that is not a CSS class is refused with a message", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})
      render_submit(view, "save_class", %{"name" => "Not A Class", "utilities" => "p-6"})

      assert has_element?(view, "#pb-class-error")
      assert render(view) =~ "lowercase letters, digits and dashes"
      refute has_element?(view, "#pb-class-Not A Class")
    end

    # A TYPO IN THIS BOX USED TO FREEZE THE SITE'S STYLESHEET. `@apply rounde-xl` is a non-zero exit
    # from Tailwind, and every later compile reads the same stored row again — so the row is proved
    # before it is stored, and what comes back is Tailwind's own sentence about it, under the field
    # that still holds what was typed.
    test "a utility Tailwind does not know is refused under the field", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})
      render_submit(view, "save_class", %{"name" => "card", "utilities" => "rounde-xl"})

      assert has_element?(view, "#pb-class-error")
      assert render(view) =~ "rounde-xl"
      refute has_element?(view, "#pb-class-card")
      assert has_element?(view, "#pb-classes-empty")
      assert has_element?(view, ~s|#pb-class-utilities[value="rounde-xl"]|)

      render_submit(view, "save_class", %{"name" => "card", "utilities" => "rounded-xl"})

      assert has_element?(view, "#pb-class-card")
      refute has_element?(view, "#pb-class-error")
    end

    # THE KIT ALREADY SAYS WHERE ITS DOCS ARE. All 136 Chelekom components carry a `doc_url` and
    # nothing read it, so someone stuck on what `variant` means had the answer in the database with
    # no way to reach it.
    test "a component's docs are one click from its properties", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "documented",
        template: ~s|<div class="p-4">hi</div>|,
        extra: %{"doc_url" => "https://mishka.tools/chelekom/docs/alert"}
      )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-documented") |> render_click()
      render_click(canvas, "select", %{})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # SELECTING ON THE CANVAS, not in the panel. A panel selection is navigation and leaves the
      # left tab where the reader put it; a canvas click means "work on this", which is what swings
      # the panel to the Inspector the link lives in.
      render_click(canvas, "select", %{"id" => node.id})

      assert has_element?(
               view,
               ~s(#pb-docs-link[href="https://mishka.tools/chelekom/docs/alert"])
             )

      assert has_element?(view, ~s(#pb-docs-link[target="_blank"][rel="noopener noreferrer"]))
    end

    # A `javascript:` in a link the ADMIN renders is the one way a third-party kit's bundle could
    # reach into this page, so only an http(s) address is offered.
    test "a doc_url that is not a web address is not offered", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "sneaky",
        template: ~s|<div>x</div>|,
        extra: %{"doc_url" => "javascript:alert(1)"}
      )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-sneaky") |> render_click()
      render_click(canvas, "select", %{})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # SELECTING ON THE CANVAS, not in the panel. A panel selection is navigation and leaves the
      # left tab where the reader put it; a canvas click means "work on this", which is what swings
      # the panel to the Inspector the link lives in.
      render_click(canvas, "select", %{"id" => node.id})

      refute has_element?(view, "#pb-docs-link")
    end

    # Clicking a row has to move the ring on the CANVAS, which is a different LiveView. The push that
    # carries it compared the new selection against itself, so it never fired.
    test "selecting in the layers rail reaches the canvas", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      assert_push_event(canvas, "pb:selected", %{id: id})
      assert id == h1.id
    end

    # The prototype uses THREE active treatments and they are not interchangeable: a scope filter is
    # violet-tinted, a category pill is solid dark, a segmented tab is white-on-track. Getting one
    # wrong looks like a typo and reads as a different control, so each is pinned here.
    # OUT OF THE BOX THE STUDIO ANSWERS FROM THIS SERVER. It used to default to the design
    # prototype's sample catalogue, which meant invented packages with prices beside an Install that
    # refuses, and invented presets beside an Apply that only flashes. `Kits` is real: its tokens are
    # the site's own stylesheet declarations and its packages are the kit components on disk this
    # site has not installed.
    test "the marketplace answers from this server unless a host swaps it", %{
      conn: conn,
      page: page
    } do
      assert MishkaCmsCore.Runtime.PageBuilder.Marketplace.adapter() ==
               MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)

      # The sample-catalogue banner is keyed on the adapter, so it goes with it.
      refute has_element?(view, "#pb-sample-catalogue")

      render_click(view, "studio_tab", %{"tab" => "presets"})
      assert has_element?(view, "#pb-presets-empty")
      refute render(view) =~ "SaaS Landing", "the prototype's invented presets must not ship"
    end

    test "active chips use the prototype's own three treatments", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-studio") |> render_click()
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-presets") |> render_click()
      _presets = render_async(view, 5_000)

      # Scope filter — violet tint.
      scope = view |> element("#pb-studio-scope-all") |> render()
      assert scope =~ "bg-[#f2f1fc]"
      assert scope =~ "text-[#4f4bcc]"

      # Category pill — solid dark.
      category = view |> element("#pb-preset-cat-all") |> render()
      assert category =~ "bg-[#17161a]"
      assert category =~ "text-white"

      # Segmented tab — white on its track.
      tab = view |> element("#pb-studio-presets") |> render()
      assert tab =~ "bg-white"
      assert tab =~ "text-[#1b1a18]"
    end

    # Reloading the frame is how you pick up a component recompiled in another tab. It must not reload
    # the EDITOR, and it must ask first when there is work that is not in a draft yet.
    test "reloading the canvas is silent with nothing unsaved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-reload") |> render_click()

      refute has_element?(view, "#pb-reload-modal")
    end

    test "reloading with unsaved work asks first", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      # In DRAFT mode the change is written as it is made, so a reload has nothing to lose.
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      _written = render_async(view)
      view |> element("#pb-reload") |> render_click()
      refute has_element?(view, "#pb-reload-modal")

      # Publish mode writes nothing, which is exactly when the question is worth asking.
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "op", %{
        "kind" => "delete",
        "node_id" => node_with_tag(view, "p").id
      })

      view |> element("#pb-reload") |> render_click()
      assert has_element?(view, "#pb-reload-modal")

      view |> element("#pb-reload-cancel") |> render_click()
      refute has_element?(view, "#pb-reload-modal")

      # And the confirm goes through, leaving the document exactly as it was.
      view |> element("#pb-reload") |> render_click()
      view |> element("#pb-reload-confirm") |> render_click()

      refute has_element?(view, "#pb-reload-modal")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.all?(&(&1.tag != "h1"))
    end

    # PRESSING SAVE IS NOT THE AUTOMATIC WRITE. The automatic one stays out of publish mode; asking
    # for the work to be kept is honoured wherever the stage happens to be pointing.
    test "Save keeps a draft even in publish mode", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "op", %{
        "kind" => "delete",
        "node_id" => node_with_tag(view, "h1").id
      })

      assert view |> editor() |> Map.fetch!(:dirty?), "publish mode writes nothing on its own"

      save!(view)
      _written = render_async(view)

      refute view |> editor() |> Map.fetch!(:dirty?)
      assert is_binary(editor(view).draft_id)
    end

    test "Save draft first saves, then reloads", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      # The modal only appears when there IS unsaved work, which is publish mode.
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      view |> element("#pb-reload") |> render_click()
      view |> element("#pb-reload-save") |> render_click()
      _written = render_async(view)

      refute has_element?(view, "#pb-reload-modal")
      refute view |> editor() |> Map.fetch!(:dirty?)
    end

    # LEAVING IS THE OTHER WAY TO LOSE PUBLISH-MODE WORK, and the only one that cannot be asked
    # about twice — a closed tab is final. The chrome carries a flag the browser reads to decide
    # whether to object at all; the server decides again when the click arrives, because the
    # attribute is one patch behind a change made in the same breath.
    test "the leave guard is armed only by unsaved work in publish mode", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s(#pb-leave-guard[data-armed="false"]))

      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      _written = render_async(view)

      assert has_element?(view, ~s(#pb-leave-guard[data-armed="false"])),
             "draft mode writes as you work, so there is nothing to lose by leaving"

      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})

      assert has_element?(view, ~s(#pb-leave-guard[data-armed="true"]))
    end

    test "leaving with nothing at stake just goes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})

      # Nothing to ask about, so the editor is already gone rather than holding a modal.
      assert_redirect(view, "/admin/dashboard/runtime/pages")
    end

    test "leaving publish mode with changes asks, and Stay keeps you here", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      assert has_element?(view, "#pb-leave-modal")

      view |> element("#pb-leave-stay") |> render_click()

      refute has_element?(view, "#pb-leave-modal")
      assert view |> editor() |> Map.fetch!(:dirty?), "staying keeps the work in the session"
      assert Drafts.list("page", page, actor(view)) == [], "and writes nothing behind your back"
    end

    test "Leave anyway goes without writing anything", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-go") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")
      assert Drafts.list("page", page, recorded) == []
    end

    # CHOOSING PUBLISH IS NOT PUBLISHING, and the difference is invisible until something is typed —
    # from that moment the editor silently stops keeping work. It says so once, when the choice is
    # made, rather than leaving the author to discover it by losing something.
    test "choosing a stage says what it just changed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      # Publish mode saves nothing to the page, but it is no longer true that nothing is kept: the
      # change still reaches the record of who did what, which is the whole point of having one.
      published = render_click(view, "set_stage", %{"stage" => "published"})
      assert published =~ "recorded but not saved to the page"
      assert published =~ "when you press Publish"

      drafted = render_click(view, "set_stage", %{"stage" => "draft"})
      assert drafted =~ "every change is kept as you make it"
    end

    # AND CHOOSING IT LEAVES THE DRAFT ALONE. Publish mode stops writing; it does not undo what was
    # written before the author switched.
    test "choosing publish mode keeps the draft already written", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)
      recorded = actor(view)

      render_click(view, "set_stage", %{"stage" => "published"})

      assert Enum.any?(Drafts.list("page", page, recorded), &(&1.id == draft_id)),
             "switching mode is not a discard"
    end

    test "the leave question offers both ways to keep the work", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})

      assert has_element?(view, "#pb-leave-save")
      assert has_element?(view, "#pb-leave-publish")
      assert has_element?(view, "#pb-leave-stay")
      assert has_element?(view, "#pb-leave-go")
    end

    test "Publish it now puts the page live and then goes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-publish") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")

      live_now =
        MishkaCmsCore.Runtime.Page
        |> Ash.get!(page.id, action: :master_get, authorize?: false)

      refute live_now.template =~ "<h1", "the change is on the live page, not in a drawer"
    end

    test "Keep as a draft writes it before going", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-save") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")

      # AND IT IS THE WORK, not an empty row: the h1 that was deleted is gone from what was kept.
      [kept] = Drafts.list("page", page, recorded)
      assert String.starts_with?(kept.label, "Draft · ")
      refute kept.template =~ "<h1"
    end

    # AND IT IS AN ORDINARY DRAFT WRITE, which means an extension gets the same say over it as over
    # every other one. This handler called `Drafts` itself, so the gate never ran for it: a plugin
    # that refuses draft writes was overruled by the one button that writes on the way out, and the
    # author was sent away believing the work was kept.
    test "and a plugin that refuses the write keeps you here with the work", %{
      conn: conn,
      page: page
    } do
      refuse_draft_writes()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      refused = view |> element("#pb-leave-save") |> render_click()

      assert Drafts.list("page", page, recorded) == [], "the gate refused, so nothing was written"
      assert refused =~ "still here with your changes"
      assert view |> editor() |> Map.fetch!(:dirty?), "the work is still the session's to lose"
    end

    # AND THE WRITE IS ANNOUNCED LIKE EVERY OTHER. `builder:draft:after_save` is what a backup or a
    # sync integration hears a draft through; the one made on the way out was never announced, so
    # the drafts nothing downstream knew about were exactly the ones written to rescue work.
    test "and the draft it wrote is announced to the extensions", %{conn: conn, page: page} do
      watch_draft_announcements()

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})
      render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
      recorded = actor(view)

      render_click(view, "leaving", %{"to" => "/admin/dashboard/runtime/pages"})
      view |> element("#pb-leave-save") |> render_click()

      assert_redirect(view, "/admin/dashboard/runtime/pages")
      [kept] = Drafts.list("page", page, recorded)

      assert_receive {MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe, announced}, 2_000
      assert announced.section == "page"

      assert announced.draft_id == kept.id,
             "the announcement named a row other than the one written"
    end

    # The destination arrives from the browser, so it is checked rather than trusted. A
    # protocol-relative URL is another origin wearing a path's clothes.
    test "a destination that is not a path of this app is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "leaving", %{"to" => "//evil.example.com/admin"})
      render_click(view, "leaving", %{"to" => "https://evil.example.com/admin"})

      refute has_element?(view, "#pb-leave-modal")
      assert render(view) =~ "pb-root"
    end

    # The theme is client state — `<html data-theme>` plus localStorage — so the button carries a hook
    # and BOTH icons, with CSS choosing. A server-rendered icon lagged the real theme and the toggle
    # only ever turned dark on.
    test "the theme toggle owns both icons and flips on the client", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = view |> element("#pb-theme") |> render()
      assert html =~ ~s(phx-hook="PbTheme")
      assert html =~ "[[data-theme=dark]_&amp;]:hidden"
      assert html =~ "[[data-theme=dark]_&amp;]:block"
    end

    test "the crumb bar reports the device and zoom", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert has_element?(view, "[data-role='pb-viewnote']", "Desktop · 100%")

      view |> element("#pb-device-tablet") |> render_click()
      assert has_element?(view, "[data-role='pb-viewnote']", "Tablet · 834px · 100%")
    end

    test "the code editor shows a collapsed strip until it is opened", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-code-strip")
      view |> element("#pb-code-strip") |> render_click()

      refute has_element?(view, "#pb-code-strip")
      assert has_element?(view, "#pb-codetab-html")
    end

    test "the canvas floats a per-element toolbar over the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-el-toolbar"
      assert html =~ "pb-eltb-duplicate"
      assert html =~ "pb-eltb-delete"
      assert html =~ "pb-eltb-ask_ai"
      assert html =~ "pb-eltb-comment"

      # No NODE carries the attribute: the ring is a CSS rule keyed on `data-selected`, and the hook
      # sets it on the click so a selection paints without re-rendering the document.
      assert html =~ ~s([data-node-id][data-selected="true"])
      refute html =~ ~s(data-node-id="#{h1.id}" data-selected="true")

      # And the actions work, through the same validated op funnel as everything else.
      render_click(canvas, "toolbar", %{"action" => "duplicate"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.count(&(&1.tag == "h1")) ==
               2

      render_click(canvas, "toolbar", %{"action" => "delete"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.count(&(&1.tag == "h1")) ==
               1
    end

    # THE TOOLBAR IS AN OPEN REGISTRY AND "NOT DELETE" MEANT "DUPLICATE", so every button an
    # extension contributed inserted a copy of the selected element — undoable, autosaved — and the
    # plugin that put it there was never called. Both halves are asserted here: the plugin hears
    # about the press, and the document does not move.
    test "a contributed toolbar action reaches its plugin instead of duplicating the element", %{
      conn: conn,
      page: page
    } do
      Process.register(self(), ToolbarInvokedProbe.waiter())
      register_plugin(ToolbarProbe, "builder:canvas:toolbar")
      register_plugin(ToolbarInvokedProbe, "builder:canvas:toolbar:invoked")

      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      before = editor(view)

      assert has_element?(canvas, "#pb-eltb-probe-toolbar")

      # THE BUTTON READS AS WHAT THE PLUGIN DECLARED, which is the other half of a contributed action
      # being real: the label and the icon were drawn from the core's own five and a plugin's button
      # came out an unlabelled box, whatever its descriptor said.
      button = canvas |> element("#pb-eltb-probe-toolbar") |> render()

      assert button |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() == "Probe",
             "the descriptor's own label is what the button says, not just its tooltip"

      assert button =~ ~s(data-pb-tb="labelled"), "so it is not squeezed into a 30px glyph box"

      assert button =~ ~s(d="M13 2 4 14h7l-1 8 9-12h-7z"),
             "and the sparkle it named, not the box every key outside the core's five fell back to"

      canvas |> element("#pb-eltb-probe-toolbar") |> render_click()

      assert_receive {ToolbarInvokedProbe,
                      %{action: "probe-toolbar", node_id: node_id, token: token}}

      assert node_id == h1.id
      assert token == token(view)

      assert editor(view).tree == before.tree, "a plugin's button is not a document change"
      assert editor(view).past == before.past, "and it is not an undo step either"
    end

    # A KEY THE REGISTRY NEVER OFFERED can only come from a forged or replayed press — the buttons
    # are drawn from that same list. It used to duplicate the element, which is the loudest possible
    # answer to "I don't know what this is"; the quietest correct one is nothing at all, said in the
    # log. Taking the canvas down instead is the iframe reload loop the catch-all clause avoids.
    test "a toolbar action nothing registered changes nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      before = editor(view)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          render_click(canvas, "toolbar", %{"action" => "not-a-registered"})
        end)

      assert log =~ ~s(no toolbar action is registered as "not-a-registered")
      assert has_element?(canvas, "#pb-el-toolbar"), "and the canvas is still up to draw the bar"
      assert editor(view).tree == before.tree
      assert editor(view).past == before.past
    end

    # `layout` IS one of the registry's five, and the only one the core answers by doing nothing —
    # the panel is client state, so the button pushes no event at all. Left to the clause that hands
    # a key back to the plugin that contributed it, a replayed press would be announced to every
    # plugin as an extension's own action.
    test "a core toolbar key is never announced as a plugin's", %{conn: conn, page: page} do
      Process.register(self(), ToolbarInvokedProbe.waiter())
      register_plugin(ToolbarInvokedProbe, "builder:canvas:toolbar:invoked")

      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      render_click(canvas, "toolbar", %{"action" => "layout"})

      refute_receive {ToolbarInvokedProbe, _summary}
    end

    # THE CHROME COLLECTED THIS REGISTRY TOO, into an assign nothing rendered and from a seed that
    # disagreed with the one on screen — so a plugin ran twice per open and saw two different core
    # sets. The bar is drawn inside the frame, and the frame is now the only thing that asks for it.
    test "only the canvas collects the toolbar registry", %{conn: conn, page: page} do
      Process.register(self(), ToolbarProbe.waiter())
      register_plugin(ToolbarProbe, "builder:canvas:toolbar")

      {:ok, view, _html} = open_builder(conn, page)
      refute_received {ToolbarProbe, :collected}

      {:ok, _canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert_received {ToolbarProbe, :collected}
    end

    # THE BAR NEEDS ROOM ABOVE WHAT IT NAMES. It sits 6px above the selection and never closer than
    # 4px to the top of the frame, so on a 16px stage it was pinned over the top of the document's
    # first element — over the chip or the words a double click was aimed at, in every builder. The
    # layout is what is checkable here; where the hook puts the bar is `placeToolbar`'s.
    test "the stage keeps the toolbar's band clear above the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      chrome = canvas |> element("#pb-canvas-chrome") |> render()

      assert chrome =~
               ~s|#pb-canvas-root[data-preview="false"] { padding-top: calc(4px + 26px + 6px); }|

      assert chrome =~ "html { scroll-padding-top: calc(4px + 26px + 6px); }",
             "a selection scrolled into view has to stop short of the bar the same way"

      view |> element("#pb-preview") |> render_click()

      refute render(canvas) =~ "calc(4px + 26px + 6px)",
             "preview draws no bar, so it keeps no band"
    end

    test "Ask AI and Comment open their rails in the chrome", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_rail", %{"action" => "ask_ai"})
      assert render(view) =~ "Describe a change"

      render_click(view, "open_rail", %{"action" => "comment"})
      assert render(view) =~ "Commenting on"
    end

    # The canvas frame shows the author's own document and nothing else. An empty page still offers
    # somewhere to click, but a page with content does not get a dashed strip appended below it.
    test "the canvas frame adds no chrome below the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "pb-canvas-tail"
      refute html =~ "Drop a component here"
    end
  end

  describe "publishing" do
    test "publish writes the page and reports the published stage", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "live-now"
      })

      # Two steps on purpose: the menu selects the stage, the button carries it out.
      view |> element("#pb-stage-published") |> render_click()
      html = view |> element("#pb-stage") |> render_click()

      assert html =~ "published"

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="live-now")
      refute editor(view).dirty?
    end

    test "the stage button publishes again after an edit, and has nothing to do without one", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      set_class =
        &render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => h1.id,
          "name" => "class",
          "value" => &1
        })

      set_class.("first-publish")
      view |> element("#pb-stage-published") |> render_click()
      view |> element("#pb-stage") |> render_click()

      view |> element("#pb-stage-published") |> render_click()
      assert view |> element("#pb-stage") |> render() =~ "Published"
      refute view |> element("#pb-stage") |> render() =~ ~s(phx-click="apply_stage")

      set_class.("second-publish")
      view |> element("#pb-stage-published") |> render_click()
      chip = view |> element("#pb-stage") |> render()
      refute chip =~ "Published"
      assert chip =~ "Publish"
      assert chip =~ ~s(phx-click="apply_stage")

      view |> element("#pb-stage") |> render_click()

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="second-publish")
    end

    test "an edit after a publish is draft work again, autosaved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      publish!(view)

      assert view |> element("#pb-stage") |> render() =~ "Save draft"

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "after-publish"
      })

      chip = view |> element("#pb-stage") |> render()
      assert chip =~ "Draft"
      refute chip =~ "Save draft"
      assert view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"
    end

    # THE ORDINARY PUBLISH IS A PUBLISH FROM A DRAFT — autosave mints one before the author ever
    # reaches the button — and its cleanup used to collect nothing at all: the spent draft is
    # discarded first, which moves its rows onto the live branch before the collect asks for them.
    # Every payload stayed, and the released rows read on the page's own timeline still offering a
    # Restore, under the summary row saying they are no longer restorable.
    test "and a publish from a draft drops the payloads behind it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert autosave!(view), "no draft was minted; this would prove nothing"
      assert snapshots() != [], "nothing was recorded; this would prove nothing"

      publish!(view)
      _collected = render_async(view)

      assert snapshots() == []
      assert Enum.all?(history_rows(page), &is_nil(&1.snapshot_id))
      assert Enum.any?(history_rows(page), &(&1.op == :publish))
    end
  end

  # The style write path: without these controls the breakpoint tabs and State chips would choose a
  # bucket that nothing ever writes to, which is what the audit found.
  describe "responsive style overrides" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # Layout and Appearance are open on selection — spacing and colour are what people reach for
      # first. The rest still need opening the way a reader would. "Editing at" is not among them any
      # more: the breakpoint is a permanent tab strip now, not a fold.
      for title <- ~w(state behavior attributes) do
        view |> element("#pb-section-#{title}") |> render_click()
      end

      %{view: view, node: section}
    end

    # THE BOX MODEL, AS A CONTROL. Eight edges, each where it is on the element. Before this the panel
    # offered `Padding Y`, `Padding X`, `Padding top` and `Padding bottom` — four of the eight edges
    # missing outright, including `margin-top`, which is the third most-used utility in the whole
    # block library.
    test "the spacing box draws all eight edges", %{view: view} do
      for edge <- ~w(mt mr mb ml pt pr pb pl) do
        assert has_element?(view, "#pb-edge-base-#{edge}"),
               "the spacing box has no cell for #{edge}"
      end
    end

    test "and typing in one writes that edge and nothing else", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px"}}

      view |> element("#pb-edge-form-base-pl") |> render_change(%{"value" => "2rem"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px", "pl" => "2rem"}}
    end

    # THE BOX HAD NO WAY OUT BUT THE KEYBOARD, and that fails in the one way a control must not: you
    # empty the field, the change does not reach the server, and the next render puts the old value
    # back — so it reads as a box that remembers what you deleted. Every other control here has a
    # Reset; this is the box's.
    test "a set edge can be cleared without retyping", %{view: view, node: node} do
      refute has_element?(view, "#pb-edge-clear-base-mt")

      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})

      assert has_element?(view, "#pb-edge-clear-base-mt")

      view |> element("#pb-edge-clear-base-mt") |> render_click()

      assert styles_of(view, node.id) == %{}
      refute has_element?(view, "#pb-edge-clear-base-mt")
    end

    test "and clearing one edge leaves the others alone", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-edge-form-base-pl") |> render_change(%{"value" => "2rem"})

      view |> element("#pb-edge-clear-base-mt") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"pl" => "2rem"}}
    end

    # Emptying the text is still a clear, for anyone who reaches for the keyboard first.
    test "and emptying the field clears it too", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => ""})

      assert styles_of(view, node.id) == %{}
    end

    test "and it reaches the published page", %{view: view, page: page} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "mt-[40px]"
    end

    # An edge is per-breakpoint like every other override, which is the whole point of putting it in
    # the panel rather than in the CSS box: `mt-10` on desktop and `mt-4` on mobile is one element.
    test "an edge belongs to the breakpoint it was set on", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-edge-form-mobile-mt") |> render_change(%{"value" => "12px"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px"}, mobile: %{"mt" => "12px"}}
    end

    # A VALUE THE AUTHOR SET IS NOT AN EXAMPLE. An empty field's placeholder is a made-up hint —
    # "any length, e.g. 2rem" — and a field inheriting from another bucket put the REAL value in the
    # same grey, so an author on Mobile read their own `1000px` as a suggestion and reported the
    # value as missing on reopen.
    test "an inherited value is marked as a value, not as a hint", %{view: view, node: node} do
      view |> element("#pb-style-form-base-width") |> render_change(%{"value" => "1000px"})

      # On base it is the author's own value, in the field itself.
      assert view
             |> element("#pb-style-base-width")
             |> render() =~ ~s(value="1000px")

      view |> element("#pb-bp-mobile") |> render_click()

      mobile = view |> element("#pb-style-mobile-width") |> render()

      assert mobile =~ ~s(placeholder="1000px"), "the inherited value is not offered at all"

      assert mobile =~ ~s(data-inherited="true"),
             "an inherited value is drawn the same as an invented example"

      refute mobile =~ ~s(value="1000px"), "it is not this bucket's own value"

      # And an untouched field still says what a value may look like, without claiming to have one.
      height = view |> element("#pb-style-mobile-height") |> render()
      assert height =~ "any length"
      refute height =~ ~s(data-inherited="true")

      assert styles_of(view, node.id) == %{base: %{"width" => "1000px"}}
    end

    test "the Typography group renders its own controls", %{view: view} do
      html = render(view)

      assert html =~ "Typography"
      assert has_element?(view, "#pb-style-form-base-font-size")
      assert has_element?(view, "#pb-style-form-base-line-height")
      assert has_element?(view, "#pb-style-form-base-letter-spacing")
      assert has_element?(view, "#pb-style-base-font-weight-font-bold")
      assert has_element?(view, "#pb-style-base-text-align-text-center")
      assert has_element?(view, "#pb-style-base-text-transform-uppercase")
    end

    # THE SIZE IS NOT A COLOUR, though Tailwind spells both `text-`. The panel writes the CSS
    # property itself for exactly this reason, and the two have to survive together.
    test "a size and a colour do not overwrite each other", %{view: view, node: node, page: page} do
      view |> element("#pb-style-form-base-font-size") |> render_change(%{"value" => "3rem"})
      view |> element("#pb-style-form-base-color") |> render_change(%{"value" => "#ff0000"})

      assert styles_of(view, node.id) == %{base: %{"font-size" => "3rem", "color" => "#ff0000"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "[font-size:3rem]"
      assert reloaded.template =~ "text-[#ff0000]"
    end

    # A PILL IS NOT A SELECT OF CLASS NAMES. `font-extrabold` and `normal-case` are Tailwind's
    # spelling, not anybody's idea of a choice, so each option carries its own words and is drawn in
    # the thing it names.
    test "an enumerated typographic value offers words, not Tailwind", %{view: view} do
      html = view |> element("#pb-style-base-font-weight-font-extrabold") |> render()

      assert html =~ "Black"
      refute html =~ ">font-extrabold<"

      assert view |> element("#pb-style-base-text-transform-normal-case") |> render() =~
               "As typed"
    end

    test "clicking a weight sets it, and clicking it again clears it", %{view: view, node: node} do
      view |> element("#pb-style-base-font-weight-font-bold") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"font-weight" => "font-bold"}}

      view |> element("#pb-style-base-font-weight-font-bold") |> render_click()

      # The whole bucket goes with the last override in it: an empty `:base` left behind would read
      # as an element that has been styled and reset rather than one nobody touched.
      assert styles_of(view, node.id) == %{}
    end

    test "and so does an alignment and a case", %{view: view, node: node} do
      view |> element("#pb-style-base-text-align-text-center") |> render_click()
      view |> element("#pb-style-base-text-transform-uppercase") |> render_click()

      assert styles_of(view, node.id) ==
               %{base: %{"text-align" => "text-center", "text-transform" => "uppercase"}}
    end

    # A BORDER COLOUR ON ITS OWN PAINTS NOTHING, which is how the panel read before: the control took
    # the colour, the element had no border, and nothing happened.
    test "a border has a width and a style beside its colour", %{view: view, node: node} do
      assert has_element?(view, "#pb-style-form-base-border-width")
      assert has_element?(view, "#pb-style-base-border-style-border-dashed")

      view |> element("#pb-style-form-base-border-width") |> render_change(%{"value" => "2px"})
      view |> element("#pb-style-base-border-style-border-dashed") |> render_click()

      assert styles_of(view, node.id) ==
               %{base: %{"border-width" => "2px", "border-style" => "border-dashed"}}
    end

    test "the column count appears on a grid and not on anything else", %{view: view} do
      refute has_element?(view, "#pb-style-cols-base-3")

      view |> element("#pb-style-pic-base-display-grid") |> render_click()

      assert has_element?(view, "#pb-style-cols-base-3")

      view |> element("#pb-style-pic-base-display-flex") |> render_click()

      refute has_element?(view, "#pb-style-cols-base-3")
    end

    test "and picking one writes Tailwind's own utility", %{view: view, node: node, page: page} do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      view |> element("#pb-style-cols-base-2") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"display" => "grid", "grid-cols" => "2"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      # `grid-cols-[2]` would be `grid-template-columns: 2`, which is not a track list and lays out
      # nothing at all.
      assert reloaded.template =~ "grid-cols-2"
      refute reloaded.template =~ "grid-cols-[2]"
    end

    test "and a track list a count cannot express still goes in", %{view: view, node: node} do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      view |> element("#pb-style-form-base-grid-cols") |> render_change(%{"value" => "2fr 1fr"})

      assert styles_of(view, node.id) == %{base: %{"display" => "grid", "grid-cols" => "2fr 1fr"}}
    end

    # SIX CONTROLS, ONE PROPERTY. `box-shadow` is one string, and offering it as one text box only
    # helps somebody who already knew the answer. Which side it falls on is two numbers.
    test "the shadow editor offers the parts a shadow is made of", %{view: view} do
      for field <- ~w(x y blur spread color) do
        assert has_element?(view, "#pb-shadow-base-#{field}"), "no shadow #{field} control"
      end

      assert has_element?(view, "#pb-shadow-base-inset")
      assert has_element?(view, "#pb-shadow-preset-m")
    end

    test "a preset writes the whole shadow", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-l") |> render_click()

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert shadow =~ "24px"
    end

    # One part at a time, and the other five have to survive it — six ops would be six undo steps for
    # one decision, five of them shadows nobody chose.
    test "and changing one part leaves the others alone", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-l") |> render_click()
      %{base: %{"shadow" => before}} = styles_of(view, node.id)

      view |> element("#pb-shadow-form-base-y") |> render_change(%{"value" => "30px"})

      assert %{base: %{"shadow" => after_edit}} = styles_of(view, node.id)
      assert after_edit =~ "30px"
      assert after_edit =~ "rgba"
      refute after_edit == before
    end

    test "an element with no shadow starts from one worth seeing", %{view: view, node: node} do
      view |> element("#pb-shadow-form-base-y") |> render_change(%{"value" => "8px"})

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert shadow =~ "8px"
      # Not `8px 0 0 0 transparent`: a shadow with no blur and no colour is one you cannot see, so
      # the first nudge would look like a control that does nothing.
      assert shadow =~ "rgba"
    end

    test "and Inside turns it into an inner shadow and back", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-m") |> render_click()
      view |> element("#pb-shadow-base-inset") |> render_click()

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert String.starts_with?(shadow, "inset ")

      view |> element("#pb-shadow-base-inset") |> render_click()

      assert %{base: %{"shadow" => plain}} = styles_of(view, node.id)
      refute plain =~ "inset"
    end

    test "and it reaches the page as a shadow utility", %{view: view, page: page} do
      view |> element("#pb-shadow-preset-s") |> render_click()
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "shadow-[0_1px_2px_0_rgba(15,23,42,0.08)]"
    end

    # A SWATCH ROW OF HARDCODED HEX IS A PALETTE WITH NOTHING TO DO WITH THE SITE. The five here are
    # the editor's own neutrals; the site's real colours were declared in its stylesheet, listed in
    # the Studio one panel away, and unreachable from the control that paints things — so a rebrand
    # meant repainting every element by hand.
    #
    # A token writes `var(--danger-light)`, which is the difference: the element resolves through the
    # same declaration every component on the site resolves through, and changing the token changes
    # them together.
    test "the site's own colours sit beside the editor's", %{conn: conn, page: page} do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "swatch-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n  --danger-light: #de1135;\n  --radius-lg: 12px;\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # FOLDED, BEHIND ITS COUNT. The installed kit theme declares 251 colours — every state of every
      # variant — and a row of them at the neutrals' size is a wall the Background control disappears
      # into. The five that are always open are the editor's own.
      refute has_element?(view, "#pb-token-base-background-danger-light")

      view |> element("#pb-section-site-colours") |> render_click()

      assert has_element?(view, "#pb-token-base-background-danger-light")

      # A length is not a colour. Offering `--radius-lg` as a background is a swatch that draws
      # nothing, which reads as a broken control rather than as an unsuitable token.
      refute has_element?(view, "#pb-token-base-background-radius-lg")

      view |> element("#pb-token-base-background-danger-light") |> render_click()

      assert styles_of(view, section.id) == %{base: %{"background" => "var(--danger-light)"}}
    end

    # AND THE ROW IS A CONVENIENCE, NOT A PRECONDITION. Reading the tokens means reading every
    # stylesheet the site can see and parsing them; done on the mount, a sheet that cannot be read
    # took the whole editor with it — trading something the author needs for something they would
    # merely like.
    test "an unreadable stylesheet costs the swatches, not the session", %{view: view} do
      assert has_element?(view, "#pb-swatch-violet")
      refute has_element?(view, "#pb-section-site-colours")
    end

    # A PICTURE THE AUTHOR PICKS, NOT A PATH THEY REMEMBER. A hero's photograph is a background, so
    # there is no `src` to point the library at — which left it reachable from an `<img>` and not
    # from the element people most want a picture on.
    test "a background can be chosen from the media library", %{view: view} do
      assert has_element?(view, "#pb-background-pick")

      view |> element("#pb-background-pick") |> render_click()

      assert render(view) =~ "Choosing for"
    end

    # The gallery answers with a ROW ACTION rather than a click of ours — the tiles are Gervaz's — so
    # this is the message the sheet really sends.
    test "and a file that is no longer there writes nothing", %{view: view, node: node} do
      view |> element("#pb-background-pick") |> render_click()

      send(view.pid, {:row_action, "use_media", %{"id" => Ecto.UUID.generate()}})

      assert render(view) =~ "no longer in the library"
      assert styles_of(view, node.id) == %{}
    end

    test "the Layout and Appearance groups render", %{view: view} do
      html = render(view)
      assert html =~ "Layout"
      assert html =~ "Appearance"
      assert html =~ "Gap"
      assert html =~ "Background"
    end

    test "a style edit lands in the base bucket and compiles to a class on save", %{
      conn: conn,
      page: page,
      view: view,
      node: node
    } do
      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "20px"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "20px"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "gap-[20px]"
      assert conn
    end

    # Firing `op` directly proves the HANDLER. This proves the CONTROL, which is a different claim:
    # the panel once offered breakpoint and state selectors that chose a bucket no widget ever wrote
    # to, and a handler-level test cannot see a hole like that.
    test "typing in a style field writes the override", %{view: view, node: node} do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}

      # No override marker at base: at Desktop/Normal the value IS the element's value, and the
      # prototype marks a field as overridden only against that baseline.
      refute has_element?(view, "#pb-style-clear-base-gap")

      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})
      assert has_element?(view, "#pb-style-clear-tablet-gap")
    end

    test "the override dot next to a set field clears just that bucket", %{
      view: view,
      node: node
    } do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})

      view |> element("#pb-style-clear-tablet-gap") |> render_click()

      # Only the tablet bucket goes; the base value it was overriding stays.
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}
    end

    # Every property the serialiser can express has to have a control, or the round trip is one-way:
    # a template with `max-w-[60ch]` on it parses into an override the panel cannot show or undo.
    # The claim is narrow and worth pinning: an editing field commits on its own debounce, so nobody
    # has to click away to make a change land. Structurally that means every field lives in a FORM
    # carrying `phx-change` and every input carries `phx-debounce` — a bare `phx-change` on an input
    # outside a form fires nothing at all, which is how these fields were dead once before.
    test "every editing field commits on debounce, with no blur required", %{
      view: view,
      node: node
    } do
      # The shape that makes a debounce commit work at all: the field is inside a form carrying the
      # change event, and the input debounces. A bare `phx-change` on an input outside a form fires
      # nothing — which is exactly how these fields were dead once before.
      assert has_element?(view, ~s(form[phx-change="op"] input[phx-debounce="350"]))

      # Nothing commits on blur any more; that is what forced the click-away.
      refute has_element?(view, "[phx-blur]")

      # And the behaviour itself, through the control rather than the handler: a change with no blur
      # of any kind reaches the tree.
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "27px"})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> then(& &1.meta.styles) == %{base: %{"gap" => "27px"}}
    end

    test "every property the serialiser understands has a control", %{view: view} do
      # Direction, Spread, Align and Wrap are shown only on an element that IS a flex row, and the
      # column count only on one that is a grid — they do nothing to anything else, and an element
      # cannot be both. So the claim is that every property is REACHABLE, not that every property is
      # on screen at once: each is looked for on the display it belongs to.
      # And the axis pair is folded away under the spacing box on an element that sets neither, so it
      # is opened the way a reader opens it. Reachable, again, is the claim.
      view |> element("#pb-section-spacing-by-axis") |> render_click()

      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      as_flex = render(view)

      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      as_grid = render(view)

      for prop <- Styles.properties() do
        assert control_for?(as_flex, prop) or control_for?(as_grid, prop),
               "no control for the #{prop} override"
      end

      # Background has the swatch row on top of its field, the way Gap has its presets.
      assert as_flex =~ "pb-swatch-"
    end

    # THE FIVE SHAPES A CONTROL COMES IN. A field in a form, the picture row an enumerated layout
    # property gets, the styled-label pills the typographic ones get, a cell in the spacing box, and
    # the shadow editor's own parts. What is pinned is that the property reaches the reader — not
    # which widget it arrived in, which is a design decision and moves.
    defp control_for?(html, prop) do
      String.contains?(html, "pb-style-form-base-#{prop}") or
        String.contains?(html, "pb-style-pics-base-#{prop}") or
        String.contains?(html, "pb-style-base-#{prop}-") or
        String.contains?(html, "pb-edge-form-base-#{prop}") or
        (prop == "shadow" and String.contains?(html, "pb-shadow-base-blur"))
    end

    # A SWATCH IS A PRESET, NOT THE ONLY WAY IN. The field below holds anything, and the swatch it
    # matches lights up — so a background typed by hand still reads as chosen when it is one of the
    # five, and reads as itself when it is not.
    test "the field and the swatches are one control", %{view: view, node: node} do
      view |> element("#pb-swatch-ink") |> render_click()
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="true"]))

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#dadada"})

      assert styles_of(view, node.id) == %{base: %{"background" => "#dadada"}}
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="false"]))
      assert view |> element("#pb-style-base-background") |> render() =~ "#dadada"

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#17161a"})
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="true"]))
    end

    # Every other preset row in the panel clears itself on a second press, and the one that did not
    # was the one whose value could not be reached any other way.
    test "pressing the chosen swatch clears it", %{view: view, node: node} do
      view |> element("#pb-swatch-violet") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"background" => "#4f4bcc"}}

      view |> element("#pb-swatch-violet") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    test "clearing a bucket drops everything written into it and nothing else", %{
      view: view,
      node: node
    } do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})
      view |> element("#pb-style-form-tablet-width") |> render_change(%{"value" => "100%"})

      view |> element("#pb-style-reset") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}
    end

    # A reset that would clear nothing reads as a broken button, so it is not drawn at all.
    test "an untouched bucket offers no reset", %{view: view} do
      refute has_element?(view, "#pb-style-reset")

      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      assert has_element?(view, "#pb-style-reset")
    end

    test "emptying a base field clears it", %{view: view, node: node} do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => ""})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{}
    end

    # Display and its flex-only neighbours are pictures rather than a `<select>` of raw utilities:
    # the value still written is the bare Tailwind class, which is what makes the round trip work.
    test "picking a Layout picture writes the bare Tailwind utility", %{
      conn: conn,
      page: page,
      view: view,
      node: node
    } do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"display" => "grid"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "grid"
      assert conn
    end

    # §3 — the layout vocabulary as pictures. What is pinned is the behaviour a non-technical author
    # depends on, not the markup: one click sets, the same click again clears, and the controls that
    # cannot do anything are not offered.
    test "clicking the chosen picture again clears the override", %{view: view, node: node} do
      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"display" => "flex"}}

      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    test "the flex-only pictures appear only once the element is a row", %{view: view} do
      refute has_element?(view, "#pb-style-pics-base-direction")
      refute has_element?(view, "#pb-style-pics-base-justify")

      view |> element("#pb-style-pic-base-display-flex") |> render_click()

      assert has_element?(view, "#pb-style-pics-base-direction")
      assert has_element?(view, "#pb-style-pics-base-align")
      assert has_element?(view, "#pb-style-pics-base-wrap")

      # …and they go again with the row, rather than lingering as settings with no effect.
      view |> element("#pb-style-pic-base-display-block") |> render_click()
      refute has_element?(view, "#pb-style-pics-base-justify")
    end

    # A row that inherits its display from Desktop is still a row on Mobile. Reading only the open
    # bucket made these four vanish the moment the reader switched breakpoint.
    test "a narrower breakpoint still offers the flex pictures it inherits", %{view: view} do
      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      view |> element("#pb-bp-mobile") |> render_click()

      assert has_element?(view, "#pb-style-pics-mobile-justify")
    end

    test "a gap preset writes the length it is named for", %{view: view, node: node} do
      view |> element("#pb-style-gap-base-L") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"gap" => "16px"}}

      # The field and the presets are one override, so the field shows what the preset wrote…
      assert view |> element("#pb-style-base-gap") |> render() =~ ~s(value="16px")

      # …and pressing the lit preset takes it off.
      view |> element("#pb-style-gap-base-L") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    # §4 — the breakpoint is a tab, and the count on it is how a responsive override stays findable.
    test "each breakpoint tab counts what it sets, and only its own", %{view: view} do
      refute has_element?(view, "#pb-bp-count-base")

      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")
      refute has_element?(view, "#pb-bp-count-mobile")

      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-style-form-mobile-gap") |> render_change(%{"value" => "8px"})
      view |> element("#pb-style-pic-mobile-display-flex") |> render_click()

      assert view |> element("#pb-bp-count-mobile") |> render() =~ ~s(title="2 set here")
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")

      # A STATE SET AT A WIDTH BELONGS TO THAT WIDTH. It used to be counted nowhere — the badge
      # looked only at the plain breakpoint bucket — so a hover colour set on mobile was a change
      # with nothing on screen pointing at it, which is exactly how a responsive edit becomes
      # impossible to find again a week later.
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "4px"})

      assert view |> element("#pb-bp-count-mobile") |> render() =~ ~s(title="3 set here")
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")
    end

    # THE CANVAS GOES WHERE THE PANEL GOES. Choosing Tablet says "I am working on tablet", and
    # leaving the frame at desktop width answers that with a page the override cannot be seen on:
    # the author sets a value, nothing moves, and the control reads as broken when it is the
    # viewport that is wrong.
    test "the breakpoint tab moves the canvas with it", %{view: view} do
      assert device(view) == :desktop

      view |> element("#pb-bp-mobile") |> render_click()
      assert device(view) == :mobile

      view |> element("#pb-bp-tablet") |> render_click()
      assert device(view) == :tablet

      view |> element("#pb-bp-base") |> render_click()
      assert device(view) == :desktop
    end

    # AND IT OPENS WHERE THE SESSION LEFT IT. The breakpoint survives a reload — that is what stops a
    # refresh throwing the panel's place away — but the frame did not, so an editor last used on
    # Mobile came back with the Mobile tab active over a desktop-width canvas. The first click on
    # Mobile then looked broken, because the tab it highlights was already the highlighted one.
    test "and the frame opens where the session left it", %{conn: conn, page: page, view: view} do
      view |> element("#pb-bp-mobile") |> render_click()

      assert device(view) == :mobile

      # A second mount, the way a refresh is: the session hands back the breakpoint it was left on,
      # and the frame has to come with it.
      {:ok, reopened, _html} = open_builder(conn, page)

      assert breakpoint(reopened) == :mobile, "the session did not keep the breakpoint"
      assert device(reopened) == :mobile
    end

    # AND THE OTHER WAY ROUND, which is the half that was missing. The device strip moved the frame
    # and left the breakpoint alone, so the canvas went to 390px while the Inspector kept writing the
    # `base` bucket — an author sizing something on a mobile canvas was setting it for every width.
    test "choosing a frame moves the breakpoint it shows", %{view: view} do
      render_click(view, "set_device", %{"device" => "mobile"})
      assert breakpoint(view) == :mobile

      render_click(view, "set_device", %{"device" => "tablet"})
      assert breakpoint(view) == :tablet

      render_click(view, "set_device", %{"device" => "desktop"})
      assert breakpoint(view) == :base, "the widest frame is what every width looks like"
    end

    # THE SYMPTOM AS REPORTED: the strip lit Mobile over a desktop canvas, so the first press on
    # Mobile did nothing visible — it was already the lit tab. Asserted on the two together, because
    # either one alone is only half the disagreement.
    test "so the lit tab and the canvas never disagree", %{view: view} do
      view |> element("#pb-bp-mobile") |> render_click()
      render_click(view, "set_device", %{"device" => "desktop"})

      assert {:desktop, :base} == {device(view), breakpoint(view)}

      html = render(view)
      assert html =~ ~s(id="pb-bp-base" phx-click="set_breakpoint" value="base" title)
      assert html =~ ~s(aria-pressed="true")

      refute view |> element("#pb-bp-mobile") |> render() =~ ~s(aria-pressed="true"),
             "Mobile stayed lit over a desktop canvas"
    end

    # And the round trip is stable, so neither control can drift the other off by one.
    test "and the two controls round-trip through each other", %{view: view} do
      for {frame, bp} <- [{"mobile", :mobile}, {"tablet", :tablet}, {"desktop", :base}] do
        render_click(view, "set_device", %{"device" => frame})
        assert breakpoint(view) == bp

        view |> element("#pb-bp-#{bp}") |> render_click()
        assert device(view) == String.to_existing_atom(frame)
      end
    end

    # LEAVING side by side is the one path where both controls move at once, and it is the one that
    # took longest to settle on screen — three frames come down and one goes up. Asserted here rather
    # than in the browser, where a probe can read between the two.
    test "and leaving the side-by-side view lands on the frame that was asked for", %{view: view} do
      view |> element("#pb-bp-mobile") |> render_click()
      render_click(view, "set_device", %{"device" => "frames"})

      assert {:frames, :mobile} == {device(view), breakpoint(view)},
             "every width is already on screen, so it moves nothing"

      render_click(view, "set_device", %{"device" => "desktop"})

      assert {:desktop, :base} == {device(view), breakpoint(view)}
    end

    # EXCEPT SIDE BY SIDE, where every width is already on screen and switching to one would take
    # away what the reader opened it for.
    test "but not when the frames view is showing every width at once", %{view: view} do
      render_click(view, "set_device", %{"device" => "frames"})

      view |> element("#pb-bp-mobile") |> render_click()

      assert device(view) == :frames
    end

    # THE BUG THIS MATRIX EXISTS FOR. A hover set while the panel says Mobile must not touch the
    # desktop, and the two must be able to disagree.
    test "a hover set on mobile is a mobile hover", %{view: view, node: node} do
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-hover-gap") |> render_change(%{"value" => "10px"})

      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      assert styles_of(view, node.id) == %{
               hover: %{"gap" => "10px"},
               mobile_hover: %{"gap" => "2px"}
             }
    end

    test "and it reaches the page as a query and a pseudo-class", %{view: view, page: page} do
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "max-[560px]:hover:gap-[2px]"
    end

    # EVERY BUCKET CAN BE CLEARED, not just the plain ones. The button reads the bucket it is
    # clearing, so `mobile :hover` says so rather than offering to clear "mobile".
    test "each bucket offers its own reset, named after itself", %{view: view, node: node} do
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      assert view |> element("#pb-style-reset") |> render() =~ "mobile :hover"

      view |> element("#pb-style-reset") |> render_click()

      assert styles_of(view, node.id) == %{}
    end

    test "a background swatch writes into the current bucket", %{view: view, node: node} do
      view |> element("#pb-swatch-ink") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"background" => "#17161a"}}
    end

    test "the Editing-at and State selectors each explain where an edit lands", %{view: view} do
      assert render(view) =~ "Recorded as the value for every size"

      render_click(view, "set_breakpoint", %{"value" => "tablet"})
      assert render(view) =~ "Recorded against 900px and below"

      render_click(view, "set_pseudo", %{"value" => "hover"})
      html = render(view)
      assert html =~ "Recorded against :hover"
      assert html =~ "Recorded"
    end

    # Each Behavior switch is a class the element either carries or does not, so it reports the
    # document rather than a flag kept beside it — save, reopen, and it is still on.
    test "a Behavior switch adds and removes its classes", %{view: view, node: node} do
      classes = fn ->
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Node.attr_text("class")
      end

      view |> element("#pb-toggle-sticky") |> render_click()
      assert classes.() =~ "sticky"
      assert classes.() =~ "top-0"

      view |> element("#pb-toggle-shadow") |> render_click()
      assert classes.() =~ "shadow-lg"

      view |> element("#pb-toggle-sticky") |> render_click()
      refute classes.() =~ "sticky"
      # Turning one off leaves the other alone.
      assert classes.() =~ "shadow-lg"
    end

    # AND A SWITCH OVER A COMPUTED CLASS JOINS IT. The switch read the row as text and wrote all of
    # it back as one string, so on `class={[@variant, "lead"]}` it put the expression's own source
    # on the element as literal words: not Elixir, and a page that would no longer compile or save.
    test "a switch joins a computed class rather than writing over it", %{view: view, node: node} do
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node.id,
        "name" => "class",
        "value" => ~S|[@variant, "lead"]|,
        "value_kind" => "expr"
      })

      view |> element("#pb-toggle-shadow") |> render_click()

      assert attr_of(view, node.id, "class") == {:expr, ~S|[@variant, "lead", "shadow-lg"]|}
      assert view |> element("#pb-toggle-shadow") |> render() =~ ~s(aria-checked="true")

      assert CodeCheck.template(Serializer.serialize(editor(view).tree)) == :ok

      view |> element("#pb-toggle-shadow") |> render_click()

      assert attr_of(view, node.id, "class") == {:expr, ~S|[@variant, "lead"]|}
    end

    test "a switch reads as on when the element already carries its classes", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section class="sticky top-0 z-10">x</section>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-behavior") |> render_click()

      assert view |> element("#pb-toggle-sticky") |> render() =~ ~s(aria-checked="true")
      assert view |> element("#pb-toggle-shadow") |> render() =~ ~s(aria-checked="false")
    end

    # Listing the attributes a node already has is not the same as being able to give it one; before
    # this the only way to add `aria-label` or a data attribute was the code drawer.
    test "a new attribute can be added by name", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "aria-label", "value" => "Hero"}})
      |> render_submit()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> Node.attr_text("aria-label") ==
               "Hero"
    end

    # EVERY ATTRIBUTE IN THIS LIST USED TO BE A TEXT BOX, including the two a page is most often
    # edited through. A block's `<img src>` was a path to type from memory while the site's media
    # library sat one panel away, and its `<a href>` was a URL with nothing to open it.
    test "a picture's source offers the library, and a link offers to open itself", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "insert",
        "parent_id" => node_with_tag(view, "section").id,
        "template" => ~s(<img src="/uploads/a.png" alt="a" />)
      })

      image = node_with_tag(view, "img")
      render_click(view, "select", %{"id" => image.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-attributes") |> render_click()

      assert has_element?(view, "#pb-attr-row-pick-src")
      refute has_element?(view, "#pb-attr-row-open-src")
    end

    test "and a link offers to open itself where a picture does not", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "insert",
        "parent_id" => node_with_tag(view, "section").id,
        "template" => ~s(<a href="https://example.com">x</a>)
      })

      link = node_with_tag(view, "a")
      render_click(view, "select", %{"id" => link.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-attributes") |> render_click()

      assert has_element?(view, "#pb-attr-row-open-href")
      refute has_element?(view, "#pb-attr-row-pick-href")
    end

    # And the row is still the field it was: the widget decorates it, it does not replace it.
    test "a widget row still writes the attribute", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "data-role", "value" => "hero"}})
      |> render_submit()

      view
      |> element("#pb-attr-row-form-#{node.id}-data-role")
      |> render_change(%{"value" => "banner"})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> Node.attr_text("data-role") == "banner"
    end

    test "adding an attribute with no name changes nothing", %{view: view, node: node} do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "  ", "value" => "x"}})
      |> render_submit()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before
    end

    test "the field written to follows the breakpoint selector", %{view: view, node: node} do
      render_click(view, "set_breakpoint", %{"value" => "mobile"})

      refute has_element?(view, "#pb-style-base-gap")
      view |> element("#pb-style-form-mobile-gap") |> render_change(%{"value" => "6px"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{mobile: %{"gap" => "6px"}}
    end

    test "switching the breakpoint writes into that bucket instead", %{view: view, node: node} do
      render_click(view, "set_breakpoint", %{"value" => "mobile"})

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "mobile",
        "prop" => "py",
        "value" => "14px"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{mobile: %{"py" => "14px"}}
      # Per-field Reset only — the prototype has no group-level one.
      assert has_element?(view, "#pb-style-clear-mobile-py")
    end

    test "a state selector writes into the pseudo bucket", %{view: view, node: node} do
      render_click(view, "set_pseudo", %{"value" => "hover"})

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "hover",
        "prop" => "background",
        "value" => "#17161a"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{hover: %{"background" => "#17161a"}}
    end

    test "Reset clears only that bucket", %{view: view, node: node} do
      for {bucket, value} <- [{"base", "8px"}, {"mobile", "2px"}] do
        render_click(view, "op", %{
          "kind" => "set_style",
          "node_id" => node.id,
          "bucket" => bucket,
          "prop" => "gap",
          "value" => value
        })
      end

      render_click(view, "op", %{
        "kind" => "reset_styles",
        "node_id" => node.id,
        "bucket" => "mobile"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{base: %{"gap" => "8px"}}
    end

    test "clearing a field removes just that property", %{view: view, node: node} do
      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "8px"
      })

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => ""
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{}
    end
  end

  # THE ROW USED TO CORRUPT WHAT IT SHOWED. An expression's braces belong to the markup around the
  # value, not to the value, and drawing them inside an editable box put them back into the document
  # the moment the row was touched. `phx-click={{JS…}}` is a one-tuple, which raises
  # `Protocol.UndefinedError` where the page renders; `:if={{assigns[:current_user]}}` is a one-tuple
  # too, and truthy, so an element hidden from signed-out visitors came back for everyone. Nothing
  # downstream takes braces off, so each re-edit added another pair.
  @click_source ~S|JS.toggle_class("is-open", to: ".pb-1")|
  @condition_source "assigns[:current_user]"

  describe "an attribute that holds an expression" do
    setup %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~S"""
          <section id="hero">
            <div phx-click={JS.toggle_class("is-open", to: ".pb-1")} :if={assigns[:current_user]} data-role="hero">
              secret
            </div>
          </section>
          """
        )

      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "div")

      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-attributes") |> render_click()

      %{view: view, node: node}
    end

    test "the box offers the source, and the mark says that is what it is", %{view: view} do
      assert field_value(view, "pb-attr-row-phx-click") == @click_source
      assert field_value(view, "pb-attr-row-:if") == @condition_source

      assert has_element?(view, "#pb-attr-row-expr-phx-click")
      assert has_element?(view, ~s([id="pb-attr-row-expr-:if"]))

      # A plain attribute reads as itself and carries no mark.
      assert field_value(view, "pb-attr-row-data-role") == "hero"
      refute has_element?(view, "#pb-attr-row-expr-data-role")
    end

    # STATED, NOT INFERRED. The write says what the box is holding, so what the row does no longer
    # depends on `Op` reading the tree back to guess it.
    test "each row says which kind its write is", %{view: view, node: node} do
      for {name, kind} <- [{"phx-click", "expr"}, {":if", "expr"}, {"data-role", "string"}] do
        assert has_element?(
                 view,
                 ~s(form[id="pb-attr-row-form-#{node.id}-#{name}"][phx-value-value_kind="#{kind}"])
               ),
               "the #{name} row does not state that it writes #{kind}"
      end
    end

    test "a row posted back unchanged leaves the expression as it was", %{view: view, node: node} do
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      assert attr_of(view, node.id, "phx-click") == {:expr, @click_source}

      # Twice, because the braces were cumulative: a second pair is what a second edit used to add.
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      assert attr_of(view, node.id, "phx-click") == {:expr, @click_source}
      assert editor_html(view) =~ ~s(phx-click={#{@click_source}})
    end

    test "and a touched condition is still a condition, not a truthy tuple", %{
      view: view,
      node: node
    } do
      commit_row(view, "pb-attr-row-form-#{node.id}-:if", field_value(view, "pb-attr-row-:if"))

      assert attr_of(view, node.id, ":if") == {:expr, @condition_source}
      assert editor_html(view) =~ ~s(:if={#{@condition_source}})
      refute editor_html(view) =~ "{{"
    end

    test "an edit reaches the expression, not the braces that used to be round it", %{
      view: view,
      node: node
    } do
      # What the author does by hand: click into the row, add a space, blur. Taken from the BOX and
      # not from the source behind it, because what the row offers is the whole of what an edit
      # sends back — braces round it and all, when there were any.
      edited =
        view |> field_value("pb-attr-row-phx-click") |> String.replace(", to:", ",  to:")

      commit_row(view, "pb-attr-row-form-#{node.id}-phx-click", edited)

      assert attr_of(view, node.id, "phx-click") ==
               {:expr, String.replace(@click_source, ", to:", ",  to:")}
    end

    test "what the rows wrote survives serializing and parsing it again", %{
      view: view,
      node: node
    } do
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      commit_row(view, "pb-attr-row-form-#{node.id}-:if", field_value(view, "pb-attr-row-:if"))

      markup = editor_html(view)
      {:ok, reparsed} = Tree.parse(markup)

      assert Serializer.serialize(reparsed) == markup

      again = reparsed |> Tree.walk() |> Enum.find(&(&1.tag == "div"))

      assert Node.attr(again, "phx-click") == {:expr, @click_source}
      assert Node.attr(again, ":if") == {:expr, @condition_source}
    end

    # AND THE PAGE STILL ANSWERS. What the rows store is only half the promise: the other half is the
    # compiler reading that markup back, which is the path a published page is served through. A
    # one-tuple raises there rather than rendering, and a `:if` holding one is truthy whatever it was
    # guarding — so the element a signed-out visitor must not see came back for everyone.
    test "and the markup they leave behind renders the way the page is served", %{
      view: view,
      node: node
    } do
      commit_row(
        view,
        "pb-attr-row-form-#{node.id}-phx-click",
        field_value(view, "pb-attr-row-phx-click")
      )

      commit_row(view, "pb-attr-row-form-#{node.id}-:if", field_value(view, "pb-attr-row-:if"))

      markup = editor_html(view)

      signed_out = LiveViewCompiler.render_template(markup, %{})

      assert is_binary(signed_out),
             "the page no longer renders at all: #{inspect(signed_out, limit: 3)}"

      refute signed_out =~ "secret", "the condition no longer hides what it guards"

      signed_in = LiveViewCompiler.render_template(markup, %{current_user: %{id: "u1"}})

      assert is_binary(signed_in),
             "the page no longer renders for a visitor who is signed in: #{inspect(signed_in, limit: 3)}"

      assert signed_in =~ "secret"
      assert signed_in =~ "toggle_class"
    end

    # THE BOX BESIDE THE LIST COULD DELETE WHAT THE LIST WAS SHOWING. It sends a name and whatever is
    # typed next to it, and an empty value is how every other control in the panel says "take this
    # attribute off" — so typing the name of a row that is already there, with the value box left
    # alone, removed it. On `:if` that publishes to everyone what the condition was keeping back.
    test "a name the element already carries is not added over the top of it", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => ":if", "value" => ""}})
      |> render_submit()

      assert attr_of(view, node.id, ":if") == {:expr, @condition_source}
      assert editor_html(view) =~ ~s(:if={#{@condition_source}})

      signed_out = LiveViewCompiler.render_template(editor_html(view), %{})

      assert is_binary(signed_out)

      refute signed_out =~ "secret",
             "the condition the add box was typed at is no longer guarding"
    end

    # AND NOT WITH A VALUE BESIDE IT EITHER. The row is in the list above the box with its own field;
    # an add reaching the same name is a name typed twice, and taking the second one would throw away
    # what the first holds — on `class` that is everything the style panel wrote.
    test "and a value typed beside a name already in the list does not replace it", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "data-role", "value" => "banner"}})
      |> render_submit()

      assert attr_of(view, node.id, "data-role") == {:string, "hero"}
    end

    # AND THE READER IS TOLD WHERE THE NAME WENT. A refusal that changes nothing on screen is a box
    # that swallowed what was typed into it, so the row holding that name is rung the same way a
    # property row arrived at from the tree is.
    test "the row that already holds the name is rung instead", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "data-role", "value" => ""}})
      |> render_submit()

      assert view
             |> element(~s([id="pb-attr-row-#{node.id}-data-role"]))
             |> render() =~ "bg-[#f7f6ff]"

      refute view
             |> element(~s([id="pb-attr-row-#{node.id}-phx-click"]))
             |> render() =~ "bg-[#f7f6ff]"
    end

    # A HEEX SPECIAL IS NOT A LITERAL. `:if`, `:for` and `:let` must be an expression between braces,
    # and this box only ever writes one of the words typed into it: `:for="item <- @items"` is not a
    # loop, it is a template the compiler refuses outright, so the page stopped rendering at all.
    test "a name HEEx reserves is refused rather than written as a string", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => ":for", "value" => "item <- @items"}})
      |> render_submit()

      assert attr_of(view, node.id, ":for") == nil
      refute editor_html(view) =~ ":for"

      assert is_binary(LiveViewCompiler.render_template(editor_html(view), %{})),
             "the page the add box left behind no longer compiles"
    end

    # And a name it does not carry is still added, with the empty row the author came for: the old
    # write sent `value: ""`, which the funnel read as a removal, so nothing appeared at all.
    test "a name the element does not carry arrives as a row to type into", %{
      view: view,
      node: node
    } do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "aria-label", "value" => ""}})
      |> render_submit()

      assert attr_of(view, node.id, "aria-label") == {:string, ""}
      assert has_element?(view, "#pb-attr-row-#{node.id}-aria-label")
    end

    # INCLUDING `id`. A component is refused that one because the property list above already offers
    # it; an element declares nothing, its list holds `id` like any other row, and this box is the
    # only place the panel has to give an element one.
    test "and an element with no id can still be given one", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "id", "value" => "hero-copy"}})
      |> render_submit()

      assert attr_of(view, node.id, "id") == {:string, "hero-copy"}
    end
  end

  # THE SAME LIST A SECOND TIME. A component's Advanced disclosure is built from the same rows, for
  # the attributes it never declared and takes through its `@rest` catch-all — so a `phx-*` on a
  # component corrupted exactly the way one on an element did.
  describe "a component attribute that holds an expression" do
    test "the Advanced row keeps the expression it shows", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "with-rest",
        attrs: [
          %{"name" => "title", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="with-rest" site="#{site.name}" phx-click={#{@click_source}}/>),
        "parent_id" => node_with_tag(view, "section").id,
        "index" => "0"
      })

      node = component_node(view, "with-rest")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert field_value(view, "pb-extra-phx-click") == @click_source
      assert has_element?(view, "#pb-extra-expr-phx-click")

      assert has_element?(
               view,
               ~s(form[id="pb-extra-form-#{node.id}-phx-click"][phx-value-value_kind="expr"])
             ),
             "the Advanced row does not state that it writes an expression"

      commit_row(
        view,
        "pb-extra-form-#{node.id}-phx-click",
        field_value(view, "pb-extra-phx-click")
      )

      assert attr_of(view, node.id, "phx-click") == {:expr, @click_source}
      assert editor_html(view) =~ ~s(phx-click={#{@click_source}})
    end
  end

  # THE BOX HAD NO IDEA WHAT THE NODE ALREADY HELD. It is free text, it sends a name and no value,
  # and the write went straight to the session with `value: ""` — past the rule that turns an empty
  # value into a removal, so the empty one landed. A string attribute came back as `color=""`, which
  # beats the component's own default; an expression came back as `:if={}`, which HEEx reads as nil,
  # so the element and everything inside it left the published page while the tree went on showing
  # the node. The comment above the handler said a duplicate name was a no-op; nothing checked.
  describe "the Advanced attribute editor" do
    setup %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "with-advanced",
        template: ~s(<div class={@color} {@rest}>advanced</div>),
        attrs: [
          %{"name" => "color", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      page = create_page!(site_id: site.id, template: @template)
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "drop", %{
        "template" =>
          ~s(<.component component_name="with-advanced" site="#{site.name}" color="primary" aria-label="Hero" :if={#{@condition_source}}/>),
        "parent_id" => node_with_tag(view, "section").id,
        "index" => "0"
      })

      node = component_node(view, "with-advanced")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      %{view: view, node: node}
    end

    defp add_extra(view, node, name),
      do: view |> form("#pb-extra-form-#{node.id}", %{"name" => name}) |> render_submit()

    test "a name the node does not carry arrives as a row to type into", %{
      view: view,
      node: node
    } do
      refute has_element?(view, "#pb-extra-data-role")

      add_extra(view, node, "data-role")

      assert has_element?(view, "#pb-extra-data-role")
      assert field_value(view, "pb-extra-data-role") == ""
      assert attr_of(view, node.id, "data-role") == {:string, ""}
    end

    # The name is trimmed on the way in, so the row it lands on is the one the author meant.
    test "and the space around what was typed is not part of the name", %{view: view, node: node} do
      add_extra(view, node, "  data-role  ")

      assert has_element?(view, "#pb-extra-data-role")
      assert attr_of(view, node.id, "data-role") == {:string, ""}
    end

    test "a name already on the node keeps the value it is holding", %{view: view, node: node} do
      add_extra(view, node, "aria-label")

      assert attr_of(view, node.id, "aria-label") == {:string, "Hero"}
      assert field_value(view, "pb-extra-aria-label") == "Hero"
    end

    # AND THE READER IS TOLD WHERE IT WENT. Refusing without changing anything on screen is a box
    # that swallowed what was typed into it, so the row holding that name is rung the same way a
    # property row arrived at from the tree is.
    test "and the row holding it is rung instead", %{view: view, node: node} do
      add_extra(view, node, "aria-label")

      assert view |> element("#pb-extra-row-aria-label") |> render() =~ "bg-[#f7f6ff]"

      add_extra(view, node, "data-role")

      refute view |> element("#pb-extra-row-aria-label") |> render() =~ "bg-[#f7f6ff]"
      assert view |> element("#pb-extra-row-data-role") |> render() =~ "bg-[#f7f6ff]"
    end

    # A HEEX SPECIAL IS NOT A LITERAL. `:if`, `:for` and `:let` must be an expression between braces,
    # and this box has no value to put in one: `:for=""` is not a loop over nothing, it is a template
    # the compiler refuses outright, so the whole page stopped rendering rather than one element.
    test "a name HEEx reserves is refused even when the node does not carry it", %{
      view: view,
      node: node
    } do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)

      add_extra(view, node, ":for")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before

      refute editor_html(view) =~ ":for"
    end

    # `color` is DECLARED, so Advanced never lists it — the author is typing a name with no row on
    # screen to say it is already set, and the panel is the only thing that can know.
    test "a declared property is not blanked by a name Advanced does not list", %{
      view: view,
      node: node
    } do
      add_extra(view, node, "color")

      assert attr_of(view, node.id, "color") == {:string, "primary"}
      refute has_element?(view, "#pb-extra-color")
    end

    # AND THE ELEMENT IS STILL ON THE PAGE. `:if={}` is not a condition that never matches, it is a
    # condition HEEx reads as nil — the element and its subtree are never emitted at all.
    test "an existing condition is not emptied out from under the page", %{
      view: view,
      node: node
    } do
      add_extra(view, node, ":if")

      assert attr_of(view, node.id, ":if") == {:expr, @condition_source}
      assert editor_html(view) =~ ~s(:if={#{@condition_source}})
      refute editor_html(view) =~ ":if={}"
    end

    # AND NOT WHEN IT IS UNSET EITHER. A declared property with nothing written on the node is the
    # component's own default doing its job. `color=""` beats that default, and Advanced would not
    # list the row it had just written — so the component changed on the canvas and nothing on
    # screen said why.
    test "a declared property the node has not set keeps its default", %{view: view, site: site} do
      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="with-advanced" site="#{site.name}"/>),
        "parent_id" => node_with_tag(view, "section").id,
        "index" => "1"
      })

      plain =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(
          &(Node.component_name(&1) == "with-advanced" and is_nil(Node.attr(&1, "color")))
        )

      render_click(view, "select", %{"id" => plain.id})
      add_extra(view, plain, "color")

      assert attr_of(view, plain.id, "color") == nil
      refute has_element?(view, "#pb-extra-color")
    end

    # AND A REFUSAL IS SAID OUT LOUD. The write went straight to the session and threw the answer
    # away, so an op the session declines left the author looking at a box that had done nothing and
    # explained nothing.
    test "a refused write says so rather than leaving the row missing", %{view: view, node: node} do
      render_click(view, "toggle_lock", %{"id" => node.id})

      add_extra(view, node, "data-role")

      assert has_element?(view, "#flash-error")
      assert attr_of(view, node.id, "data-role") == nil
    end

    # The dynamic wrapper's own two attributes are on the node like any other, so the same lookup
    # covers them: blanking `site` is a component that no longer resolves to anything.
    test "the wrapper's own attributes survive being typed at", %{view: view, node: node} do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)

      add_extra(view, node, "site")
      add_extra(view, node, "component_name")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before
    end

    test "typing nothing into the box changes nothing", %{view: view, node: node} do
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs)

      add_extra(view, node, "   ")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Map.fetch!(:attrs) ==
               before
    end
  end

  describe "the assistant rail" do
    test "sending a prompt reaches the backend and renders both turns", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      assert has_element?(view, "#pb-ai-form")
      assert render(view) =~ "Echo (no model configured)"

      html =
        view |> form("#pb-ai-form", %{"prompt" => "Make the header sticky"}) |> render_submit()

      assert html =~ "Make the header sticky"
      # The default backend must SAY it cannot act rather than fabricate an edit.
      assert html =~ "No AI backend is configured"
      assert html =~ "Nothing was changed"
    end

    test "the prompt is scoped to the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      view |> element("#pb-rail-assistant") |> render_click()

      # The composer names the scope the way the prototype does — the tag in angle brackets.
      assert render(view) =~ "&lt;h1&gt;"

      html = view |> form("#pb-ai-form", %{"prompt" => "shorter"}) |> render_submit()
      assert html =~ "h1"
    end

    test "an empty prompt does nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()

      view |> form("#pb-ai-form", %{"prompt" => "   "}) |> render_submit()
      assert render(view) =~ "Describe a change"
    end
  end

  describe "the assistant rail's chrome" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()
      %{view: view}
    end

    test "it names who is answering, how it is connected, and what it has done", %{view: view} do
      html = render(view)

      assert html =~ "AI Assistant"
      assert html =~ "Echo (no model configured)"
      assert html =~ "0 revisions"
      # Claiming "Connected" while Echo answers would make its honest reply read as a malfunction.
      assert html =~ "Not connected"
      assert html =~ "Advanced settings"
    end

    # THE EXPLANATION IS ON THE PAGE, FOLDED. Nothing behind the disclosure needs this process, so
    # the heading is a JS toggle of a body that shipped with the panel.
    test "Advanced settings explains the backend, behind a fold the browser opens", %{view: view} do
      assert render(view) =~ "No model is connected"
      assert has_element?(view, "#pb-ai-advanced-body.hidden")
      assert view |> element("#pb-ai-advanced") |> render() =~ "#pb-ai-advanced-body"
    end

    test "a chip fills the box rather than sending", %{view: view} do
      html = render_click(view, "ai_chip", %{"text" => "Make the header sticky"})

      assert html =~ "Make the header sticky"
      # Nothing was asked — the wording stays the author's to adjust.
      assert editor_messages(view) == []
    end

    test "both turns render with a sender and the scope", %{view: view} do
      view |> form("#pb-ai-form", %{"prompt" => "Tighten the spacing"}) |> render_submit()

      html = render(view)
      assert html =~ "Tighten the spacing"
      assert html =~ "boss"
      assert html =~ "AI Assistant"
    end

    # Echo changes nothing, so it offers no Restore. A rollback button that rolls nothing back is
    # worse than none — the prototype shows one on every turn because its transcript is a mock.
    test "a reply that changed nothing offers no Restore", %{view: view} do
      view |> form("#pb-ai-form", %{"prompt" => "Make it blue"}) |> render_submit()

      refute has_element?(view, "#pb-ai-restore-1")
      assert render(view) =~ "0 revisions"
    end
  end

  # THE SEAM THE RAIL HAS ALWAYS CLAIMED. Echo returns no ops, so every one of the tests above passes
  # against a transcript nothing applies; these run a backend that does return one.
  describe "an assistant that edits the document" do
    setup %{conn: conn, page: page} do
      Application.put_env(:mishka_cms_core, :builder_ai_backend, MishkaCmsCore.Test.AiBackendStub)
      MishkaCmsCore.Test.AiBackendStub.answer([])

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :builder_ai_backend)
        Application.delete_env(:mishka_cms_core, :test_ai_answer)
      end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-assistant") |> render_click()
      %{view: view}
    end

    test "the ops it returns are applied, and the revision counts what landed", %{view: view} do
      insert_figure(view)

      assert node_with_tag(view, "figure"), "the reply's op reached the document"
      assert has_element?(view, "#pb-ai-restore-1")
      assert render(view) =~ "1 revision"
      assert render(view) =~ "1 change"
    end

    # One prompt is one undo step, however many ops it took — which is what a reader means by
    # "undo what it just did".
    test "undo takes the whole run back in one step", %{view: view} do
      insert_figure(view)
      assert node_with_tag(view, "figure")

      render_click(view, "undo", %{})

      refute node_with_tag(view, "figure")
    end

    # A run is all-or-nothing, so a refusal leaves the document alone — and the rail says so in the
    # transcript rather than stamping a revision whose Restore would write over the author's work.
    test "a refused op changes nothing, says so, and offers no Restore", %{view: view} do
      h1 = node_with_tag(view, "h1")
      before = editor(view).tree

      ask_ai(view, [%{kind: :insert, parent_id: h1.id, index: 0, template: "<section></section>"}])

      assert editor(view).tree == before
      refute has_element?(view, "#pb-ai-restore-1")
      assert render(view) =~ "0 revisions"

      # The headline is the loud line, and the model's claim is not allowed to stand in it with the
      # correction whispered underneath.
      assert %{
               text: "Nothing was changed. A `<h1>` can only hold text and inline elements.",
               plain: "Done: Add a figure"
             } = List.last(editor_messages(view))
    end

    # A model writes malformed ops, and a field-error list inspected into the bubble is a struct dump
    # for an admin to read.
    test "an op the editor cannot read is refused in words", %{view: view} do
      ask_ai(view, [%{kind: :rewrite, parent_id: "root", index: 0}])

      assert %{text: "Nothing was changed. That change could not be applied: unknown kind."} =
               List.last(editor_messages(view))
    end

    # Applied is not the same as changed. A run leaving the very same tree records nothing, so a
    # revision beside it would offer to roll back to the document already on screen — over whatever
    # the author did while waiting for the answer, which is what the canvas was still doing.
    test "an answer that changes nothing carries no revision", %{view: view} do
      section = node_with_tag(view, "section")

      ask_ai(
        view,
        [%{kind: :set_attr, node_id: section.id, name: "id", value: "hero", value_kind: :string}],
        [%{kind: :insert, parent_id: "root", index: 0, template: "<aside></aside>"}]
      )

      refute has_element?(view, "#pb-ai-restore-1")
      refute render(view) =~ "Nothing was changed"
      assert render(view) =~ "0 revisions"
      # The canvas's own insert, and no `:run` entry on top of it.
      assert [%{kind: :insert}] = editor(view).past
    end

    # THE DOCUMENT MOVES WHILE THE MODEL THINKS. The canvas is a separate process that keeps writing
    # for the whole round trip, so Restore has to put back the document as it was when the answer
    # landed — the rail's own copy of the tree is the one from before the question.
    test "Restore keeps an edit made while the answer was being written", %{view: view} do
      ask_ai(
        view,
        [%{kind: :insert, parent_id: "root", index: 0, template: "<figure></figure>"}],
        [%{kind: :insert, parent_id: "root", index: 0, template: "<aside></aside>"}]
      )

      assert node_with_tag(view, "figure")
      assert node_with_tag(view, "aside")

      render_click(view, "ai_restore", %{"index" => "1"})

      refute node_with_tag(view, "figure")
      assert node_with_tag(view, "aside"), "the edit made while the model was thinking survived"
    end

    # The history row is the assistant's, not the operator's, and carries what it was asked.
    test "the run is recorded as the assistant's, with the prompt behind it", %{view: view} do
      insert_figure(view)

      assert %{author_type: :ai, label: "1 change", prompt: "Add a figure", backend: backend} =
               hd(editor(view).past)

      assert backend == "Stub (test backend)"
    end

    # `opts` was a declared argument nothing ever filled, so a backend that would rather write its
    # own ops had no handle to write through.
    test "the backend is handed the session and the document it is editing", %{
      view: view,
      page: page
    } do
      ask_ai(view, [])

      assert_receive {:asked, "Add a figure", opts}
      assert opts[:token] == token(view)
      assert opts[:resource_id] == page.id
      assert opts[:site_id] == page.site_id
      assert opts[:section] == editor(view).section
    end

    defp insert_figure(view) do
      ask_ai(view, [%{kind: :insert, parent_id: "root", index: 0, template: "<figure></figure>"}])
    end

    # `meanwhile` is what the canvas writes while the model is answering — see the stub.
    defp ask_ai(view, ops, meanwhile \\ []) do
      MishkaCmsCore.Test.AiBackendStub.answer(ops, meanwhile)
      view |> form("#pb-ai-form", %{"prompt" => "Add a figure"}) |> render_submit()
    end
  end

  describe "the canvas's own event handlers" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      %{view: view, canvas: canvas}
    end

    # A real mouse drop lands on the CANVAS LiveView, not the chrome — a different handler.
    test "a drop on the canvas inserts", %{view: view, canvas: canvas} do
      section = node_with_tag(view, "section")

      render_click(canvas, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure")
    end

    test "a drop on the canvas moves", %{view: view, canvas: canvas} do
      h1 = node_with_tag(view, "h1")
      render_click(canvas, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})

      assert Tree.get(view |> editor() |> Map.fetch!(:tree), h1.id).parent_id == nil
    end

    test "an illegal drop on the canvas lands beside the target and says so", %{
      view: view,
      canvas: canvas
    } do
      h1 = node_with_tag(view, "h1")

      render_click(canvas, "drop", %{
        "template" => "<section></section>",
        "parent_id" => h1.id,
        "index" => "0"
      })

      assert_push_event(canvas, "pb:drop-moved", %{message: message})
      assert message =~ "Placed after"

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "section" and &1.children == []))

      assert inserted.parent_id == h1.parent_id
    end

    test "the canvas answers a dragstart with the tree's verdict", %{view: view, canvas: canvas} do
      h1 = node_with_tag(view, "h1")
      section = node_with_tag(view, "section")

      render_click(canvas, "drag_start", %{"template" => "<section></section>"})

      assert_push_event(canvas, "pb:drop-hints", %{accepts: accepts})
      assert accepts[h1.id] == false
      assert accepts[section.id] == true
    end

    test "inline text editing writes through the canvas", %{view: view, canvas: canvas} do
      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(canvas, "set_text", %{"id" => text.id, "text" => "Edited inline"})

      assert editor_html(view) =~ "Edited inline"
    end

    # Hover deliberately never reaches the server. Nothing reads it — the layers rail highlights the
    # SELECTION, as the prototype does — and pushing an event per mouseover meant a round trip and a
    # re-render of the whole document for every pixel the pointer travelled. The outline is a CSS rule
    # inside the frame instead.
    test "hovering costs no round trip: the canvas has no hover handler", %{canvas: canvas} do
      assert render(canvas) =~ ~s([data-node-id]:hover)

      # A stray push is ignored rather than mutating anything.
      assert render_click(canvas, "hover", %{"id" => "nabcdefgh"})
    end
  end

  describe "presence" do
    # You are always in the stack — that is what gives the bar the prototype's avatar chip without
    # inventing colleagues. What must NOT appear is a second one.
    test "a lone editor sees only their own avatar", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = view |> element("#pb-avatars") |> render()
      assert html =~ "Only you are editing this page"

      # Exactly one chip: you. A second would mean a second person, which is the case that matters.
      assert html |> String.split("rounded-full") |> length() == 2
    end

    # Two admins share a session by URL. This used to be impossible: `?session=` was ignored, so
    # each mount opened its own private tree and the avatars could never appear.
    test "a second admin joining by session token shares the document and shows up", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      shared = token(first)

      other = create_admin("colleague@example.com")

      second_conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
        |> log_in(other)

      {:ok, second, _html} =
        live(
          second_conn,
          "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{shared}"
        )

      # Same session, not a copy.
      assert token(second) == shared

      # An edit by one is seen by the other, over the session's PubSub topic.
      h1 = node_with_tag(first, "h1")
      render_click(second, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(first, "h1")

      # And each sees the other in the avatar row.
      assert render(first) =~ "pb-avatars"

      assert Enum.any?(
               MishkaCmsCore.Runtime.PageBuilder.Presence.editors(shared),
               &(&1.id == other.id)
             )
    end

    test "a site admin in a master's session sees the master as M, and the master sees them", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, first, _html} = open_builder(conn, page)
      shared = token(first)
      joiner = create_admin("tenant.joiner@example.com", site.id)

      {:ok, second, _html} =
        live(
          log_in(build_conn_for_host(), joiner),
          "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{shared}"
        )

      assert token(second) == shared
      assert avatars(second) == ["TJ", "M"]
      assert avatars(first) == ["B", "TJ"]
      refute MishkaCmsCore.Runtime.PageBuilder.Presence.editors(shared) |> inspect() =~ "@"
    end

    test "a stale or foreign session token falls back to a fresh session", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?session=nosuchtokenatall")

      assert token(view) =~ ~r/^[a-z0-9]{32}$/
      assert node_with_tag(view, "h1")
    end

    test "initials come from the email's local part" do
      alias MishkaCmsCore.Runtime.PageBuilder.Presence

      assert Presence.initials(%{email: "ada.lovelace@example.com"}) == "AL"
      assert Presence.initials(%{email: "boss@example.com"}) == "B"
      assert Presence.initials(%{email: "a_b_c@example.com"}) == "AB"
      assert Presence.initials(%{}) == "?"
    end
  end

  describe "autosave, history counter and revert" do
    # The prototype puts no counter chip in the bar — the position lives in the undo button's own
    # tooltip, where it explains what that click will do, and in the Record-history sheet.
    test "the undo button reports position and total", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert view |> element("#pb-undo") |> render() =~ "0/0"

      h1 = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      assert view |> element("#pb-undo") |> render() =~ "1/1"

      undo!(view)
      assert view |> element("#pb-undo") |> render() =~ "0/1"
    end

    test "revert restores the document to a history entry", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(view, "h1")

      _flushed = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "history"})
      render_async(view)

      # By the row's own id, not by its position: the sheet pages and filters, so an index would be
      # a different change on a different screen.
      render_click(view, "history_revert", %{"id" => newest_history_row(page).id})
      _recorded = render_async(view)

      assert node_with_tag(view, "h1")
    end

    # A CHANGE IS THE TRIGGER, not a clock. It writes a DRAFT and never the live row: a live write
    # enqueues a compile job and would push half-finished work to visitors as it was being made.
    test "a change writes a draft and leaves the live page alone", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "auto"
      })

      _written = render_async(view)

      {:ok, live_page} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      refute live_page.template =~ ~s(class="auto")

      {:ok, drafts} =
        MishkaCmsCore.Runtime.PageDraft
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read(page: [limit: 10])

      draft = Enum.find(drafts.results, &(&1.source_page_id == page.id))
      assert draft
      assert draft.template =~ ~s(class="auto")
      assert String.starts_with?(draft.label, "Draft · "), draft.label
    end

    test "an autosaved draft is reachable at its shareable preview URL", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      send(view.pid, :autosave)

      _saved = render_async(view)

      # The shareable link lives behind the Preview caret now, with the other ways of looking at the
      # page, instead of a lone tick in the top bar that said nothing about what it did.
      html = render(view)

      assert html =~ "/_preview/page/"
      assert has_element?(view, "#pb-preview-tab")
    end

    test "a clean session does not autosave", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      send(view.pid, :autosave)
      _rendered = render_async(view)

      refute has_element?(view, "#pb-preview-tab")
    end
  end

  describe "the Studio, Assets and Review sheets" do
    # These assert the SHIPPED SAMPLE catalogue, so they name the adapter that provides it rather
    # than depending on which one happens to be the default. The real default reads the kits on
    # disk — covered separately below.
    setup do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)
      :ok
    end

    test "Studio opens on Tokens and shows a real generated export", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      html = render(view)
      assert html =~ "Studio"
      assert html =~ "Iris"
      assert html =~ "theme.colors.iris"

      # The generated file names itself on the shut drawer, and the drawer holds the real thing —
      # the fold is a JS toggle, so the source is rendered whether or not it is on screen.
      assert html =~ "tailwind.config.js"
      assert has_element?(view, "#pb-token-export-body.hidden")
      assert html =~ "module.exports = {"
    end

    test "switching the export format regenerates the file", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      view |> element("#pb-tokfmt-css") |> render_click()
      html = render(view)
      assert html =~ ":root {"
      assert html =~ "--iris: #5b57d6;"
      assert html =~ "tokens.css"

      view |> element("#pb-tokfmt-ex") |> render_click()
      assert render(view) =~ "defmodule MishkaWeb.Theme do"
    end

    test "the Studio has all five tabs and a scope filter", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      for tab <- ~w(tokens presets snippets registry settings) do
        assert has_element?(view, "#pb-studio-#{tab}")
      end

      html = render(view)
      assert html =~ "Design tokens"
      assert html =~ "One source of truth"

      # The scope filter belongs to the two tabs that list things you can own — asking "Downloaded"
      # of the site's own tokens means nothing.
      refute has_element?(view, "#pb-studio-scope-downloaded")

      view |> element("#pb-studio-registry") |> render_click()
      assert has_element?(view, "#pb-studio-scope-downloaded")
      assert render(view) =~ "1 installed"
    end

    # Custom tokens are the ones this site added on top of the kit, and the row says so.
    # The prototype's switches are decoration; these are the site's own settings, so a flick has to
    # survive the next read.
    test "a Studio option toggle writes the site's setting", %{conn: conn, page: page, site: site} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      refute MishkaCmsCore.Settings.get("studio.dark_pair", false, site.id) == true

      view |> element("#pb-studio-opt-studio\\.dark_pair") |> render_click()

      assert MishkaCmsCore.Settings.get("studio.dark_pair", false, site.id) == true

      assert view |> element("#pb-studio-opt-studio\\.dark_pair") |> render() =~
               "aria-checked=\"true\""
    end

    test "the registry source is stored, not just displayed", %{
      conn: conn,
      page: page,
      site: site
    } do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      view
      |> form("#pb-registry-source-form", %{"registry" => %{"source" => "hex.pm/chelekom"}})
      |> render_change()

      assert MishkaCmsCore.Settings.get("studio.registry_source", nil, site.id) ==
               "hex.pm/chelekom"
    end

    # A licence token is a credential: the field shows what is stored and refuses to take a new one
    # here, because this editor is not where a secret should be typed.
    test "the licence field is read-only and points at Settings", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      html = view |> element("#pb-license-token") |> render()
      assert html =~ "readonly"
      assert render(view) =~ "Not connected"
    end

    # WHICHEVER TOKENS THIS SITE IS BEING SHOWN, read through the same function the sheet reads.
    # `Marketplace.tokens(nil)` is a different list: it asks the adapter for the GLOBAL set, while
    # the Studio asks `studio_token_list/1` for the site's own and falls back to the adapter only
    # when the site declares none. They agree today because this block forces the sample adapter,
    # and they stop agreeing the moment the fixture grows a stylesheet.
    test "a custom token is marked and an unused one is called out", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      shown = Panels.studio_token_list(page.site_id)

      # The list pages at 30, so a token is reached by narrowing rather than by scrolling — which is
      # what the Custom chip is for.
      view |> element("#pb-tokcat-custom") |> render_click()

      custom = Enum.find(shown, & &1.custom?)

      assert custom, "the sheet is showing no custom token, so there is nothing to mark"
      assert view |> element("#pb-token-#{custom.key}") |> render() =~ "Custom"

      unused = Enum.find(shown, &(&1.usage == 0))

      if unused do
        # Narrow to its own category for the same reason: one page is 30 rows.
        view |> element("#pb-tokcat-#{unused.category}") |> render_click()
        assert view |> element("#pb-token-#{unused.key}") |> render() =~ "Unused"
      end
    end

    # The row shows what Copy would actually give you, so it follows the selected format.
    #
    # WHICH TOKENS EXIST IS NOT THIS TEST'S BUSINESS. It named `iris` from the sample set, which the
    # Studio shows only while the site declares none of its own — so it passed or failed on whether
    # some earlier test had left a theme stylesheet behind, and reported that as a formatting bug.
    # The subject is the FORMAT, so it reads whichever token is listed and follows that one.
    test "a token's reference follows the export format", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      assert [_match, key] = Regex.run(~r/theme\.colors\.([a-z0-9-]+)/, render(view))

      view |> element("#pb-tokfmt-css") |> render_click()
      html = render(view)

      assert html =~ "--#{key}"
      refute html =~ "theme.colors."
    end

    # ONLY THE LIST WAITS. The sheet's own skeleton note promises that "the tabs and the filters
    # above are real and clickable from the first frame" — and the chips ARE filters. They used to
    # be drawn only in the table's LOADED state, so every first read blinked the whole row out and
    # put it back: a jump in the one part of the sheet that was meant not to move.
    #
    # ASKED OF THE LOADING STATE DIRECTLY, because it cannot be caught from the outside. Two waits
    # are stacked here — the sheet's own `:studio_data`, then the table's first read — so the frame
    # `render_click` returns is the sheet's skeleton with no table in it at all, and the one frame
    # that matters is gone by the time any assertion can look at it.
    test "the loading state draws the chips beside the shape of the list" do
      skeleton =
        %{
          state: %{path_params: %{token_categories: [{"all", "All", 3}, {"color", "Color", 2}]}},
          myself: nil,
          __changed__: nil
        }
        |> MishkaCmsCoreWeb.Templates.StudioTokens.render_loading()
        |> rendered_to_string()

      assert skeleton =~ "pb-token-skel-1", "the list still waits as a shape"
      assert skeleton =~ ~s(id="pb-tokcat-all")
      assert skeleton =~ ~s(id="pb-tokcat-color")
    end

    # A TABLE WITH NO STATE AT ALL is what the renderer draws on the very first paint, before it has
    # one to hand over. Nothing to count is not a crash.
    test "and draws none when there is no state to read them from" do
      skeleton =
        %{state: nil, myself: nil, __changed__: nil}
        |> MishkaCmsCoreWeb.Templates.StudioTokens.render_loading()
        |> rendered_to_string()

      assert skeleton =~ "pb-token-skel-1"
      refute skeleton =~ "pb-tokcat-"
    end

    test "tokens group under category headings with counts", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      assert has_element?(view, "#pb-tokcat-all")
      assert has_element?(view, "#pb-tokcat-color")

      view |> element("#pb-tokcat-color") |> render_click()
      html = render(view)
      assert html =~ "Ink"
      # Narrowed to one category, the others are gone.
      refute html =~ "Tight"
    end

    test "Settings names the licence, the source and the theme options", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-settings") |> render_click()

      html = render(view)
      assert html =~ "License token"
      assert html =~ "Not connected"
      assert html =~ "registry.mishka.tools"
      assert html =~ "Generate dark pair"
      assert html =~ "Lock tokens"
      # The scope filter belongs to the catalogues, not to settings.
      refute has_element?(view, "#pb-studio-scope-all")
    end

    # WHERE AN INSTALL LANDS. The Registry is the only surface in the admin that installs a package,
    # and it passed the editor's `site_id` unconditionally — a master could not share one across
    # sites, and nothing stopped a tenant's event asking for every site.
    test "a master is asked where, on the package they are installing", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-registry") |> render_click()
      _loaded = render_async(view)

      actor = :sys.get_state(view.pid).socket.assigns.current_user
      assert is_nil(actor.site_id), "this suite logs in a master"

      package = first_uninstalled_package(view)

      # The question is asked at the moment of installing: the menu ships folded, and Install is a
      # JS toggle of it — the choice is one click away and no round trip away.
      assert has_element?(view, "#pb-pkg-install-menu-#{package}.hidden")

      assert view |> element("#pb-pkg-install-#{package}") |> render() =~
               "#pb-pkg-install-menu-#{package}"

      assert has_element?(view, "#pb-pkg-install-site-#{package}")
      assert has_element?(view, "#pb-pkg-install-global-#{package}")
    end

    test "the menu belongs to one package, not the panel", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-registry") |> render_click()
      _loaded = render_async(view)

      package = first_uninstalled_package(view)

      # EACH PACKAGE OWNS ITS MENU. The button carries its own package's id, so one row's Install
      # cannot unfold another's — which is the whole reason the id is built from the package.
      assert has_element?(view, "#pb-pkg-install-menu-#{package}")

      assert view |> element("#pb-pkg-install-#{package}") |> render() =~
               "#pb-pkg-install-menu-#{package}"
    end

    # THE GUARD, not the control. A tenant never sees the buttons, so the only way to exercise this
    # is the way an attacker would: send the event anyway. A REAL tenant session, because the actor
    # is what the guard reads — standing the assign down in the process is not the same thing, and
    # an earlier version of this test did that and passed while proving nothing.
    test "a tenant's forged global install is refused", %{conn: conn, page: page, site: site} do
      tenant = create_admin("tenant@example.com", site.id)
      assert tenant.site_id == site.id

      {:ok, view, _html} = conn |> log_in(tenant) |> open_builder(page)
      view |> element("#pb-studio") |> render_click()
      view |> element("#pb-studio-registry") |> render_click()

      assert has_element?(view, "#pb-studio-registry"), "the Registry tab is open"

      refute has_element?(view, "#pb-pkg-install-menu-chelekom-alert"),
             "a tenant is not offered the choice in the first place"

      render_click(view, "install_package", %{"package" => "chelekom-alert", "scope" => "global"})

      assert render(view) =~ "cannot install for that site"
    end

    # The registry lists whatever the kits on disk have not installed yet, so the fixture cannot name
    # a package — it reads the first one the panel actually drew an Install button for.
    defp first_uninstalled_package(view) do
      view
      |> render()
      |> then(&Regex.run(~r/id="pb-pkg-install-([a-z0-9-]+)"/, &1))
      |> case do
        [_full, id] -> id
        nil -> flunk("the Registry drew no Install button to click")
      end
    end

    test "switching tab resets the category filter", %{conn: conn, page: page} do
      view = open_studio(conn, page)
      view |> element("#pb-tokcat-color") |> render_click()

      # "color" means nothing to a package, so carrying it across would hide the catalogue.
      view |> element("#pb-studio-registry") |> render_click()
      assert render(view) =~ "Chelekom Datatable"
    end

    # Save → list → insert → delete, through the panel's own controls. The snippet store is the one
    # place in the Studio holding THIS install's content rather than a registry's, so the round trip
    # is what proves it: a saved snippet has to come back as an ordinary insert.
    test "a snippet saves what is selected and inserts it back", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "insert",
        "parent_id" => "root",
        "index" => "0",
        "template" => "<section id=\"kept\">Say hello</section>"
      })

      placed =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.tag == "section"))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-studio") |> render_click()
      view |> element("#pb-studio-snippets") |> render_click()

      # The markup rides in on a hidden input that `Panels` associates with the form by id, so it
      # stays fresh as the canvas changes without rebuilding the form under a half-typed name.
      assert render(view) =~ ~s(form="pb-snippet-form")

      view
      |> element("#pb-snippet-form")
      |> render_submit(%{
        "form" => %{
          "name" => "Greeting block",
          "source" => ~s(<section id="kept">Say hello</section>),
          "visibility" => "page"
        }
      })

      html = render_async(view)
      assert html =~ "Greeting block"
      # Blocks and size are read off the markup, not stored beside it.
      assert html =~ "1 block ·"

      [snippet] = saved_snippets(site, page)

      render_click(view, "op", %{"kind" => "delete", "node_id" => placed.id})
      view |> element("#pb-snippet-insert-#{snippet.id}") |> render_click()

      assert editor_html(view) =~ "Say hello"
      # It went through history, so it is undoable like any other insert.
      refute editor(view).past == []

      view |> element("#pb-snippet-delete-#{snippet.id}") |> render_click()
      assert saved_snippets(site, page) == []
    end

    # The scope used to be decided FOR the author — a selection saved `:page`, a whole page saved
    # `:shared`, and there was no way to say otherwise. Now the radio decides, and "All sites" is a
    # `site_id` choice rather than a third `scope`.
    test "the author chooses who a snippet is for", %{conn: conn, page: page, site: site} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-snippets") |> render_click()

      save = fn name, visibility ->
        view
        |> element("#pb-snippet-form")
        |> render_submit(%{
          "form" => %{
            "name" => name,
            "source" => "<section>#{name}</section>",
            "visibility" => visibility
          }
        })
      end

      save.("Beside this page", "page")
      save.("Across this site", "shared")
      save.("Everywhere", "global")

      stored =
        site
        |> saved_snippets(page)
        |> Map.new(&{&1.name, &1.scope})

      assert stored["Beside this page"] == "This page"
      assert stored["Across this site"] == "Shared"

      # "All sites" is the one choice that is not a `scope` at all: it writes a nil `site_id`, which
      # `scope_label/1` reads back as "All sites". Every default is merged over a blank param, so
      # the editor's site deliberately does NOT travel under that name — see `editor_site_id`.
      assert stored["Everywhere"] == "All sites"
      assert has_element?(view, "#pb-snippet-scope-global")
    end

    # A `:page` snippet with no document to sit beside is unreachable forever, so the choice is not
    # offered rather than offered and quietly ignored.
    test "there is no This page choice until there is a page", %{conn: conn, page: page} do
      {:ok, new_view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")
      new_view |> element("#pb-studio") |> render_click()
      new_view |> element("#pb-studio-snippets") |> render_click()

      refute has_element?(new_view, "#pb-snippet-scope-page")
      assert has_element?(new_view, "#pb-snippet-scope-shared")

      view = open_studio(conn, page)
      view |> element("#pb-studio-snippets") |> render_click()

      assert has_element?(view, "#pb-snippet-scope-page")
    end

    # A name is the only thing the author supplies, so an empty one has to say so rather than write a
    # row nobody can find again.
    test "saving a snippet without a name says so", %{conn: conn, page: page, site: site} do
      view = open_studio(conn, page)
      view |> element("#pb-studio-snippets") |> render_click()

      view
      |> element("#pb-snippet-form")
      |> render_submit(%{"form" => %{"name" => "  ", "source" => "<section>x</section>"}})

      assert render(view) =~ "Give the snippet a name first."
      assert saved_snippets(site, page) == []
    end

    test "the Studio tabs show presets, the registry and snippets", %{conn: conn, page: page} do
      view = open_studio(conn, page)

      view |> element("#pb-studio-presets") |> render_click()
      assert render(view) =~ "Commerce Pro"

      view |> element("#pb-studio-registry") |> render_click()
      html = render(view)
      assert html =~ "Chelekom Datatable"
      assert html =~ "Installed"

      view |> element("#pb-studio-snippets") |> render_click()
      # The list is a Gervaz table now, so its empty state appears once the read has actually come
      # back — not as markup that was always there and merely hidden.
      assert render_async(view) =~ "No snippets saved yet."
    end

    # Presets and packages come from the configured adapter, and the shipped one is a SAMPLE. A card
    # that looks installable next to an Install button that refuses is the demo lying about itself,
    # so the two tabs that show adapter data say where it comes from. Tokens and snippets do not —
    # they are this site's own.
    test "the sample catalogue says it is one, on the tabs that show it", %{
      conn: conn,
      page: page
    } do
      view = open_studio(conn, page)

      view |> element("#pb-studio-presets") |> render_click()
      assert has_element?(view, "#pb-sample-catalogue")

      view |> element("#pb-studio-registry") |> render_click()
      assert has_element?(view, "#pb-sample-catalogue")

      view |> element("#pb-studio-tokens") |> render_click()
      refute has_element?(view, "#pb-sample-catalogue")

      view |> element("#pb-studio-snippets") |> render_click()
      refute has_element?(view, "#pb-sample-catalogue")
    end

    # THE SHEET IS THE MEDIA SYSTEM. Not a hand-rolled mirror of it: the browse half is
    # `MishkaGervaz.Table.Web.Live` on `Runtime.Media` with the resource's own MediaGallery template,
    # and the upload half is `MishkaGervaz.Form.Web.Live`, which registers its own `allow_upload`.
    test "Assets mounts the Gervaz gallery and the Gervaz upload form", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_media!(site_id: site.id, name: "brochure")

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      assert has_element?(view, "#pb-assets-gallery"), "the library is Gervaz's table"
      assert has_element?(view, "#pb-media-upload"), "uploading happens here, not on another page"
      assert render(view) =~ "brochure"
    end

    # The dropzone, the accept list, the size limit, the progress bar and the write all belong to
    # Gervaz's `uploads do … style :dropzone … end` block on the resource. Registering a second
    # uploader for the same name here would be a second media system.
    test "the upload half is Gervaz's, uploader and all", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      assert render(view) =~ "drag and drop", "Gervaz's own dropzone copy"

      refute :sys.get_state(view.pid).socket.assigns[:uploads],
             "BuilderLive must not register an uploader of its own"
    end

    # An `image_url` attribute is not a link an author types — it is a file in this site's library. The
    # library is browsable on its own, so the pick has to say who it is picking FOR, and the answer
    # has to land on the attribute that asked.
    test "an image attribute picks from the library and writes what it picked", %{
      conn: conn,
      page: page,
      site: site
    } do
      media_id =
        create_media!(site_id: site.id, name: "hero-shot", relative_path: "/uploads/hero.png").id

      create_component!(
        site_id: site.id,
        name: "banner-box",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-banner-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The library has no Use button until something is choosing.
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)
      refute has_element?(view, "#pb-media-target")

      view |> element("#pb-attr-pick-image_url") |> render_click()
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "Choosing for"
      assert html =~ "image_url"

      # AND HOW. Naming the target and stopping there left the reader in front of a grid of files
      # with a tick box on each, and the tick box is for Archive and Featured — it picks nothing.
      assert html =~ "press <b>Use</b> on a file below"

      # The Use button is the resource's own row action, rendered by the Gervaz gallery. It reaches
      # this LiveView as `{:row_action, "use_media", %{"id" => id}}`.
      html = render(view)

      assert html =~ "editor_pick_node" or html =~ "Use",
             "the gallery must offer the editor's own action while something is choosing"

      send(view.pid, {:row_action, "use_media", %{"id" => media_id}})
      _rendered = render(view)

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Node.attr_text("image_url") ==
               "/uploads/hero.png"

      # The sheet closes and stops offering to pick, so browsing later writes nothing.
      refute has_element?(view, "#pb-media-target")
    end

    # A BROKEN GLYPH IS NOT AN ANSWER. A media field whose path points at nothing drew the browser's
    # own torn-page icon, which says the same thing about a deleted file, a mistyped name and a URL
    # that was never right. Reported alongside "can we put an image inside a card?" — the card was
    # fine; the path in it was not, and nothing on screen said so.
    test "a media field says when its path loads nothing", %{conn: conn, page: page, site: site} do
      html = media_field_html(conn, page, site, "shot-a", "/uploads/gone.png")

      assert html =~ "Nothing loads from this path"

      assert html =~ ~s(phx-hook="MediaThumb"),
             "without the hook the sentence never gets uncovered"
    end

    # And a half-typed value is not worth a box at all — an empty frame appearing under every
    # keystroke reads as something failing.
    test "and draws no preview box for a value that is not a path yet", %{
      conn: conn,
      page: page,
      site: site
    } do
      refute media_field_html(conn, page, site, "shot-b", "upl") =~ "Nothing loads from this path"
    end

    # A WRONG DOOR IS WORSE THAN A LOCKED ONE. The sheet listed every file whatever was asking, so
    # pressing Use on the first card put `/uploads/documents/10.docx` into an `<img src>` — taken
    # without complaint and drawn on the page as a broken picture. `type` is a Media attribute, so it
    # filters the gallery through the same channel `site_id` already rides.
    test "picking for a picture shows only pictures", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "shot-c",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-shot-c") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})
      _loaded = render_async(view)

      assert :sys.get_state(view.pid).socket.assigns.media_target.accepts == :images
      assert media_filter(view)[:type] == :images
    end

    # `<video src>` is not a picture, and hiding every video from the one field that takes one would
    # be the same fault pointing the other way.
    test "and picking for something that plays does not", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><video src="/a.mp4"></video></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      video = node_with_tag(view, "video")

      render_click(view, "pick_media", %{"node_id" => video.id, "name" => "src"})
      _loaded = render_async(view)

      assert :sys.get_state(view.pid).socket.assigns.media_target.accepts == :any
      refute Map.has_key?(media_filter(view), :type)
    end

    # The still frame on a video IS a picture — the exception inside the exception.
    test "and a video's poster is a picture again", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><video src="/a.mp4"></video></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      video = node_with_tag(view, "video")

      render_click(view, "pick_media", %{"node_id" => video.id, "name" => "poster"})
      _loaded = render_async(view)

      assert media_filter(view)[:type] == :images
    end

    # A background is always a picture.
    test "and a background is a picture too", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      root = view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) |> List.first()

      render_click(view, "pick_background", %{"node_id" => root, "bucket" => "desktop"})
      _loaded = render_async(view)

      assert media_filter(view)[:type] == :images
    end

    # What the gallery is actually scoped by, read where the sheet hands it over.
    defp media_filter(view) do
      view
      |> render()
      |> then(fn _html -> :sys.get_state(view.pid).socket.assigns end)
      |> then(&MishkaCmsCoreWeb.Live.Admin.Builder.Panels.media_scope_params/1)
    end

    # AND THE BOX SAYS WHAT IT TAKES. Every length field said "unset", so an author who typed a bare
    # number, got pixels, and had no reason to try anything else reported the fields as pixels-only.
    test "a length field says it takes any length", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      root = view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) |> List.first()

      render_click(view, "select", %{"id" => root})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert view |> element("#pb-style-base-width") |> render() =~ "any length, e.g. 2rem"
    end

    # Opacity is a NUMBER, not a length — telling somebody to type `2rem` into it would be wrong.
    test "and a field that is not a length does not", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      root = view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) |> List.first()

      render_click(view, "select", %{"id" => root})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute view |> element("#pb-style-base-opacity") |> render() =~ "any length"
    end

    # NOTHING VANISHES WITHOUT A REASON. A master's library read excludes files whose site is switched
    # off, so editing a page that belongs to such a site shows an empty sheet however many files that
    # site really has. An empty shelf with no notice reads as a bug — or as files somebody deleted.
    #
    # The admin itself stays reachable because it is served on the MASTER host, which is active;
    # `SiteLookupPlug` 503s a disabled site's OWN host, so this case only arises for a master editing
    # somebody else's site — which is exactly what `?site_id=` exists for.
    test "the Assets sheet says when the edited site is switched off", %{conn: conn} do
      n = System.unique_integer([:positive])
      off = create_site!(name: "off-#{n}", host: "off-#{n}.test", active: false)
      page = create_page!(site_id: off.id)
      create_media!(site_id: off.id, name: "kept-while-off")

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: off.id,
        name: off.name,
        host: off.host,
        priority: off.priority,
        active: false,
        master: off.master
      })

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{off.id}")

      _loaded = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      assert has_element?(view, "#pb-assets-site-off")
      assert render(view) =~ "Its files are here for you to work with"
      assert render(view) =~ "kept-while-off", "the master still works with the site's own files"
    end

    # A GLOBAL DOCUMENT IS RENDERED BY EVERY SITE, so its gallery offers only files of sites that are
    # up: an inactive or offline site's file would not load for anyone else.
    test "a global document offers only files of sites that are up", %{conn: conn, site: site} do
      n = System.unique_integer([:positive])
      off = create_site!(name: "off-#{n}", host: "off-#{n}.test", active: false)
      quiet = create_site!(name: "quiet-#{n}", host: "quiet-#{n}.test", active: true)
      Enum.each([off, quiet], &cache_site/1)
      {:ok, _} = MishkaCmsCore.Settings.put("cms.offline", true, site_id: quiet.id)

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SettingsState.delete(quiet.id, "cms.offline")
      end)

      create_media!(site_id: site.id, name: "shared-hero")
      create_media!(site_id: off.id, name: "switched-off-hero")
      create_media!(site_id: quiet.id, name: "offline-hero")

      component =
        create_component!(name: "global-banner-#{n}", site_id: nil, template: "<p>hi</p>")

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      render_click(view, "open_sheet", %{"sheet" => "assets"})
      html = render_async(view)

      assert html =~ "shared-hero"
      refute html =~ "switched-off-hero"
      refute html =~ "offline-hero"
    end

    test "and says nothing of the sort while the site is on", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      refute has_element?(view, "#pb-assets-site-off")
    end

    # UPLOADING DURING A PICK IS PICKING. Something asked for a file, which is the only reason the
    # reader opened the library and uploaded at all — and then the sheet stayed open, said
    # "Uploaded", and left them to find the card they had just made and press Use on it.
    test "a file uploaded while something is picking is used straight away", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "shot-up",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-shot-up") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})
      _loaded = render_async(view)

      picture =
        create_media!(
          site_id: site.id,
          name: "just-uploaded",
          type: :images,
          relative_path: "/uploads/new.png"
        )

      send(view.pid, {:form_saved, :create, picture})
      html = render(view)

      assert html =~ "and used it"

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Node.attr_text("image_url") == "/uploads/new.png"

      refute has_element?(view, "#pb-media-target"), "the sheet stayed open after answering"
    end

    # A file the field cannot show is NOT placed, and says so: the gallery is filtered to what the
    # field accepts, so a document uploaded during a picture pick vanishes from the grid the moment
    # it saves — uploaded, invisible, and apparently lost.
    test "and one the field cannot show is kept but not used", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "shot-doc",
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-shot-doc") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick_media", %{"node_id" => placed.id, "name" => "image_url"})
      _loaded = render_async(view)

      doc =
        create_media!(
          site_id: site.id,
          name: "a-contract",
          type: :documents,
          relative_path: "/uploads/deal.pdf"
        )

      send(view.pid, {:form_saved, :create, doc})
      html = render(view)

      assert html =~ "is a document"
      assert html =~ "saved in the library"

      refute view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Node.attr_text("image_url") == "/uploads/deal.pdf"
    end

    # With nothing picking, an upload is just an upload.
    test "and an upload with nothing picking only reports itself", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      shot = create_media!(site_id: site.id, name: "idle-upload")

      send(view.pid, {:form_saved, :create, shot})
      html = render(view)

      assert html =~ "Uploaded"
      refute html =~ "and used it"
    end

    # A component with one media attribute: placed, selected, given a value, Inspector rendered.
    defp media_field_html(conn, page, site, name, value) do
      create_component!(
        site_id: site.id,
        name: name,
        attrs: [%{"name" => "image_url", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-#{name}") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "image_url",
        "value" => value
      })

      render(view)
    end

    test "Assets says so plainly when the library is empty", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "Assets"

      # The sheet's own words, because its empty state is a folder rather than a whole library: the
      # rail may be sitting on one that happens to have nothing in it.
      assert html =~ "No files in this folder yet"
    end

    # THE SHEET IS A FOLDER RAIL AND A GRID, and the rail is what answers the question the library's
    # Type and Site filters answer on a page — which is why the sheet draws neither.
    test "Assets has a folder rail and only search above the grid", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      html = render_async(view)

      assert html =~ ~s(data-role="pb-assets-folders")
      assert html =~ ~s(id="pb-folder-all")
      assert html =~ ~s(id="pb-assets-search")

      refute html =~ "All types", "the library's Type filter is a page control, not a sheet one"
    end

    test "choosing a folder scopes the grid to it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      refute :sys.get_state(view.pid).socket.assigns.assets_category

      render_click(view, "select_asset_category", %{
        "id" => "6c5cf4ee-0000-4000-8000-000000000001"
      })

      assert :sys.get_state(view.pid).socket.assigns.assets_category ==
               "6c5cf4ee-0000-4000-8000-000000000001"

      # …and "All files" puts it back, rather than filtering for a folder called "__all__".
      render_click(view, "select_asset_category", %{"id" => "__all__"})
      refute :sys.get_state(view.pid).socket.assigns.assets_category
    end

    # The library's own filters and pagination come with the Gervaz table; the sheet does not
    # reimplement folders. What it DOES own is the scope: an editor only ever browses its own site.
    test "Assets shows this site's library and not another's", %{
      conn: conn,
      page: page,
      site: site
    } do
      other = create_site!()
      create_media!(site_id: site.id, name: "ours-hero")
      create_media!(site_id: other.id, name: "theirs-hero")

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "ours-hero"
      refute html =~ "theirs-hero"
    end

    test "Review names what a comment would be anchored to", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = render(view)
      assert html =~ "Commenting on"
      assert html =~ "h1"
    end

    # A NOTE IS A ROW NOW, not a list on the editing session. What is pinned here is what
    # gets STORED, because that is what has to survive the session: the element it was anchored to,
    # the label captured beside it, its type, and who wrote it.
    test "posting a note anchors it to the selection and stores what it was about", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Tighten this heading", "bug")

      [comment] = notes(site, page)
      assert comment.body == "Tighten this heading"
      assert comment.node_id == h1.id
      assert comment.node_label == "h1"
      assert comment.type == :bug
      assert comment.status == :open
      assert comment.author_type == :human
      assert comment.author_id, "a human note records who wrote it"
    end

    # A COMPOSER THAT KEEPS THE NOTE YOU JUST POSTED IS BROKEN. The form has no `phx-change`, so
    # LiveView does not own its inputs and cannot clear them; changing `defaults` rebuilds it, and
    # the revision on `defaults` is what changes after a write.
    test "the composer resets after a note is posted", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      before = :sys.get_state(view.pid).socket.assigns.review_revision
      post_note(view, "First note", "bug")

      assert :sys.get_state(view.pid).socket.assigns.review_revision > before,
             "the revision is what rebuilds the composer"
    end

    # The same code path with nothing selected. One nullable column is the whole difference.
    test "a note left with nothing selected is about the whole page", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Needs a meta description", "task")

      [comment] = notes(site, page)
      assert comment.node_id == nil
      assert comment.node_label == nil
      assert comment.type == :task
    end

    test "the composer offers every note type, in the order a note's types are named", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_async(view)

      offered =
        view
        |> element("#pb-comment-type")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("option")
        |> LazyHTML.attribute("value")

      assert offered == Enum.map(MishkaCmsCore.Runtime.PageComment.types(), &to_string/1)
    end

    test "an empty note posts nothing and says so", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "   ", "information")

      assert notes(site, page) == []
      assert render(view) =~ "Write something first."
    end

    # Resolving records WHO and WHEN, together or not at all.
    test "resolving a note records the resolver, and reopening clears them", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Fix the spacing", "bug")

      [comment] = notes(site, page)

      # The event, not the button: one button carries BOTH, swapping its `phx-click` when the note's
      # status changes, and `element/2` renders from the HTML the client last applied a diff to — so
      # clicking it twice in a row sends "resolve" twice.
      assert has_element?(view, "#pb-comment-resolve-#{comment.id}")
      render_click(view, "resolve_comment", %{"id" => comment.id})

      [resolved] = notes(site, page)
      assert resolved.status == :resolved
      assert resolved.resolved_at
      assert resolved.resolved_by_id, "who closed it is the thing a thread is asked a week later"

      render_click(view, "reopen_comment", %{"id" => comment.id})

      [reopened] = notes(site, page)
      assert reopened.status == :open
      refute reopened.resolved_at

      refute reopened.resolved_by_id,
             "'resolved by X' on an open note is a claim that is not true"
    end

    test "a note can be deleted", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Never mind", "other")

      [comment] = notes(site, page)
      assert has_element?(view, "#pb-comment-delete-#{comment.id}")
      render_click(view, "delete_comment", %{"id" => comment.id})

      assert notes(site, page) == []
    end

    # THE OPEN / ALL CHIPS ARE A REAL FILTER, not decoration. They used to push Gervaz's `filter`
    # event at a resource that declared no filters, so the handler reduced over an empty list and
    # returned the map it started with — a silent no-op that looked exactly like a working control.
    test "the Open and All chips actually narrow the thread", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Still needs doing", "task")
      post_note(view, "Already handled", "bug")

      handled = Enum.find(notes(site, page), &(&1.body == "Already handled"))
      render_click(view, "resolve_comment", %{"id" => handled.id})
      _flushed = render(view)

      # All — nothing filtered, both notes.
      view |> element("#pb-review-all") |> render_click()
      _loaded = render_async(view)
      all = render(view)
      assert all =~ "Still needs doing"
      assert all =~ "Already handled"

      # Open — the resolved one goes.
      view |> element("#pb-review-open") |> render_click()
      _loaded = render_async(view)
      open = render(view)
      assert open =~ "Still needs doing"
      refute open =~ "Already handled"
    end

    # FIFTY AT A TIME, then more on demand. `keep_loaded_records true` is what makes "more" ACCUMULATE
    # — it re-reads pages 1..N in one query rather than replacing the list with page N — and the
    # button is gated on `has_more?`, which is the only field that is right during a load.
    test "the thread pages fifty at a time and loads more on demand", %{
      conn: conn,
      page: page,
      site: site
    } do
      for n <- 1..62 do
        MishkaCmsCore.Runtime.PageComment
        |> Ash.Changeset.for_create(
          :create,
          %{
            body: "Note number #{n}",
            type: :information,
            section: :page,
            document_id: page.id
          },
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()
      end

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      _loaded = render_async(view)

      cards = fn html ->
        html |> String.split(~s(<article id="pb-comment-)) |> length() |> Kernel.-(1)
      end

      first = render(view)
      assert cards.(first) == 50, "one page is fifty"
      assert first =~ "pb-review-more", "there is more, so it has to be offered"

      view |> element("#pb-review-more") |> render_click()
      _loaded = render_async(view)

      second = render(view)
      assert cards.(second) == 62, "load-more accumulates rather than replacing the page"
      refute second =~ "pb-review-more", "and stops offering once there is nothing left"
    end

    # THE COUNTER IS UNRESOLVED BUGS AND IT IS DERIVED. Every one of the four things that can
    # change it is exercised here, because a hard-coded counter passes any test that only creates.
    test "the Review badge counts unresolved bugs, and only those", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      assert review_badge(view) == nil

      render_click(view, "open_sheet", %{"sheet" => "review"})

      # A note that is not a bug does not move it.
      post_note(view, "Looks good", "information")
      assert review_badge(view) == nil

      post_note(view, "Broken on mobile", "bug")
      post_note(view, "Overlaps the footer", "bug")
      assert review_badge(view) == "2"

      bug = Enum.find(notes(site, page), &(&1.type == :bug))

      render_click(view, "resolve_comment", %{"id" => bug.id})
      assert review_badge(view) == "1"

      render_click(view, "reopen_comment", %{"id" => bug.id})
      assert review_badge(view) == "2"

      render_click(view, "delete_comment", %{"id" => bug.id})
      assert review_badge(view) == "1"
    end

    # WHO MAY CLOSE A NOTE, and — since a shared document became a master's to open — who may reach
    # the thread at all. `PageComment` will only accept a site-less note on a section that can BE
    # site-less, so a shared note lives on a shared component or a shared layout and nowhere else;
    # and those are the two documents a tenant is now turned away from. The thread is a master's,
    # entirely, and the door is where that is decided rather than the button inside it.
    #
    # The reader who is refused is told what happened, which is the part worth pinning: silence here
    # reads as a broken link. `MishkaCmsCoreWeb.Test.EditorTenancyTest` covers the rule in full.
    test "a shared component's review thread is not a tenant's to reach", %{
      conn: conn,
      site: site
    } do
      component = create_component!(name: "shared-box", template: ~s(<div>shared</div>))

      {:ok, note} =
        MishkaCmsCore.Runtime.PageComment
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            body: "Broken for everyone",
            type: :bug,
            section: :component,
            document_id: component.id
          },
          authorize?: false
        )
        |> Ash.create()

      assert is_nil(note.site_id), "the note under test has to be the shared kind"

      tenant_conn = log_in(build_conn_for_host(), create_admin("tenant@example.com", site.id))

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(tenant_conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert to == "/admin/dashboard/runtime/components"
      assert flash["error"] =~ "shared with every site"

      # And the master, who does open it, is offered the button the tenant was not.
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      _thread = render_async(view)

      html = render(view)
      assert html =~ "Broken for everyone"
      assert html =~ "pb-comment-resolve-#{note.id}"
      refute html =~ "Master closes this"
    end

    # A NOTE'S ID IS NOT AUTHORITY. The three note handlers take `phx-value-id` straight from the
    # client, and the write behind them read the TENANT off the note it was handed — so a
    # site-scoped admin's Delete ran under the VICTIM's tenant, which satisfied `TenantContext`, the
    # multitenancy filter and the policy alike. Nothing downstream could tell. Scoped by who is
    # asking now, the way `delete_snippet` has always been.
    test "a tenant cannot reach another site's note by typing its id", %{conn: conn, site: site} do
      other_site = create_site!(name: "elsewhere", host: "elsewhere.test")
      foreign_page = create_page!(site_id: other_site.id, name: "their-page", path: "/their-page")

      {:ok, foreign_note} =
        MishkaCmsCore.Runtime.PageComment
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            body: "A private note on another site",
            type: :bug,
            section: :page,
            document_id: foreign_page.id,
            site_id: other_site.id
          },
          authorize?: false
        )
        |> Ash.create()

      own_page = create_page!(site_id: site.id, name: "our-page", path: "/our-page")
      tenant = create_admin("tenant-notes@example.com", site.id)
      {:ok, view, _html} = open_builder(log_in(build_conn_for_host(), tenant), own_page)

      for event <- ~w(resolve_comment reopen_comment delete_comment) do
        render_click(view, event, %{"id" => foreign_note.id})
      end

      assert {:ok, survivor} =
               Ash.get(MishkaCmsCore.Runtime.PageComment, foreign_note.id,
                 action: :get_any,
                 authorize?: false
               )

      assert survivor.status == :open, "#{survivor.status}: another site's note was resolved"
      refute survivor.resolved_by_id

      # Their OWN site's notes are still theirs to resolve and delete — the writes run under the
      # domain's authorization now rather than with it turned off, so this is what says the policy
      # lets a site admin through.
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Ours to close", "task")
      [mine] = notes(site, own_page)

      render_click(view, "resolve_comment", %{"id" => mine.id})
      assert [%{status: :resolved}] = notes(site, own_page)

      render_click(view, "delete_comment", %{"id" => mine.id})
      assert notes(site, own_page) == []

      # And the master, whose notes these are to manage, still deletes it.
      {:ok, master_view, _html} = open_builder(conn, foreign_page)
      render_click(master_view, "delete_comment", %{"id" => foreign_note.id})

      assert {:error, _gone} =
               Ash.get(MishkaCmsCore.Runtime.PageComment, foreign_note.id,
                 action: :get_any,
                 authorize?: false
               )
    end

    # WHICH EDITOR AM I IN, AND WHOSE DOCUMENT IS THIS. Four sections share one address shape, one
    # chrome and — until this — one title. A tab strip with a page, its layout and a component open
    # read "Page Builder" three times, and nothing anywhere on the component editor said whether the
    # row being changed belonged to this site or to every site.
    test "the header names the section it is editing, not always the page", %{conn: conn} do
      component = create_component!(name: "shared-box", template: ~s(<div>shared</div>))

      {:ok, _view, html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert html =~ "Component builder"
      refute html =~ "Page Builder"
      assert html =~ "shared-box.heex"
    end

    test "a site-less component is badged Global, a site's own is badged by name", %{
      conn: conn,
      site: site
    } do
      shared = create_component!(name: "shared-box", template: ~s(<div>shared</div>))
      owned = create_component!(name: "own-box", site_id: site.id, template: ~s(<div>own</div>))

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{shared.id}")

      assert has_element?(view, "[data-role=pb-scope]", "Global")

      {:ok, mine, _html} = live(conn, "/admin/dashboard/runtime/builder/component/#{owned.id}")

      assert has_element?(mine, "[data-role=pb-scope]", site.name)
      refute has_element?(mine, "[data-role=pb-scope]", "Global")
    end

    test "a layout editor says layout and a page editor still says page", %{
      conn: conn,
      site: site,
      page: page
    } do
      layout = create_layout!(name: "shell", site_id: site.id, template: ~s(<div>{@inner}</div>))

      {:ok, _layout_view, layout_html} =
        live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert layout_html =~ "Layout builder"

      {:ok, _page_view, page_html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert page_html =~ "Page builder"
    end

    # THE HANDOVER. The ring is client state, so a frame that has just mounted has none — even when
    # the session it mounted from has had something selected all along. The server has to say what
    # is selected, once, on the root; without it the toolbar renders (the server knows) and the hook
    # hides it again (no node carries the ring), which reads as "selected, but no toolbar".
    test "the canvas is told what is already selected when it mounts", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(data-selection="#{h1.id}")
      assert html =~ "pb-el-toolbar", "the bar the ring is drawn for"
    end

    # …and re-asking for the selection the session already holds must still tell the client. That is
    # exactly what a review note about the selected element does.
    test "selecting the already-selected element still announces it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      render_click(view, "select", %{"id" => h1.id})

      assert_push_event(canvas, "pb:selected", %{id: id})
      assert id == h1.id
    end

    # MOVING AN IFRAME RELOADS IT — a browser rule, not a LiveView one. The flash used to be two
    # top-level `:if` divs, so showing one INSERTED a sibling before the page, LiveView shifted the
    # tree under it, and the canvas was thrown away and fetched again on every "Saved" and every
    # "Note posted". A wrapper that is always there means notices come and go INSIDE it.
    test "the flash wrapper is present even with nothing to say", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ ~s(id="mishka-flash")
      refute html =~ ~s(id="flash-info"), "nothing to show yet"

      # …and it is the same wrapper once there is something in it.
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Something to say", "information")

      posted = render(view)
      assert posted =~ ~s(id="mishka-flash")
      assert posted =~ ~s(id="flash-info")

      # The notice dismisses itself, client-side — the hook is what carries the clock.
      assert posted =~ ~s(phx-hook="FlashAutoDismiss")
      assert posted =~ ~s(data-dismiss-after)
    end

    # A NOTE IS NOT A DOCUMENT CHANGE. Notes ride the session topic so both editors' sheets follow
    # each other, but re-reading the session in the canvas rebuilds the whole document — which the
    # author sees as the page flashing every time anyone types a comment.
    # The canvas must not so much as LOOK at the session for a review message. Comparing the tree
    # afterwards proves nothing — re-reading gives an equal tree — so this proves it by making the
    # read impossible: with the session gone, anything that re-reads it flips the frame to
    # "expired", and ignoring the message leaves the canvas exactly as it was.
    test "a review message does not make the canvas re-read the session", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      token = token(view)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token}")

      refute :sys.get_state(canvas.pid).socket.assigns.missing?

      MishkaCmsCore.Runtime.States.EditorSessionState.delete(token)

      send(canvas.pid, {:builder_session, token, {:review, :changed}})
      _rendered = render(canvas)
      refute :sys.get_state(canvas.pid).socket.assigns.missing?, "a note is not a document change"

      # …and anything that IS a document change still is.
      send(canvas.pid, {:builder_session, token, {:op_applied, :insert}})
      _rendered = render(canvas)
      assert :sys.get_state(canvas.pid).socket.assigns.missing?
    end

    # REPLIES. The shape is `MishkaBlog.Comment`'s — a nullable self-reference and its reverse — and
    # so is the move: Reply seeds the composer's `defaults` with the parent rather than opening a
    # second form.
    test "replying threads the answer under the question", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Is this heading final?", "question")
      [question] = notes(site, page)

      # MOVE THE SELECTION FIRST. A reply anchored to whatever happens to be selected when Reply is
      # pressed would file the answer against a different element than the question — and with the
      # selection left on the h1 the two answers are the same string, so the test could not tell.
      elsewhere = node_with_tag(view, "p")
      render_click(view, "select", %{"id" => elsewhere.id})

      # Arming a reply changes what the composer says it is doing.
      armed = render_click(view, "reply_to_comment", %{"id" => question.id})
      assert armed =~ "Replying to"
      assert armed =~ "Post reply"
      assert armed =~ "pb-comment-cancel-reply"

      post_note(view, "Yes, signed off yesterday", "information")

      # The thread still holds ONE note: the answer is under the question, not beside it.
      assert [threaded] = notes(site, page)
      assert threaded.id == question.id
      assert [reply] = threaded.replies
      assert reply.body == "Yes, signed off yesterday"
      assert reply.parent_comment_id == question.id

      # …and it inherited what the question was about, not whatever is selected now.
      assert reply.node_id == h1.id
      assert reply.node_label == "h1"

      # Posting it ends reply mode.
      assert render(view) =~ "Commenting on"
    end

    test "cancelling a reply goes back to writing a new note", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "A question", "question")

      [question] = notes(site, page)
      assert render_click(view, "reply_to_comment", %{"id" => question.id}) =~ "Replying to"
      assert render_click(view, "cancel_reply", %{}) =~ "Commenting on"
    end

    # A reply answers a note that already has a type; letting it carry its own would double-count it
    # in the badge.
    test "a reply is not a bug of its own", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Broken here", "bug")

      [bug] = notes(site, page)
      assert review_badge(view) == "1"

      render_click(view, "reply_to_comment", %{"id" => bug.id})
      post_reply(view, "Fixing it now")

      assert review_badge(view) == "1", "a reply must not add to the count"
      assert [%{replies: [reply]}] = notes(site, page)
      assert reply.type == :information
    end

    test "the answers are drawn under the question", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "The question", "question")

      [question] = notes(site, page)
      render_click(view, "reply_to_comment", %{"id" => question.id})
      post_note(view, "The answer", "information")

      html = render_async(view)
      assert html =~ "The question"
      assert html =~ "The answer"
      assert [%{replies: [reply]}] = notes(site, page)
      assert html =~ "pb-comment-#{reply.id}"
    end

    # NAMING SOMEBODY. The browser decides WHEN — it is the only thing that knows where the caret
    # is — so the search arrives as a hook push rather than a click.
    test "typing @ offers the people who can be named", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      assert render_hook(view, "mention_search", %{"q" => "bo"}) =~
               ~s(data-handle="boss@example.com")

      refute render_hook(view, "mention_search", %{"q" => "zz"}) =~ "pb-mention-list"
    end

    # PICKING IS THE BROWSER'S — it owns the caret, the arrow keys and the highlight. What the server
    # has to put in the markup is what the hook reads: the handle, and a row that starts highlighted.
    test "the list carries what the keyboard picks with", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = render_hook(view, "mention_search", %{"q" => "bo"})

      assert html =~ ~s(data-handle="boss@example.com")
      assert html =~ ~s(data-index="0")
      assert html =~ ~s(data-active="true")
    end

    test "leaving the word closes the list", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      assert render_hook(view, "mention_search", %{"q" => ""}) =~
               ~s(data-handle="boss@example.com")

      refute render_hook(view, "mention_close", %{}) =~ ~s(data-handle="boss@example.com")
    end

    # BEING NAMED IS ADDRESSED TO YOU, so your own chip is the filled one. The handle is the email's
    # local part, so the reader of this test IS `@boss`.
    test "your own name is drawn differently from anybody else's", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = post_note(view, "@boss@example.com and @someone@else.test", "information")

      assert html =~ ~s(data-role="pb-mention-self")
      assert html =~ "boss@example.com — this is you"
      assert html =~ ~s(data-role="pb-mention")
    end

    # A NAME IN A NOTE IS DRAWN AS ONE. Segments rather than injected markup, so this also pins that
    # a body is still text: the chip is a span the template made, not something the body said.
    test "a name in a note is drawn as a chip", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = post_note(view, "@boss@example.com please look at <b>this</b>", "question")

      assert html =~ ">@boss@example.com</span>"
      refute html =~ "<b>this</b>", "a body is text, not markup"
    end

    # THE ANCHOR HAS TO SURVIVE THE PARSE THAT WROTE IT. Node ids are minted per parse, so a
    # colleague reading the note in their own session computes a different id for the same element —
    # and the note used to tell them the element was gone. The stored path is what both of them agree
    # on.
    test "a note's element can be found from another session", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About this heading", "question")

      [note] = notes(site, page)
      assert note.node_path, "an element note has to record where the element sits"

      {:ok, other, _html} = open_builder(colleague(conn), page)
      their_h1 = node_with_tag(other, "h1")

      assert their_h1.id != note.node_id,
             "two sessions mint different ids; without that this proves nothing"

      render_click(other, "open_sheet", %{"sheet" => "review"})
      render_click(other, "goto_comment", %{"id" => note.id})

      assert editor(other).selection == their_h1.id
      refute render(other) =~ "no longer on this page"
    end

    # The path is a position, and a position is only right if what sits there is still the same kind
    # of thing. Deleting an element slides its neighbour into that index.
    test "a note does not select whatever slid into its place", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About this heading", "question")

      [note] = notes(site, page)

      {:ok, other, _html} = open_builder(colleague(conn), page)
      render_click(other, "op", %{"kind" => "delete", "node_id" => node_with_tag(other, "h1").id})
      render_click(other, "open_sheet", %{"sheet" => "review"})
      render_click(other, "goto_comment", %{"id" => note.id})

      assert render(other) =~ "no longer on this page"
    end

    # A NOTE ABOUT THE PAGE, WITH SOMETHING SELECTED. The composer follows the canvas, which is right
    # nearly always and wrong exactly when the thing to be said is about the page rather than the
    # element under the cursor. Deselecting to say it would lose the place you were working in.
    test "the scope can be cleared to the whole page without deselecting", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      assert render(view) =~ "pb-comment-whole-page"

      cleared = render_click(view, "comment_on_page", %{})
      refute cleared =~ "pb-comment-whole-page", "there is nothing left to clear"

      post_note(view, "About the page as a whole", "information")

      assert [note] = notes(site, page)
      refute note.node_id, "the note is about the page, not the element still selected"
      refute note.node_path
      assert editor(view).selection == h1.id, "clearing the scope must not clear the canvas"
    end

    # …and choosing another element is choosing what the next note is about, so the override ends.
    test "selecting an element takes the composer back off the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(view, "comment_on_page", %{})

      refute render(view) =~ "pb-comment-whole-page"

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})

      # The composer REBUILDS when what it is about changes, and a rebuilt Gervaz form draws its
      # skeleton until it has loaded.
      html = render_async(view)

      assert html =~ "pb-comment-whole-page"
      assert html =~ "&lt;p&gt;"
    end

    # A LOCAL PART IS NOT A NAME. Two people called `master` are two people, and a byline reading
    # "master" says which of them wrote this to nobody.
    test "the byline is the whole address", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      html = post_note(view, "Mine", "information")

      assert html =~ ">boss@example.com<"
      refute html =~ ">boss<"
    end

    # A MASTER'S ADDRESS IS NOT A TENANT'S TO HAVE. The masters work across every site on the
    # deployment, so putting one's email in a customer's sidebar hands them the platform's own
    # contact details. The activity feed already draws this line; the thread draws it too.
    test "a tenant sees a master's note without seeing the master", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Written by a master", "information")

      tenant_conn = log_in(build_conn_for_host(), create_admin("tenant@example.com", site.id))
      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})

      theirs_html = render_async(theirs)
      [note] = notes(site, page)

      assert theirs_html =~ "Written by a master", "the note itself is theirs to read"
      assert byline(theirs, note) == {"M", "Master"}
      refute theirs_html =~ "boss@example.com"
      refute theirs_html =~ ">boss<", "not even the local part"

      # …and a master reading the same note sees the whole address.
      assert byline(view, note) == {"B", "boss@example.com"}
    end

    test "a site admin reads a master named in a note as @Master", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_admin("other.master@platform.test")
      create_admin("named-tenant@example.com", site.id)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "@other.master@platform.test and @named-tenant@example.com look", "task")
      [note] = notes(site, page)

      tenant_conn = log_in(build_conn_for_host(), create_admin("reader@example.com", site.id))
      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})
      render_async(theirs)

      assert note_mentions(theirs, note) == ["@Master", "@named-tenant@example.com"]
      refute render(theirs) =~ "other.master"

      assert note_mentions(view, note) == [
               "@other.master@platform.test",
               "@named-tenant@example.com"
             ]
    end

    test "a site admin sees who resolved a note, and a master only as Master", %{
      conn: conn,
      page: page,
      site: site
    } do
      tenant = create_admin("resolver-tenant@example.com", site.id)
      tenant_conn = log_in(build_conn_for_host(), tenant)

      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})
      post_note(theirs, "Raised by the site", "bug")
      [note] = notes(site, page)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(view, "resolve_comment", %{"id" => note.id})
      render_async(view)

      assert byline(view, note) == {"RT", "resolver-tenant@example.com"}
      assert resolver_line(view, note) =~ "Resolved by boss@example.com"

      {:ok, theirs, _html} = open_builder(tenant_conn, page)
      render_click(theirs, "open_sheet", %{"sheet" => "review"})
      render_async(theirs)

      assert byline(theirs, note) == {"RT", "resolver-tenant@example.com"}
      assert resolver_line(theirs, note) =~ "Resolved by Master"
      refute render(theirs) =~ "boss@example.com"
      refute render(theirs) =~ ">boss<"
    end

    # MOTION IN BOTH DIRECTIONS. An overlay gated by `:if` is gone from the DOM the instant the assign
    # flips, so a CSS leave transition never gets a frame — `phx-remove` is what makes LiveView hold
    # the node back and run the commands first. Without it the close is the one that snaps, and it is
    # the one nobody notices is missing until it is there.
    test "the sheet arrives and leaves with motion", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render_click(view, "open_sheet", %{"sheet" => "review"})

      assert html =~ ~s(id="pb-sheet")
      assert html =~ "phx-mounted"
      assert html =~ "phx-remove"
      assert html =~ "duration-200", "the enter"
      assert html =~ "duration-150", "and the leave"
    end

    # PREVIEW IS A TOGGLE, and the caret only exists where there is a second way. A page with no
    # draft has none, and a caret with nothing behind it turns one click into a choice.
    test "preview has no caret without a draft to share", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      assert html =~ ~s(id="pb-preview")
      refute html =~ ~s(id="pb-preview-menu")
      refute html =~ ~s(id="pb-preview-tab")
    end

    test "preview still toggles between the editor and the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      refute editor(view).preview?

      render_click(view, "toggle_preview", %{})
      assert editor(view).preview?

      render_click(view, "toggle_preview", %{})
      refute editor(view).preview?
    end

    # A draft has a URL somebody who is not editing can open, so it — and only it — gets the caret.
    test "a shareable draft gets a caret with the link behind it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      autosave!(view)

      html = render(view)
      assert html =~ ~s(id="pb-preview-menu")

      opened = render(view)
      assert opened =~ ~s(id="pb-preview-tab")
      assert opened =~ "Open in a new tab"
      assert opened =~ "The shareable link"
      assert opened =~ ~s(target="_blank")

      # …and the link is a link, not a way of changing what the button does.
      refute editor(view).preview?
    end

    # A DESCRIPTION GOES UNDER THE TITLE. Beside it the two ran together into one line that read as
    # neither, so the markup has to put the label in a block of its own.
    test "a menu item's description sits under its title", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert [_all, between] = Regex.run(~r/Draft history(.*?)Open a saved draft/s, html)
      assert between =~ "</span>", "the title closes before the description starts"
      assert between =~ "block", "and the description is its own block"
    end

    # A note is only actionable if the reader can get to what it is about.
    test "a note's chip selects the element it was written about", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "Here", "suggestion")

      render_click(view, "select", %{"id" => nil})
      refute editor(view).selection

      [comment] = notes(site, page)
      render_click(view, "goto_comment", %{"id" => comment.id})

      assert editor(view).selection == h1.id
    end

    # And when it is not, that is a sentence rather than a crash. The id is the editor's own
    # handle, minted fresh by every parse, so it goes stale by construction.
    test "a note pointing at a deleted element says so instead of failing", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About this heading", "question")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      [comment] = notes(site, page)
      html = render_click(view, "goto_comment", %{"id" => comment.id})

      assert html =~ "no longer on this page"
    end

    test "a page-level note says it is about the page rather than going nowhere", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "About the page", "information")

      [comment] = notes(site, page)
      assert render_click(view, "goto_comment", %{"id" => comment.id}) =~ "the whole page"
    end

    # Nothing here implements AI review. What is pinned is that when something does, it is a
    # value in an existing column rather than a second comment system beside this one. The system
    # writes it through `:master_create`; the tenant `:create` takes no author from input.
    test "a note can be written by an AI or by the system", %{page: page, site: site} do
      for author_type <- [:ai, :system] do
        assert {:ok, comment} =
                 MishkaCmsCore.Runtime.PageComment
                 |> Ash.Changeset.for_create(
                   :master_create,
                   %{
                     body: "Contrast is below AA here",
                     type: :bug,
                     section: :page,
                     document_id: page.id,
                     site_id: site.id,
                     author_type: author_type
                   },
                   authorize?: false
                 )
                 |> Ash.create()

        assert comment.author_type == author_type
        assert comment.author_id == nil, "an AI or system note has no user row"
      end

      assert length(notes(site, page)) == 2
    end

    # Both browsers in a session share one document, so they share one thread — which is now true
    # because the thread is a table, not a copy of a list.
    test "a note posted in one session is visible to the other editor", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      token = token(view)

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{token}")

      render_click(second, "open_sheet", %{"sheet" => "review"})
      render_click(view, "open_sheet", %{"sheet" => "review"})

      post_note(view, "Seen by both", "information")

      [comment] = notes(site, page)
      assert comment.body == "Seen by both"

      # The second editor reads the same rows, so re-opening its sheet shows the note.
      render_click(second, "open_sheet", %{"sheet" => "review"})
      _loaded = render_async(second)
      assert render(second) =~ "Seen by both"
    end

    # TWO PEOPLE WHO EACH OPENED THIS PAGE FROM THE LIST share no session and no session topic — the
    # rows are the only thing they have in common. The thread follows them, on the resource's own
    # `pub_sub`, so a note arrives while the other editor is looking at it.
    test "a note reaches an editor in a session of their own", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, other, _html} = open_builder(colleague(conn), page)

      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(other, "open_sheet", %{"sheet" => "review"})

      assert token(view) != token(other),
             "two people editing one page have two sessions; without that this proves nothing"

      post_note(view, "Written next door", "information")

      # No click, no reload: the other editor's thread re-read on the broadcast alone.
      assert render_async(other) =~ "Written next door"
    end

    # The badge is a count of rows, so it has to move for the same reason the thread does.
    test "the bug counter follows somebody else's note", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, other, _html} = open_builder(colleague(conn), page)

      render_click(view, "open_sheet", %{"sheet" => "review"})
      assert review_badge(other) == nil

      post_note(view, "Broken next door", "bug")

      _settled = render_async(other)
      assert review_badge(other) == "1"
    end

    # A note about ANOTHER page arrives on the same topic — the topic knows only the site. The thread
    # would never SHOW it, because the read is scoped by document either way; what the check buys is
    # that a busy site does not make every open editor re-read for every note in it. So the thing to
    # assert is the work, not the words.
    test "a note about another page does not disturb this thread", %{
      conn: conn,
      page: page,
      site: site
    } do
      elsewhere = create_page!(site_id: site.id)
      {:ok, view, _html} = open_builder(conn, elsewhere)
      {:ok, other, _html} = open_builder(colleague(conn), page)

      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_click(other, "open_sheet", %{"sheet" => "review"})

      before = revision(other)
      post_note(view, "About the other page", "information")
      _settled = render_async(other)

      refute render(other) =~ "About the other page"

      assert revision(other) == before,
             "a note about another document must not cost this thread a read"
    end

    # OUR OWN NOTE COMES BACK TO US on the same topic everybody else hears it on. `refresh_review/1`
    # has already re-read, synchronously, so handling the echo as well would make the author pay for
    # every note twice — a second `:for_editor` read and a second `COUNT` for nothing.
    test "the author does not re-read their own note twice", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})

      before = revision(view)
      post_note(view, "Mine", "information")

      assert revision(view) == before + 1,
             "the write re-read the thread once; the broadcast must not re-read it again"
    end

    defp revision(view), do: :sys.get_state(view.pid).socket.assigns.review_revision

    # §Reply — the composer announces what it is for, so the caret has to be in it.
    test "replying puts the caret in the composer", %{conn: conn, page: page, site: site} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "review"})
      post_note(view, "A question", "question")

      [question] = notes(site, page)
      render_click(view, "reply_to_comment", %{"id" => question.id})

      assert_push_event(view, "gervaz:exec-js", %{target: "pb-comment-body", js: js})
      assert js =~ "focus"

      render_click(view, "cancel_reply", %{})
      assert_push_event(view, "gervaz:exec-js", %{target: "pb-comment-body"})
    end
  end

  describe "a layout, which is not a page with a header on it" do
    @body_layout ~s(<body class="min-h-screen bg-white"><main>{@inner_content}</main></body>)

    # A LAYOUT'S ROOT IS `<body>` — every one in this CMS opens with the element a page is wrapped in
    # — and a document may hold only one. The canvas is an ordinary document that already has a body,
    # so the parser merged the second one's attributes onto the first and dropped the tag: the node
    # the editor was pointing at was not in the frame at all. It looked right on the first render,
    # because the merge happened; every patch after that discarded the attributes outright.
    test "the root <body> is drawn as a container the frame can actually hold", %{
      conn: conn,
      site: site
    } do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      root = node_with_tag(view, "body")

      assert has_element?(canvas, ~s(div[data-node-id="#{root.id}"])),
             "the layout's root is selectable, draggable and stylable like any other container"

      refute has_element?(canvas, ~s(body[data-node-id="#{root.id}"])),
             "a second <body> is dissolved by the parser, taking the node with it"
    end

    # THE HALF THAT PROVES IT. Standing in for the tag is only worth anything if an edit to the root
    # now shows: the old behaviour recorded the override, wrote it into the saved template, and left
    # the frame exactly as it was — an editor that appears to ignore you.
    test "and recolouring that root reaches the frame", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      root = node_with_tag(view, "body")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => root.id,
        "bucket" => "base",
        "prop" => "background",
        "value" => "#ff0000"
      })

      assert canvas |> element(~s(div[data-node-id="#{root.id}"])) |> render() =~ "bg-[#ff0000]"

      # And the substitution is what the canvas draws, never what the document says.
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "<body"
    end

    # THE ONE THING A LAYOUT IS FOR. Take `@inner_content` out and the layout still compiles, saves
    # and previews — and every page wrapped in it serves this chrome with the page missing. The audit
    # said "0 blockers" over exactly that document.
    test "the audit names a layout that renders no page", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      view |> element("#pb-rail-audit") |> render_click()
      assert render(view) =~ "The page renders inside this layout"

      render_click(view, "op", %{"kind" => "delete", "node_id" => expression_node(view).id})

      html = render(view)
      assert html =~ "This layout renders no page"
      assert html =~ "every page on it loses its content"
    end

    test "a layout whose @inner_content is hidden from visitors is named, and not published",
         %{conn: conn, site: site} do
      template = ~s(<body><main>{@inner_content}</main></body>)
      layout = create_layout!(site_id: site.id, template: template)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "main").id
      })

      view |> element("#pb-rail-audit") |> render_click()
      assert render(view) =~ "@inner_content is inside an element hidden from visitors"

      publish!(view)

      assert flashes(view) =~
               "Not published — @inner_content is inside an element hidden from visitors"

      stored =
        Ash.get!(MishkaCmsCore.Runtime.Layout, layout.id, authorize?: false, tenant: site.id)

      assert stored.template == template
    end

    # A LAYOUT'S HEADINGS ARE HALF AN OUTLINE. Its h1 is the site name and its h3s label the footer;
    # the page's own headings land between them through `@inner_content`, so the `h1 → h3` it reads
    # as on its own is a gap the page fills. Every seeded layout wore the warning.
    test "no heading-order warning over an outline the page completes", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template:
            ~s(<body><h1>Site</h1><main>{@inner_content}</main><footer><h3>More</h3></footer></body>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)

      refute html =~ "Heading order skips a level"

      # And no tick either: "no level is skipped" is a claim about a document this rail is holding
      # half of, so it is withheld in both directions rather than only in the one that stings.
      refute html =~ "Heading order is sound"
      refute html =~ "Page opens at h1"
    end

    # And a page, which is a whole document, keeps it.
    test "while a page still gets one", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><h1>Top</h1><h3>Then</h3></div>))

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Heading order skips a level"
    end

    # Structure is a question only a layout has an answer to, so a page must not grow an empty
    # heading that reads as a check which failed to run.
    test "and says nothing of the kind on a page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-rail-audit") |> render_click()

      refute render(view) =~ "Structure"
    end

    # Publishing is the deliberate "make this live", and this one is already broken — the same
    # promise a required property makes, made by the section instead of by a component.
    test "publishing a layout that renders no page is refused", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      slot = expression_node(view)
      render_click(view, "op", %{"kind" => "delete", "node_id" => slot.id})

      assert publish!(view) =~ "Not published"

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Layout, layout.id, action: :master_get, authorize?: false)

      assert reloaded.template == @body_layout, "the live layout is untouched"
    end

    # The chip whose whole job is to say which document a save lands on called every one of them a
    # page, because the words were written into the markup.
    test "the stage chip names the layout rather than a page", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, _view, html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert html =~ "Live layout"
      refute html =~ "Live page"
    end
  end

  describe "what the canvas shows a run of text" do
    # `&copy;` is what a footer is written with, and a layout's footer is where it lives. Interpolated
    # it renders `&amp;copy;`, so the author read the six letters they typed while the published page
    # and the shareable preview both showed ©.
    test "a character reference is drawn as the character it names", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>&copy; 2026 &mdash; Mishka</p>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      paragraph = canvas |> element(~s(p[data-node-id])) |> render()

      assert paragraph =~ "© 2026 — Mishka"
      refute paragraph =~ "&amp;copy;", "the reference was shown as its own six letters"

      # And the document is untouched by any of that — the substitution is what the frame draws.
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~
               "&copy; 2026 &mdash; Mishka"
    end

    # THE BOX SAYS `plaintext-only` AND MEANT IT NOWHERE. The hook pushes `textContent`, so the three
    # characters that mean something to HTML arrived as the characters typed and went into the
    # template as markup: typing `<b>bold</b>` put a real element in the document, and the same
    # keystrokes could have put a `<script>` on a published page.
    test "typing stays text, whatever is typed", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>original</p>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(canvas, "set_text", %{"id" => text.id, "text" => "Fish & Chips <b>bold</b>"})

      saved = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()

      assert saved =~ "Fish &amp; Chips &lt;b&gt;bold&lt;/b&gt;"
      refute saved =~ "<b>", "typed characters became an element in the document"

      # And it comes back to the author as what they typed rather than as markup: the run is still one
      # text node, and no `<b>` was ever built from it.
      assert render(canvas) =~ "Fish &amp; Chips &lt;b&gt;bold&lt;/b&gt;"
      refute has_element?(canvas, ~s(span[data-kind="text"] b))
    end
  end

  describe "the controls a node can actually take" do
    # `{@inner_content}` is the one node every layout has and the first thing anyone clicks. The
    # Inspector offered it breakpoints, states, spacing, typography and the whole Appearance section
    # — and the serializer emits an expression verbatim, with nowhere to put a class, so every one of
    # those controls recorded an override that was dropped on the way out.
    test "an expression is not offered styling that would be dropped", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~s(<main class="wrap">{@inner_content}</main>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      render_click(view, "select", %{"id" => expression_node(view).id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, ~s([data-role="pb-bptabs"]))
      assert has_element?(view, "#pb-not-styleable")
      assert has_element?(view, "#pb-select-parent"), "and it says where the styling does belong"
    end

    test "nor is a run of text", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>words</p>))

      {:ok, view, _html} = open_builder(conn, page)

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(view, "select", %{"id" => text.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      assert has_element?(view, "#pb-not-styleable")
      assert render(view) =~ "double-click it on the canvas"
    end

    # A `<style>` renders nothing a visitor sees, so the style surface would record overrides for an
    # element that shows none of them. It is offered its attributes, the nonce it is saved with and
    # a way to where its rules belong instead.
    test "a style block is offered its attributes and where its rules belong", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<div><style>.x { color: red; }</style></div>))

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "style").id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, ~s([data-role="pb-bptabs"]))
      assert has_element?(view, "#pb-not-styleable")
      assert has_element?(view, "#pb-style-nonce-note")

      assert has_element?(
               view,
               ~s(#pb-raw-block-home[href="/admin/dashboard/runtime/stylesheets"])
             )

      refute has_element?(view, "#pb-css-toggle"), "it has no CSS box of its own"
      refute has_element?(view, "#pb-act-toggle"), "nothing to click"
      refute has_element?(view, "#pb-hook-toggle"), "nothing to hook"
      assert has_element?(view, "#pb-when-toggle"), "whether it renders is still a condition"
    end

    test "a script block points at JS hooks and is promised no nonce", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~S|<div><script>console.log(1)</script></div>|)

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "script").id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert has_element?(view, "#pb-not-styleable")
      refute has_element?(view, "#pb-style-nonce-note")
      assert has_element?(view, ~s(#pb-raw-block-home[href="/admin/dashboard/runtime/js-hooks"]))
    end

    # The element it sits in still gets everything, which is the half that proves the gate is about
    # the node rather than about the panel.
    test "the element around it still gets the whole surface", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>words</p>))

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, "#pb-not-styleable")
    end
  end

  describe "the other three sections" do
    test "a layout opens and saves through its own attribute", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~s(<main><p>Layout body</p>{@inner_content}</main>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert node_with_tag(view, "main")

      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => p.id,
        "name" => "class",
        "value" => "lead"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Layout, layout.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="lead")
    end

    test "a component opens and saves through its own attribute", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "editable-box",
          template: ~s(<div class="box"><span>Inside</span></div>)
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert has_element?(view, "#pb-root")
      assert view |> editor() |> Map.fetch!(:section) == "component"

      span = node_with_tag(view, "span")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => span.id,
        "name" => "class",
        "value" => "inner"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Component, component.id,
          action: :master_get,
          authorize?: false
        )

      assert reloaded.template =~ ~s(class="inner")
      assert reloaded.template =~ "Inside"
    end

    # An error page stores a LIST of per-status templates and has no `template` attribute at all, so
    # this is the section that would break if the editor assumed one document per record.
    test "an error page edits one status and writes it back into the list", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      # It opens on the 404 entry — the document itself lives in the canvas iframe, so the session
      # tree is where to look — and offers both statuses.
      assert editor_html(view) =~ "Not found"
      assert has_element?(view, "#pb-status-404")
      assert has_element?(view, "#pb-status-500")

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => hd(h1.children),
        "text" => "Missing"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      # Ash hands typed map entries back atom-keyed even when they were written with string keys.
      by_status =
        Map.new(reloaded.error_pages, fn entry ->
          {entry["status"] || entry[:status], entry["template"] || entry[:template]}
        end)

      assert by_status[404] =~ "Missing"
      # The other status must be untouched — saving one entry cannot clobber the list.
      assert by_status[500] =~ "Boom"
    end

    test "an error page can be opened directly on another status", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      assert editor_html(view) =~ "Boom"
      refute editor_html(view) =~ "Not found"
    end

    # The page an offline site shows is an entry of its own, beside the codes, addressed as
    # `?status=offline`. Read as a number, that address opened the 404 and published over it.
    test "the offline page opens on its own tab and publishes into its own entry", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => "offline", "template" => "<h1>Soon</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=offline")

      assert editor_html(view) =~ "Soon"
      refute editor_html(view) =~ "Not found"
      assert has_element?(view, "#pb-status-offline")

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => hd(h1.children),
        "text" => "Back later"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      by_status = Map.new(reloaded.error_pages, &{&1.status, &1.template})

      assert by_status[:offline] =~ "Back later"
      assert by_status[404] =~ "Not found"
    end

    # SWITCHING STATUS IS NOT OPENING ONE FRESH, and that is the whole difference. The tab strip is a
    # `navigate` link, so pressing 500 remounts — and a remount RESUMES the session this actor already
    # has open on this document, which is what stops a reload throwing work away. The session is keyed
    # on section, record and actor, so the status was not part of what it is a session FOR: the strip
    # lit 500, `@status` became 500, and the tree stayed the 404 one.
    test "and switching status inside an open session changes the document", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, first, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=404")

      assert editor_html(first) =~ "Not found"

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      assert editor_html(second) =~ "Boom"

      refute editor_html(second) =~ "Not found",
             "the strip said 500 and the canvas was still showing 404"
    end

    # SEO IS ADVICE ABOUT FIELDS THE RECORD HAS. `ErrorPage` declares no `seo_tags` at all, so the
    # group asked a 404 for a meta description, an Open Graph image and a 50–60 character title it
    # cannot hold — and "Meta description missing" is a BLOCKER, which made a perfectly good error
    # page the only red score ring in the editor.
    test "the audit asks an error page nothing about SEO", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      view |> element("#pb-rail-audit") |> render_click()
      html = render(view)

      refute html =~ "Meta description missing"
      refute html =~ "Open Graph image not set"
      refute html =~ "SEO &amp; Meta"

      # The outline IS its own, though — an error page is a whole document, not a fragment.
      assert html =~ "Heading order is sound" or html =~ "Heading order skips a level"
    end

    # And a page, which declares `seo_tags`, keeps the whole group — the gate is the resource's
    # fields, not a list of sections written down twice.
    test "while a page, which has those fields, still gets asked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-rail-audit") |> render_click()

      assert render(view) =~ "Open Graph image not set"
    end

    # AND THE COST OF GETTING IT WRONG, which is why this is not a cosmetic bug. `save_fields/3`
    # replaces the entry named by `@status` with whatever the tree serialises to — so a tree left over
    # from 404, saved while the strip reads 500, writes the 404 markup into the 500 entry and the real
    # 500 page is gone with nothing said.
    test "so publishing after a switch cannot write one status over another", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, _first, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=404")

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      publish!(second)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      by_status =
        Map.new(reloaded.error_pages, fn entry ->
          {entry["status"] || entry[:status], entry["template"] || entry[:template]}
        end)

      assert by_status[500] =~ "Boom", "the 404 tree was published over the 500 entry"
      assert by_status[404] =~ "Not found"
    end
  end

  # A READER HAS TO BE ABLE TO TELL THE TWO APART. A live component answers clicks and keeps
  # state between renders; a function component structurally cannot. Two cards, two rows and two
  # inspector panels that look identical are a choice the author cannot make, and they find out
  # which they picked by publishing.
  # AN AUTHOR WRITES THE COMPONENT'S OWN LIFECYCLE, in the editor, and it runs.
  #
  # This looks blocked, and the blocker is real for the question a page raises: a PAGE author
  # cannot target a component, because `@myself` is not in scope in a page template and the canvas
  # strips every `phx-*` written on a `<.component>` node. But that is not the question a
  # component's author asks. Inside the COMPONENT's own template `@myself` is in scope — that is what
  # compiling to a `Phoenix.LiveComponent` bought — so a component's handler has a door, and the
  # Helpers tab is where it is written.
  describe "writing a live component's lifecycle in the editor" do
    defp live_component!(site_id) do
      create_component!(
        name: "editable-live",
        site_id: site_id,
        stateful: true,
        template:
          ~s(<div id={@id} {@rest}><button phx-click="tick" phx-target={@myself}>go</button></div>),
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
      )
    end

    test "the Helpers tab says which three names are the lifecycle", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, live_component!(site.id))

      render_click(view, "source_tab", %{"tab" => "helpers"})

      assert has_element?(view, ~s([data-role="pb-lifecycle-note"])),
             "a live component's author is not told that handle_event is its own"

      html = render(view)
      assert html =~ "handle_event(name, params, socket)"
      assert html =~ "phx-target"
    end

    # AND A FUNCTION COMPONENT IS NOT TOLD SOMETHING UNTRUE. It has no lifecycle to write: a
    # `handle_event` on one is a plain function nothing will ever call.
    test "and a function component is not", %{conn: conn, site: site} do
      plain = create_component!(name: "editable-plain", site_id: site.id)
      {:ok, view} = open_component(conn, plain)

      render_click(view, "source_tab", %{"tab" => "helpers"})

      refute has_element?(view, ~s([data-role="pb-lifecycle-note"]))
    end

    # AND HOW FAR IT REACHES. A component's handler runs in whatever LiveView renders it, so a
    # global one's runs inside every tenant's page. Nothing scopes that — it is what shared means —
    # so it is said where the handler is written, and said only where it is true.
    test "a global one's note says its code runs on every site", %{conn: conn} do
      {:ok, view} = open_component(conn, live_component!(nil))

      render_click(view, "source_tab", %{"tab" => "helpers"})

      assert has_element?(
               view,
               ~s([data-role="pb-lifecycle-note"] [data-role="pb-lifecycle-shared"]),
               "runs on every site that places it"
             ),
             "a global live component's author is not told its handlers run on every site"
    end

    test "and one site's note does not", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, live_component!(site.id))

      render_click(view, "source_tab", %{"tab" => "helpers"})

      assert has_element?(view, ~s([data-role="pb-lifecycle-note"]))

      refute has_element?(view, ~s([data-role="pb-lifecycle-shared"])),
             "a component of one site was said to run on every site"
    end

    # THE ROUND TRIP. Written in the editor, stored on the row, and — because `Changes.SignCode` is
    # on the component's own update action and `Helper` now has somewhere to keep a signature —
    # stored SIGNED, which is what makes it run rather than compile to an inert clause.
    test "a handler written here is saved, and saved signed", %{conn: conn, site: site} do
      Application.put_env(:mishka_cms_core, :code_signing_key, "a-test-signing-key-long-enough")
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :code_signing_key) end)

      component = live_component!(site.id)
      {:ok, view} = open_component(conn, component)

      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> form("#pb-code-form", %{
        "tab" => "helpers",
        "entry" => %{
          "0" => %{
            "name" => "handle_event",
            "args" => ~s|"tick", _params, socket|,
            "code" => "{:noreply, socket}"
          }
        }
      })
      |> render_submit()

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)

      assert [helper] = stored.helpers
      assert helper.name == "handle_event"

      assert is_binary(helper.signature),
             "the handler was stored unsigned, so it would compile to an inert clause"

      assert MishkaCmsCore.Runtime.PageBuilder.CodeSignature.trusted?(helper)
    end
  end

  describe "which kind of component this is" do
    defp select_placed(view, name) do
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => name})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == name))

      assert placed, "#{name} was not placed"
      render_click(view, "select", %{"id" => placed.id})

      # THE INSPECTOR IS A TAB, and picking from the palette leaves the palette showing — a click on
      # the canvas is what swings the rail over. Asserting without this reads a panel that is not on
      # screen.
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      view
    end

    test "the palette marks a live one and leaves a plain one unmarked", %{
      conn: conn,
      page: page,
      site: site
    } do
      _live = create_component!(name: "live-card", site_id: site.id, stateful: true)
      _plain = create_component!(name: "plain-card", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s(#pb-comp-live-card [data-role="pb-livedot"])),
             "a live component's card said nothing about being live"

      refute has_element?(view, ~s(#pb-comp-plain-card [data-role="pb-livedot"]))
    end

    test "and the inspector says so over the selected one", %{
      conn: conn,
      page: page,
      site: site
    } do
      _live = create_component!(name: "live-selected", site_id: site.id, stateful: true)
      _plain = create_component!(name: "plain-selected", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      select_placed(view, "live-selected")

      assert has_element?(view, ~s([data-role="pb-insp-kind"])),
             "the inspector did not say the selected component keeps state"

      select_placed(view, "plain-selected")

      refute has_element?(view, ~s([data-role="pb-insp-kind"])),
             "a function component was labelled as live"
    end
  end

  # THE FLAG HAS TO SURVIVE THE PALETTE. The palette's query names its columns explicitly, and
  # an unselected attribute is not an error and is not `%Ash.NotLoaded{}` — the struct field reads
  # `nil`, which is falsy. Miss it and every component reads as stateless, no drop is ever given an
  # id, and a live component placed on a page raises in the visitor's LiveView instead.
  describe "a stateful component in the palette" do
    test "the entry carries the flag the row declared", %{conn: conn, page: page, site: site} do
      _live = create_component!(name: "live-thing", site_id: site.id, stateful: true)
      _plain = create_component!(name: "plain-thing", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      assert entry(view, "live-thing").stateful? == true
      assert entry(view, "plain-thing").stateful? == false
    end

    # AND A DROP OF ONE CARRIES AN ID. A `Phoenix.LiveComponent` cannot exist without one —
    # `Phoenix.LiveView.Diff` raises — so this is not a nicety the kit opts into by declaring an
    # `id` attr, which is the question asked of a function component.
    test "placing one mints an id even though it declares no id attr", %{
      conn: conn,
      page: page,
      site: site
    } do
      _live = create_component!(name: "live-drop", site_id: site.id, stateful: true)

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => "live-drop"})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "live-drop"))

      assert node, "the component was not placed"
      assert {:string, id} = Node.attr(node, "id")
      assert String.starts_with?(id, "phx-"), "got #{inspect(id)}"
    end

    # A FUNCTION COMPONENT IS UNCHANGED. Minting an id for one that declares nothing to read it
    # would put an attribute in the saved markup that no rule refers to.
    test "and a plain one that declares no id still gets none", %{
      conn: conn,
      page: page,
      site: site
    } do
      _plain = create_component!(name: "plain-drop", site_id: site.id)

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => "plain-drop"})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "plain-drop"))

      assert node, "the component was not placed"
      assert Node.attr(node, "id") == nil
    end
  end

  # §1 — THE TWO FIELDS A DOCUMENT IS MOST LIKELY TO HAVE WRONG on a first draft, changeable from
  # the one screen the author is actually on. Everything past the click is the resource's own Gervaz
  # form, so what is pinned here is which fields survive, that a save reaches the record, and that
  # the design the editor is holding does not move.
  describe "document settings" do
    defp settings_form(section), do: "#pb-settings-" <> section <> "-form"

    # Picks, in `form`, the kind of record each address of the page shows: `"__nil__"` for none.
    defp pick_kind(view, form, kind) do
      view |> element("#{form} input[name='_search_record']") |> render_focus()

      view
      |> element("#{form} [phx-click='relation_select'][phx-value-id='#{kind}']")
      |> render_click()

      view
    end

    # THE FORM LOADS ASYNCHRONOUSLY IN EDIT MODE and synchronously in create mode — Gervaz's
    # `DataLoader.load_record/3` is a `start_async`, `new_record/2` is not. So the essentials step
    # can be filled in the frame it opens on and this cannot: the frame `render_click` returns is a
    # spinner with no form in it, and a test that submitted straight into it passed or failed on how
    # warm the run was.
    defp open_settings(view) do
      view |> element("#pb-settings-open") |> render_click()
      _settled = render_async(view)
      view
    end

    defp reread!(resource, id) do
      resource
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!()
    end

    test "the header opens it, and General asks for the title and path; the description is on SEO",
         %{
           conn: conn,
           page: page
         } do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-settings-open")
      refute has_element?(view, "#pb-settings-modal")

      open_settings(view)

      form = settings_form("page")
      assert has_element?(view, "#pb-settings-modal")
      assert has_element?(view, "#{form} input[name='form[path]']")
      assert has_element?(view, "#{form} [name='form[title]']")
      refute has_element?(view, "#{form} [name='form[description]']")

      # THE SITE IS NOT ON OFFER. `update` accepts no `site_id` on any of these resources, so a
      # picker here would be a control that cannot do the thing it appears to.
      refute has_element?(view, "#{form} input[name='_search_site_id']")

      for absent <- ~w(template content extra schema seo_tags priority format active) do
        refute has_element?(view, "#{form} [name='form[#{absent}]']"),
               "#{absent} is not one of the document's settings"
      end
    end

    # WHO MAY OPEN THE PAGE is a page's alone among the documents a builder edits, and it is picked
    # from the permission names that exist rather than typed.
    test "a page picks who may open it; the other documents do not", %{conn: conn, page: page} do
      refute :permissions in Panels.settings_hidden_fields("page")
      assert :permissions in Panels.settings_hidden_fields("layout")

      {:ok, view, _html} = open_builder(conn, page)
      open_settings(view)

      assert has_element?(view, "#{settings_form("page")} [name='_search_permissions']")
    end

    test "a picked permission name is written to the page", %{conn: conn, page: page} do
      permission = create_permission!(name: "admin:dashboard:runtime:page")

      {:ok, view, _html} = open_builder(conn, page)
      open_settings(view)

      picker = "#multi-select-pb-settings-page-permissions"
      view |> element("#{picker} input[name='_search_permissions']") |> render_focus()
      view |> element("#{picker} [phx-value-id='#{permission.name}']") |> render_click()

      view |> form(settings_form("page")) |> render_submit()

      refute has_element?(view, "#pb-settings-modal")
      assert reread!(MishkaCmsCore.Runtime.Page, page.id).permissions == [permission.name]
    end

    test "un-picking the last permission name makes the page public again", %{
      conn: conn,
      site: site
    } do
      permission = create_permission!(name: "admin:dashboard:runtime:page")

      page =
        create_page!(site_id: site.id, template: @template, permissions: [permission.name])

      {:ok, view, _html} = open_builder(conn, page)
      open_settings(view)

      chips = "#multi-select-pb-settings-page-permissions [data-role='gervaz-multi-selected']"
      assert has_element?(view, chips, permission.name), "a page's permission is not shown"

      view |> element("#{chips} [aria-label='Remove #{permission.name}']") |> render_click()
      view |> form(settings_form("page")) |> render_submit()

      refute has_element?(view, "#pb-settings-modal")
      assert reread!(MishkaCmsCore.Runtime.Page, page.id).permissions == []
    end

    # THE LAYOUT A PAGE IS DRAWN IN is picked here, from the layouts its site may use, and the canvas
    # draws the page inside it — the layout's markup inert around it, the page's own nodes editable.
    test "the canvas draws the page inside the layout picked in its settings", %{
      conn: conn,
      site: site
    } do
      layout =
        create_layout!(
          site_id: site.id,
          name: "probe-shell",
          path: "/layouts/probe-shell",
          template: ~S|<header id="layout-probe">Shell</header><main>{@inner_content}</main>|
        )

      page = create_page!(site_id: site.id, template: @template, layout_id: layout.id)

      refute :layout_id in Panels.settings_hidden_fields("page")

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-layout-shell #layout-probe", "Shell")
      assert has_element?(canvas, "#pb-layout-shell main #pb-layout-slot [data-node-id]")

      open_settings(view)
      form = settings_form("page")
      view |> element("#{form} input[name='_search_layout_id']") |> render_focus()

      view
      |> element("#{form} [phx-click='relation_select'][phx-value-id='__nil__']")
      |> render_click()

      view |> form(form) |> render_submit()

      assert reread!(MishkaCmsCore.Runtime.Page, page.id).layout_id == nil
      refute has_element?(canvas, "#pb-layout-shell")
      assert has_element?(canvas, "#pb-canvas-root [data-node-id]")
    end

    # WHILE A DRAFT IS BEING WRITTEN, ITS SETTINGS ARE THE DRAFT'S. Publishing a draft writes every
    # field it carries over the page, so a setting saved to the page beside an open draft came back
    # undone when that draft was published.
    test "while a draft is being written, the settings are the draft's and the page keeps its own",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)
      assert is_binary(draft_id)

      open_settings(view)

      assert has_element?(view, "#pb-settings-draft-note")
      refute has_element?(view, settings_form("page"))

      view
      |> form(settings_form("page-draft"), %{"form" => %{"path" => "/drafted"}})
      |> render_submit()

      refute has_element?(view, "#pb-settings-modal")
      assert reread!(MishkaCmsCore.Runtime.PageDraft, draft_id).path == "/drafted"
      assert reread!(MishkaCmsCore.Runtime.Page, page.id).path == page.path
    end

    test "while a draft is being written, the kind its addresses show is the draft's", %{
      conn: conn,
      page: page
    } do
      register_plugin(MishkaCmsCoreWeb.Test.BuilderLiveTest.TestKinds, "runtime:page:records")

      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)

      open_settings(view)

      form = settings_form("page-draft")
      view |> pick_kind(form, "test:post") |> form(form) |> render_submit()

      assert reread!(MishkaCmsCore.Runtime.PageDraft, draft_id).extra["record"] == "test:post"
      refute Map.has_key?(reread!(MishkaCmsCore.Runtime.Page, page.id).extra || %{}, "record")
    end

    test "a session resumed inside its draft edits the draft's settings straight away", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      _draft_id = autosave!(first)

      {:ok, view, _html} = open_builder(conn, page)
      open_settings(view)

      assert has_element?(view, "#pb-settings-draft-note")
      assert has_element?(view, settings_form("page-draft"))
    end

    test "in Publish mode the settings are the page's, even with a draft beside it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)
      render_click(view, "set_stage", %{"stage" => "published"})

      open_settings(view)
      refute has_element?(view, "#pb-settings-draft-note")

      view
      |> form(settings_form("page"), %{"form" => %{"path" => "/published-path"}})
      |> render_submit()

      assert reread!(MishkaCmsCore.Runtime.Page, page.id).path == "/published-path"
      assert reread!(MishkaCmsCore.Runtime.PageDraft, draft_id).path == page.path
    end

    test "while a draft is being written, the canvas draws the draft's layout", %{
      conn: conn,
      site: site
    } do
      layout =
        create_layout!(
          site_id: site.id,
          name: "draft-shell",
          path: "/layouts/draft-shell",
          template: ~S|<header id="layout-probe">Shell</header>{@inner_content}|
        )

      page = create_page!(site_id: site.id, template: @template, layout_id: layout.id)

      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)

      open_settings(view)
      form = settings_form("page-draft")
      view |> element("#{form} input[name='_search_layout_id']") |> render_focus()

      view
      |> element("#{form} [phx-click='relation_select'][phx-value-id='__nil__']")
      |> render_click()

      view |> form(form) |> render_submit()

      assert reread!(MishkaCmsCore.Runtime.PageDraft, draft_id).layout_id == nil
      assert reread!(MishkaCmsCore.Runtime.Page, page.id).layout_id == layout.id

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      refute has_element?(canvas, "#pb-layout-shell")

      render_click(view, "set_stage", %{"stage" => "published"})
      assert has_element?(canvas, "#pb-layout-shell #layout-probe")
    end

    test "a new path is written to the page, and the header follows", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      open_settings(view)

      view
      |> form(settings_form("page"), %{"form" => %{"path" => "/renamed"}})
      |> render_submit()

      refute has_element?(view, "#pb-settings-modal"),
             "the modal stayed open over a save that worked"

      saved = reread!(MishkaCmsCore.Runtime.Page, page.id)
      assert saved.path == "/renamed"
      assert saved.title == page.title
      assert saved.name == page.name
      assert render(view) =~ "#{page.name}.heex"
    end

    # THE DESIGN IS NOT ON THIS RECORD as far as the modal is concerned — the working tree lives in
    # the editing session and is written by a draft save. A rename mid-edit that quietly published,
    # reverted or emptied the markup would be the worst possible shape for this feature.
    test "saving settings leaves the document alone", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = editor(view).tree

      open_settings(view)

      view
      |> form(settings_form("page"), %{"form" => %{"path" => "/still"}})
      |> render_submit()

      assert reread!(MishkaCmsCore.Runtime.Page, page.id).template == page.template
      assert editor(view).tree == before
    end

    # THE RESOURCE SAYS WHAT IS LEGAL. This adds no rules of its own, so a path the resource's
    # `PathFormat` refuses is refused here in the resource's own words and nothing is written.
    test "a path the resource refuses is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      open_settings(view)

      html =
        view
        |> form(settings_form("page"), %{"form" => %{"path" => "not-a-path"}})
        |> render_submit()

      assert html =~ "pb-settings-modal", "a refusal closed the modal and lost what was typed"
      assert reread!(MishkaCmsCore.Runtime.Page, page.id).path == page.path
    end

    # THE BADGE BESIDE THE TITLE READS `record.site.name`, and a Gervaz save answers with the row it
    # wrote and nothing loaded onto it — so assigning that record straight turned "localhost" into
    # "This site" on every save. Not a change of scope: the badge falling through to its last clause.
    test "the site the document belongs to is still named after a save", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, page)
      badge = "[data-role='pb-scope']"
      assert has_element?(view, badge, site.name)

      open_settings(view)

      view
      |> form(settings_form("page"), %{"form" => %{"path" => "/still-localhost"}})
      |> render_submit()

      assert has_element?(view, badge, site.name),
             "the scope badge stopped naming the site after a settings save"
    end

    test "closing it leaves the editor where it was", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      open_settings(view)
      assert has_element?(view, "#pb-settings-modal")

      view |> element("#pb-settings-close") |> render_click()
      refute has_element?(view, "#pb-settings-modal")
      assert has_element?(view, "#pb-settings-open")
    end

    # §2 — A LAYOUT IS THE SAME DOCUMENT WITH A DIFFERENT NOUN. The gate is asked of the resource's
    # own form, so nothing here is a second implementation — what is pinned is that the layout's
    # address really is reachable and really is written, and that a shared layout says so.
    test "a layout's path is changed the same way", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, path: "/layouts/first")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _settled = render_async(view)

      open_settings(view)

      form = settings_form("layout")
      assert has_element?(view, "#{form} input[name='form[name]']")
      assert has_element?(view, "#{form} input[name='form[path]']")

      view
      |> form(form, %{"form" => %{"path" => "/layouts/second"}})
      |> render_submit()

      refute has_element?(view, "#pb-settings-modal")
      assert reread!(MishkaCmsCore.Runtime.Layout, layout.id).path == "/layouts/second"
    end

    # A SITE-LESS LAYOUT IS EVERY SITE'S, and the badge beside the title says so. Renaming one is a
    # rename for thirty sites, so the thing worth pinning is that the badge still reads "Global"
    # afterwards — the same last-clause fallthrough the site badge had.
    test "a shared layout still says it is shared after a save", %{conn: conn} do
      layout = create_layout!(site_id: nil, path: "/layouts/shared")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _settled = render_async(view)

      badge = "[data-role='pb-scope']"
      assert has_element?(view, badge, "Global")

      open_settings(view)

      view
      |> form(settings_form("layout"), %{"form" => %{"path" => "/layouts/shared-still"}})
      |> render_submit()

      assert has_element?(view, badge, "Global")
      assert reread!(MishkaCmsCore.Runtime.Layout, layout.id).path == "/layouts/shared-still"
    end

    # AN ERROR PAGE OPENS THE SAME MODAL AND ITS PATH IS NOT ITS OWN — the address is written from
    # the site, so what is changeable here is the name. The address itself is pinned in "an error
    # page's address" below, which is where the rule lives.
    test "an error page's name is changed the same way", %{conn: conn, site: site} do
      error_page = create_error_page!(site_id: site.id)

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      _settled = render_async(view)

      open_settings(view)

      view
      |> form(settings_form("error-page"), %{"form" => %{"name" => "second-errors"}})
      |> render_submit()

      refute has_element?(view, "#pb-settings-modal")
      assert reread!(MishkaCmsCore.Runtime.ErrorPage, error_page.id).name == "second-errors"
    end

    # A COMPONENT IS REACHED BY NAME FROM THE MARKUP THAT CALLS IT, and that name is what its
    # compiled module is hashed from — so it has no address to change here, and renaming one is not
    # a settings change but a rename of every call site. `settings?/1` asks the resource's own form
    # whether it declares a path rather than naming the section.
    test "a component has no address, so there is nothing to open", %{conn: conn, site: site} do
      component = create_component!(site_id: site.id)

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _settled = render_async(view)

      refute Panels.settings?("component")
      refute has_element?(view, "#pb-settings-open")
    end

    # A DOCUMENT THAT DOES NOT EXIST YET HAS NOTHING TO CHANGE, and the essentials step in front of
    # it is asking for these same two fields.
    test "there is nothing to open before the document exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")

      refute has_element?(view, "#pb-settings-open")
      assert has_element?(view, "#pb-new-document")
    end
  end

  # THE SEO TAB of the same modal: the page's description, tags and schema, saved together, with
  # previews drawn from the head the page would render — see `MishkaCmsCore.Runtime.Seo`.
  describe "the SEO tab" do
    test "a page edits its description on the SEO tab alone; its title, which names it, on General" do
      page_hidden = Panels.settings_hidden_fields("page")

      refute :title in page_hidden
      assert :description in page_hidden
      refute :name in page_hidden
      refute :path in page_hidden

      refute :description in Panels.settings_hidden_fields("layout")
    end

    defmodule PostSeo do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "runtime:page:seo"

      @impl true
      def call(%{page: %{path: "/:lang/post-" <> _}} = seo),
        do: {:reply, %{seo | var_docs: [%{key: "post.title", label: "Post title"}]}}

      def call(seo), do: {:reply, seo}
    end

    # The tab is a Gervaz form, which reads its record asynchronously.
    defmodule TestKinds do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "runtime:page:records"

      @impl true
      def call(%{records: records} = state) do
        kinds = [
          %{
            id: "test:post",
            group: "Journal",
            label: "Entry",
            captures: ["slug"],
            samples: [%{label: "First entry · en", params: %{"slug" => "first", "lang" => "en"}}]
          },
          %{id: "test:tag", group: "Journal", label: "Topic", captures: ["slug"]},
          %{id: "other:issue", group: "Tracker", label: "Issue", captures: ["number"]}
        ]

        {:reply, %{state | records: records ++ kinds}}
      end
    end

    defmodule TestEntrySeo do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "runtime:page:seo"

      @impl true
      def call(%{record: "test:post", params: %{"slug" => slug}} = seo) do
        {:reply, :halt,
         %{
           seo
           | title: "Entry #{slug}",
             vars: %{"entry.title" => "Entry #{slug}"},
             var_docs: [%{key: "entry.title", label: "Entry title"}]
         }}
      end

      def call(%{record: "test:post"} = seo),
        do: {:reply, :halt, %{seo | var_docs: [%{key: "entry.title", label: "Entry title"}]}}

      def call(seo), do: {:reply, seo}
    end

    defp open_seo(view) do
      open_settings(view)
      view |> element("#pb-settings-tab-seo") |> render_click()
      _settled = render_async(view)
      view
    end

    # What the form sends when one field changes: every field as drawn, `_target` naming the one.
    defp seo_change(view, seo, target) do
      view
      |> form("#pb-seo-form", %{"seo" => seo})
      |> render_change(%{"_target" => ["seo" | target]})
    end

    defp seo_save(view), do: view |> form("#pb-seo-form") |> render_submit()

    defp seo_text(view, selector),
      do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

    defp stored_tag(record, attr, name) do
      Enum.find(record.seo_tags, &(Map.get(&1.attrs, attr) == name))
    end

    test "opens on a page beside General, its previews drawn from the page", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, title: "Our studio", template: @template)
      {:ok, view, _html} = open_builder(conn, page)

      open_settings(view)
      assert has_element?(view, "#pb-settings-tab-general[aria-selected='true']")
      refute has_element?(view, "#pb-seo-form")

      open_seo(view)

      assert has_element?(view, "#pb-settings-tab-seo[aria-selected='true']")
      assert has_element?(view, "#pb-seo-previews")
      assert has_element?(view, "#pb-seo-basics")
      assert has_element?(view, "#pb-seo-tags")
      assert has_element?(view, "#pb-seo-schema")
      assert seo_text(view, "#pb-seo-search-title") =~ "Our studio"
      assert seo_text(view, "#pb-seo-search-url") =~ site.host
      assert seo_text(view, "#pb-seo-share-title") =~ "Our studio"

      # General is hidden rather than removed, so what was typed in it is still there.
      assert has_element?(view, "#pb-settings-page-form")
    end

    test "the ••• menu opens the same settings straight on the SEO tab", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, title: "Our studio", template: @template)
      {:ok, view, _html} = open_builder(conn, page)

      more!(view, "#pb-more-seo")
      _settled = render_async(view)

      assert has_element?(view, "#pb-settings-modal")
      assert has_element?(view, "#pb-settings-tab-seo[aria-selected='true']")
      assert seo_text(view, "#pb-seo-search-title") =~ "Our studio"

      # The name still opens it on General.
      view |> element("#pb-settings-close") |> render_click()
      open_settings(view)
      assert has_element?(view, "#pb-settings-tab-general[aria-selected='true']")
    end

    test "while a draft is being written, the SEO is the draft's", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)
      open_seo(view)

      seo_change(view, %{"description" => "Written to the draft, not the page."}, ["description"])
      seo_save(view)

      assert reread!(MishkaCmsCore.Runtime.PageDraft, draft_id).description ==
               "Written to the draft, not the page."

      assert reread!(MishkaCmsCore.Runtime.Page, page.id).description == page.description
    end

    test "the previews follow the title and description as they are typed", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      seo_change(view, %{"title" => "A title typed just now"}, ["title"])
      assert seo_text(view, "#pb-seo-search-title") =~ "A title typed just now"
      assert has_element?(view, "#pb-seo-meter-title[data-state='short']")

      seo_change(view, %{"title" => "{{page.title}} | Studio"}, ["title"])
      assert seo_text(view, "#pb-seo-search-title") =~ "#{page.title} | Studio"

      # A variable nothing fills leaves the title as it was.
      seo_change(view, %{"title" => "{{post.title}} | Studio"}, ["title"])
      assert seo_text(view, "#pb-seo-search-title") =~ page.title

      description = String.duplicate("A sentence about the studio. ", 4)
      seo_change(view, %{"description" => description}, ["description"])

      assert seo_text(view, "#pb-seo-search-description") =~ "A sentence about the studio."
      assert seo_text(view, "#pb-seo-share-description") =~ "A sentence about the studio."
      assert has_element?(view, "#pb-seo-meter-description[data-state='good']")
    end

    test "a known tag is added with its default, and a custom one by its name", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      seo_change(view, %{"add" => "og:title"}, ["add"])
      assert has_element?(view, "#pb-seo-add-value[value='{{page.title}}']")

      view |> element("#pb-seo-add-confirm") |> render_click()
      assert has_element?(view, "#pb-seo-tag-0", "Open Graph title")
      refute has_element?(view, "#pb-seo-add-confirm")

      seo_change(view, %{"add" => "custom"}, ["add"])
      assert has_element?(view, "#pb-seo-add-confirm[disabled]")

      seo_change(
        view,
        %{"custom_kind" => "property", "custom_key" => "fb:app_id", "add_value" => "123"},
        ["add_value"]
      )

      view |> element("#pb-seo-add-confirm") |> render_click()
      assert has_element?(view, "#pb-seo-tag-1", "fb:app_id")

      seo_save(view)

      saved = reread!(MishkaCmsCore.Runtime.Page, page.id)
      assert stored_tag(saved, "property", "og:title").content == "{{page.title}}"
      assert stored_tag(saved, "property", "fb:app_id").content == "123"
    end

    test "an enumerated tag offers its values, and robots its directives", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      seo_change(view, %{"add" => "twitter:card"}, ["add"])
      assert has_element?(view, "select#pb-seo-add-value option[value='summary']")

      seo_change(view, %{"add" => "robots"}, ["add"])
      assert has_element?(view, "#pb-seo-add-values input[value='noarchive']")

      seo_change(view, %{"add_values" => ["noindex", "noarchive"]}, ["add_values"])
      view |> element("#pb-seo-add-confirm") |> render_click()

      assert has_element?(view, "#pb-seo-tag-0", "noindex, noarchive")

      view |> element("#pb-seo-tag-remove-0") |> render_click()
      assert has_element?(view, "#pb-seo-tags-empty")
    end

    test "the switch hides the page from search engines, and turning it off shows it again", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      seo_change(view, %{"noindex" => "true"}, ["noindex"])
      assert has_element?(view, "#pb-seo-noindex[checked]")
      assert has_element?(view, "#pb-seo-tag-0", "noindex, nofollow")

      seo_change(view, %{"noindex" => "false"}, ["noindex"])
      refute has_element?(view, "#pb-seo-noindex[checked]")
      assert has_element?(view, "#pb-seo-tags-empty")
    end

    test "a sign-in page says it is hidden already", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: @template, extra: %{"visitors_only" => true})

      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      assert seo_text(view, "#pb-seo-basics") =~ "Hidden already"
    end

    test "a schema type writes one JSON-LD object and keeps the page's others", %{
      conn: conn,
      site: site
    } do
      crumbs = %{"@context" => "https://schema.org", "@type" => "BreadcrumbList"}
      page = create_page!(site_id: site.id, template: @template, schema: [crumbs])

      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      seo_change(view, %{"type" => "Article"}, ["type"])
      assert has_element?(view, "#pb-seo-field-headline[value='{{page.title}}']")

      seo_change(view, %{"fields" => %{"datePublished" => "2026-10-01"}}, [
        "fields",
        "datePublished"
      ])

      seo_save(view)

      assert [^crumbs, article] = reread!(MishkaCmsCore.Runtime.Page, page.id).schema

      assert %{
               "@type" => "Article",
               "headline" => "{{page.title}}",
               "datePublished" => "2026-10-01",
               "author" => %{"@type" => "Person", "name" => "{{site.name}}"}
             } = article
    end

    test "questions and answers are added and removed in pairs", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      seo_change(view, %{"type" => "FAQPage"}, ["type"])
      assert has_element?(view, "#pb-seo-faq-0")

      view |> element("#pb-seo-faq-add") |> render_click()
      assert has_element?(view, "#pb-seo-faq-1")

      seo_change(
        view,
        %{"faq" => %{"0" => %{"question" => "Open on Sunday?", "answer" => "No."}}},
        ["faq", "0", "question"]
      )

      view |> element("#pb-seo-faq-remove-1") |> render_click()
      refute has_element?(view, "#pb-seo-faq-1")

      seo_save(view)

      assert [%{"@type" => "FAQPage", "mainEntity" => [question]}] =
               reread!(MishkaCmsCore.Runtime.Page, page.id).schema

      assert question["name"] == "Open on Sunday?"
      assert question["acceptedAnswer"]["text"] == "No."
    end

    test "the advanced JSON-LD is checked before it is saved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)
      view |> element("#pb-seo-advanced") |> render_click()

      seo_change(view, %{"json" => "[{not json"}, ["json"])
      assert seo_text(view, "#pb-seo-json-error") =~ "not valid JSON"

      seo_change(view, %{"json" => ~s([{"name": "untyped"}])}, ["json"])
      assert seo_text(view, "#pb-seo-json-error") =~ "@type"

      seo_save(view)
      assert render(view) =~ "The JSON-LD has a mistake"
      assert has_element?(view, "#pb-seo-form")
      assert reread!(MishkaCmsCore.Runtime.Page, page.id).schema == []

      seo_change(view, %{"json" => ~s([{"@type": "AboutPage", "name": "{{page.title}}"}])}, [
        "json"
      ])

      refute has_element?(view, "#pb-seo-json-error")
      seo_save(view)

      assert reread!(MishkaCmsCore.Runtime.Page, page.id).schema == [
               %{"@type" => "AboutPage", "name" => "{{page.title}}"}
             ]
    end

    test "the variable chips list the core variables", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      for key <- ~w(page.title page.description page.url page.image site.name) do
        assert has_element?(view, ~s([data-seo-var="{{#{key}}}"])), key
      end

      refute has_element?(view, "#pb-seo-record-note")
    end

    test "a page whose plugin fills its SEO lists the plugin's variables and says so", %{
      conn: conn,
      site: site
    } do
      register_plugin(PostSeo, "runtime:page:seo")
      n = System.unique_integer([:positive])
      page = create_page!(site_id: site.id, template: @template, path: "/:lang/post-#{n}/:slug")

      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      assert has_element?(view, ~s([data-seo-var="{{post.title}}"]))
      assert has_element?(view, "#pb-seo-record-note")
    end

    test "the share image is chosen from Media", %{conn: conn, page: page, site: site} do
      media =
        create_media!(site_id: site.id, name: "cover", relative_path: "/uploads/cover.png")

      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      view |> element("#pb-seo-image-pick") |> render_click()
      assert has_element?(view, "#pb-sheet")
      assert has_element?(view, "#pb-settings-modal.hidden")

      send(view.pid, {:row_action, "use_media", %{"id" => media.id}})
      _rendered = render(view)

      refute has_element?(view, "#pb-sheet")
      refute has_element?(view, "#pb-settings-modal.hidden")

      # The address is put into the field by the `PbSeoFields` hook, whose change writes it — the
      # field is hidden until the author asks for an address, so the hook's change is sent as is.
      assert_push_event(view, "pb-seo-set", %{id: "pb-seo-image", value: "/uploads/cover.png"})

      view
      |> element("#pb-seo-form")
      |> render_change(%{
        "seo" => %{"image" => "/uploads/cover.png"},
        "_target" => ["seo", "image"]
      })

      assert has_element?(view, "#pb-seo-image[value='/uploads/cover.png']")
      assert has_element?(view, "#pb-seo-image-thumb[src='/uploads/cover.png']")
      assert has_element?(view, "#pb-seo-image-clear")
      assert has_element?(view, "#pb-seo-share-image[src='/uploads/cover.png']")

      view |> element("#pb-seo-image-clear") |> render_click()
      refute has_element?(view, "#pb-seo-image-thumb")
      refute has_element?(view, "#pb-seo-share-image")
    end

    test "Save writes the description, tags and schema and leaves the design alone", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      before = editor(view).tree
      open_seo(view)
      view |> element("#pb-seo-image-manual") |> render_click()

      seo_change(
        view,
        %{
          "description" => "What the studio does.",
          "image" => "/uploads/cover.png",
          "canonical" => "https://example.com/about"
        },
        ["canonical"]
      )

      seo_save(view)

      refute has_element?(view, "#pb-settings-modal")
      assert render(view) =~ "Saved."

      saved = reread!(MishkaCmsCore.Runtime.Page, page.id)
      assert saved.description == "What the studio does."
      assert stored_tag(saved, "property", "og:image").content == "/uploads/cover.png"
      assert stored_tag(saved, "rel", "canonical").attrs["href"] == "https://example.com/about"
      assert saved.template == page.template
      assert editor(view).tree == before
    end

    test "the title is a stored tag over the page's own, and any field takes a variable", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, title: "Our studio", template: @template)
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      assert has_element?(view, "#pb-seo-title[placeholder='Our studio'][data-seo-vars]")
      assert has_element?(view, "#pb-seo-description[data-seo-vars]")
      refute has_element?(view, "#pb-seo-title[value]")

      seo_change(view, %{"title" => "{{page.title}} | Studio"}, ["title"])
      seo_save(view)

      saved = reread!(MishkaCmsCore.Runtime.Page, page.id)
      assert saved.title == "Our studio"

      assert %{content: "{{page.title}} | Studio"} =
               Enum.find(saved.seo_tags, &(&1.tag == "title"))
    end

    test "a page that serves records says each fills what is left empty, and names its variables",
         %{conn: conn, site: site} do
      register_plugin(PostSeo, "runtime:page:seo")
      n = System.unique_integer([:positive])
      page = create_page!(site_id: site.id, template: @template, path: "/:lang/post-#{n}/:slug")

      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      assert seo_text(view, "#pb-seo-record-note") =~ "Each record fills what you leave empty"
      assert seo_text(view, "#pb-seo-type") =~ "Default (from each record)"

      assert has_element?(
               view,
               "#pb-seo-description[placeholder='Empty: each record\\'s own description.']"
             )

      # There is no post in the editor, so the preview shows where its title goes.
      seo_change(view, %{"title" => "{{post.title}} | Blog"}, ["title"])
      assert seo_text(view, "#pb-seo-search-title") =~ "{post.title} | Blog"
      seo_save(view)

      saved = reread!(MishkaCmsCore.Runtime.Page, page.id)
      assert %{content: "{{post.title}} | Blog"} = Enum.find(saved.seo_tags, &(&1.tag == "title"))
    end

    # WHAT EACH ADDRESS SHOWS IS WHAT KIND OF PAGE IT IS, so it is picked on General beside who may open
    # it, out of the kinds the installed extensions name; SEO only reads it.
    test "General picks which kind of record each address shows; a custom page shows none",
         %{conn: conn, site: site} do
      register_plugin(TestKinds, "runtime:page:records")

      page =
        create_page!(
          site_id: site.id,
          template: @template,
          path: "/:lang/journal/:slug",
          extra: %{"keep" => "me"}
        )

      {:ok, view, _html} = open_builder(conn, page)
      open_settings(view)

      form = settings_form("page")
      view |> element("#{form} input[name='_search_record']") |> render_focus()
      assert has_element?(view, "#{form} [phx-value-id='__nil__']", "Custom page")

      # Each extension's kinds under its name, and a kind says its extension once picked.
      assert has_element?(view, "#{form} div", "Journal")

      assert has_element?(
               view,
               "#{form} [phx-value-id='test:post'][phx-value-label='Journal · Entry']",
               "Entry"
             )

      assert has_element?(
               view,
               "#{form} [phx-value-id='other:issue'][phx-value-label='Tracker · Issue']",
               "Issue"
             )

      view |> pick_kind(form, "test:post") |> form(form) |> render_submit()

      saved = reread!(MishkaCmsCore.Runtime.Page, page.id)
      assert saved.extra["record"] == "test:post"
      assert saved.extra["keep"] == "me"

      # The SEO tab no longer offers it, and reads what General saved.
      open_seo(view)
      refute has_element?(view, "#pb-seo-record-open")
      assert has_element?(view, "#pb-seo-record-note")
      view |> element("#pb-settings-close") |> render_click()

      open_settings(view)
      assert has_element?(view, "#{form} input[type='hidden'][name='record'][value='test:post']")

      view |> pick_kind(form, "__nil__") |> form(form) |> render_submit()

      assert reread!(MishkaCmsCore.Runtime.Page, page.id).extra == %{"keep" => "me"}
    end

    test "the preview draws a sample record, or placeholders where its address shows the capture",
         %{conn: conn, site: site} do
      register_plugin(TestKinds, "runtime:page:records")
      register_plugin(TestEntrySeo, "runtime:page:seo")

      page =
        create_page!(
          site_id: site.id,
          template: @template,
          path: "/:lang/journal/:slug",
          extra: %{"record" => "test:post"}
        )

      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      assert seo_text(view, "#pb-seo-search-url") =~ "journal › {slug}"
      seo_change(view, %{"title" => "{{entry.title}} - Mishka Group"}, ["title"])
      assert seo_text(view, "#pb-seo-search-title") =~ "{entry.title} - Mishka Group"

      seo_change(view, %{"sample" => "0"}, ["sample"])
      assert seo_text(view, "#pb-seo-search-title") =~ "Entry first - Mishka Group"
      assert seo_text(view, "#pb-seo-search-url") =~ "journal › first"

      seo_change(view, %{"sample" => ""}, ["sample"])
      assert seo_text(view, "#pb-seo-search-title") =~ "{entry.title} - Mishka Group"
    end

    test "the previews switch between Google, X and Facebook", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      assert has_element?(view, "#pb-seo-x.hidden")
      refute has_element?(view, "#pb-seo-google.hidden")

      view |> element("#pb-seo-view-x") |> render_click()
      refute has_element?(view, "#pb-seo-x.hidden")
      assert has_element?(view, "#pb-seo-google.hidden")
      assert has_element?(view, "#pb-seo-view-x[aria-selected='true']")

      view |> element("#pb-seo-view-facebook") |> render_click()
      refute has_element?(view, "#pb-seo-share.hidden")
    end

    test "a rating on a type search engines may star is drawn as stars", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      seo_change(view, %{"type" => "BlogPosting"}, ["type"])
      refute has_element?(view, "#pb-seo-stars-note")

      seo_change(view, %{"type" => "Product"}, ["type"])
      assert has_element?(view, "#pb-seo-stars-note")
      refute has_element?(view, "#pb-seo-stars")

      seo_change(
        view,
        %{
          "fields" => %{
            "aggregateRating.ratingValue" => "4.5",
            "aggregateRating.ratingCount" => "12"
          }
        },
        ["fields", "aggregateRating.ratingValue"]
      )

      assert seo_text(view, "#pb-seo-stars") =~ "★★★★★"
      assert seo_text(view, "#pb-seo-stars") =~ "4.5"
      assert seo_text(view, "#pb-seo-stars") =~ "12"
    end

    test "the canonical address, the tags and the JSON-LD are folded under Advanced", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)

      assert has_element?(view, "#pb-seo-advanced[aria-expanded='false']")
      assert has_element?(view, "#pb-seo-advanced-section .hidden #pb-seo-canonical")
      assert has_element?(view, "#pb-seo-advanced-section .hidden #pb-seo-tags")
      assert has_element?(view, "#pb-seo-advanced-section .hidden #pb-seo-json")

      view |> element("#pb-seo-advanced") |> render_click()
      assert has_element?(view, "#pb-seo-advanced[aria-expanded='true']")
      refute has_element?(view, "#pb-seo-advanced-section .hidden #pb-seo-canonical")
    end

    test "a layout's SEO tab is its tags alone", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, path: "/layouts/seo")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _settled = render_async(view)
      assert seo_text(view, "#pb-more-seo") =~ "The tags every page on this layout carries"
      open_seo(view)

      assert has_element?(view, "#pb-seo-tags")
      assert has_element?(view, "#pb-seo-vars")
      refute has_element?(view, "#pb-seo-previews")
      refute has_element?(view, "#pb-seo-basics")
      refute has_element?(view, "#pb-seo-schema")

      seo_change(view, %{"add" => "og:site_name"}, ["add"])
      view |> element("#pb-seo-add-confirm") |> render_click()
      seo_save(view)

      saved = reread!(MishkaCmsCore.Runtime.Layout, layout.id)
      assert stored_tag(saved, "property", "og:site_name").content == "{{site.name}}"
    end

    test "an error page has no SEO tab", %{conn: conn, site: site} do
      error_page = create_error_page!(site_id: site.id)

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      _settled = render_async(view)
      open_settings(view)

      assert has_element?(view, "#pb-settings-modal")
      refute has_element?(view, "#pb-settings-tab-seo")
      refute has_element?(view, "#pb-more-seo")
      refute SeoSettings.mode("error-page")
      assert SeoSettings.mode("page") == :page
      assert SeoSettings.mode("layout") == :tags
    end
  end

  # §3 — AN ERROR PAGE HAS NO PATH ANYBODY CHOOSES. The renderer derives the address it looks a row
  # up by from the site, so a path somebody typed produced an error page nothing could ever render.
  # `MishkaCmsCore.Runtime.ErrorAddress` is the rule; these are the two surfaces it reaches.
  describe "an error page's address" do
    test "the essentials step does not ask for a path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/error-page")

      form = "#pb-new-error-page-form"
      assert has_element?(view, "#{form} input[name='form[name]']")

      # SHOWN, NOT TYPED. Gervaz renders a `readonly` field and drops it from what is submitted, so
      # the reader sees where the address comes from and the action writes it.
      assert has_element?(view, "#{form} input[name='form[path]'][readonly]")
    end

    test "a created error page is addressed at its site", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/error-page")

      view
      |> element("#pb-new-error-page-form input[name='_search_site_id']")
      |> render_focus()

      view
      |> element("#search-select-pb-new-error-page-site_id button", site.name)
      |> render_click()

      view
      |> form("#pb-new-error-page-form", %{"form" => %{"name" => "addressed-errors"}})
      |> render_submit()

      record =
        MishkaCmsCore.Runtime.ErrorPage
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(name == "addressed-errors")
        |> Ash.read_one!()

      assert record.path == ErrorAddress.for_site(site.id)
      assert record.path == "/mishka-cms/errors/#{site.name}"
    end

    # INSIDE THE EDITOR TOO. The settings modal is the same Gervaz form in edit mode, so the same
    # `readonly` keeps the address out of the reader's hands there — and shows them what it is.
    test "the settings modal shows the address and will not take a new one", %{
      conn: conn,
      site: site
    } do
      error_page = create_error_page!(site_id: site.id)

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      _settled = render_async(view)
      open_settings(view)

      form = settings_form("error-page")
      assert has_element?(view, "#{form} input[name='form[path]'][readonly]")

      view
      |> form(form, %{"form" => %{"name" => "renamed-errors", "path" => "/somewhere-else"}})
      |> render_submit()

      saved = reread!(MishkaCmsCore.Runtime.ErrorPage, error_page.id)
      assert saved.name == "renamed-errors"
      assert saved.path == ErrorAddress.for_site(site.id)
    end

    # A TENANT'S SITE IS KNOWN BEFORE ANYTHING IS TYPED, so "make an error page" for a site that has
    # one opens the one it has rather than asking for a name and refusing the answer afterwards.
    test "a tenant asking for a new one lands on the one their site has", %{site: site} do
      error_page = create_error_page!(site_id: site.id)
      tenant = create_admin("tenant-errors@example.com", site.id)
      conn = log_in(build_conn_for_host(), tenant)

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/dashboard/runtime/builder/error-page")

      assert to == "/admin/dashboard/runtime/builder/error-page/#{error_page.id}"
      assert flash["info"] =~ "already has an error page"
    end

    # AND A TENANT WHOSE SITE HAS NONE STILL GETS THE STEP. The redirect is about the one that
    # exists, not about tenants.
    test "a tenant whose site has none is asked to name one", %{conn: conn} do
      fresh = create_site!(name: "no-errors-yet", host: "no-errors-yet.test")
      cache_site(fresh)
      tenant = create_admin("tenant-no-errors@example.com", fresh.id)
      tenant_conn = log_in(build_conn_for_host(fresh.host), tenant)
      _unused = conn

      {:ok, view, _html} = live(tenant_conn, "/admin/dashboard/runtime/builder/error-page")

      assert has_element?(view, "#pb-new-document")
    end

    # A MASTER HAS NOT SAID WHICH SITE YET, so nothing can be looked up for them — what answers is
    # the identity, in words a reader can act on rather than ones naming a field they never saw.
    test "a master picking a site that is taken is told which one it is", %{
      conn: conn,
      site: site
    } do
      _existing = create_error_page!(site_id: site.id)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/error-page")

      view
      |> element("#pb-new-error-page-form input[name='_search_site_id']")
      |> render_focus()

      view
      |> element("#search-select-pb-new-error-page-site_id button", site.name)
      |> render_click()

      html =
        view
        |> form("#pb-new-error-page-form", %{"form" => %{"name" => "second-errors"}})
        |> render_submit()

      assert html =~ "already has an error page"
    end
  end

  # §A — WHAT THE EDITOR NEEDS BEFORE THERE IS A DOCUMENT. Reached by "Create empty & open editor",
  # which is a link: it leaves the list page's form unsubmitted precisely so none of its validations
  # fire, and the record is made here instead — through the resource's OWN Gervaz form, with
  # everything but the essentials hidden.
  describe "the essentials step" do
    defp essentials_form(section), do: "#pb-new-" <> section <> "-form"

    defp created!(resource, name) do
      resource
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(name == ^name)
      |> Ash.read!(page: [limit: 2])
      |> then(fn
        %{results: [record]} -> record
        [record] -> record
        _none -> nil
      end)
    end

    defp start_document(view, section, fields, site) do
      view
      |> pick_essentials_site(section, site)
      |> form(essentials_form(section), %{"form" => fields})
      |> render_submit()
    end

    defp pick_essentials_site(view, section, site) do
      view
      |> element("#{essentials_form(section)} input[name='_search_site_id']")
      |> render_focus()

      view
      |> element("#search-select-pb-new-#{section}-site_id button", site.name)
      |> render_click()

      view
    end

    # THE FIELDS ARE THE RESOURCE'S, NOT A COPY OF THEM. What is pinned is which ones survive: a
    # title, a path, and the site relation — and that the rest of the resource's twenty are not on
    # screen.
    test "a page is asked for a title, a path, what it shows and a site, and nothing else", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")

      form = essentials_form("page")
      assert has_element?(view, "#{form} input[name='form[title]']")
      assert has_element?(view, "#{form} input[name='form[path]']")

      # What each address shows follows the site, as a layout does, so a master picks that first.
      pick_essentials_site(view, "page", site)
      assert has_element?(view, "#{form} input[name='_search_record']")

      # The site is a SEARCHABLE relation, not a select — a list of every site is not a control.
      assert has_element?(view, "#{form} input[name='_search_site_id']")
      refute has_element?(view, "#{form} select[name='form[site_id]']")

      for absent <- ~w(template content extra schema description priority format) do
        refute has_element?(view, "#{form} [name='form[#{absent}]']"),
               "#{absent} is not one of the essentials"
      end
    end

    test "naming a page creates it and the editor reopens on it", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")

      start_document(
        view,
        "page",
        %{"title" => "Essentials Page", "path" => "/essentials-page"},
        site
      )

      record = created!(MishkaCmsCore.Runtime.Page, "essentials-page")
      assert record
      assert_redirect(view, "/admin/dashboard/runtime/builder/page/#{record.id}")

      # AND IT IS AN EMPTY DOCUMENT, not a record with a hole in it: the starter chooser only offers
      # itself over markup `PageStarter.empty?/1` recognises.
      {:ok, tree} = Tree.parse(record.template)
      assert PageStarter.empty?(tree)
    end

    test "a page named with the kind it shows is created showing it", %{conn: conn, site: site} do
      register_plugin(MishkaCmsCoreWeb.Test.BuilderLiveTest.TestKinds, "runtime:page:records")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")
      form = essentials_form("page")

      view
      |> pick_essentials_site("page", site)
      |> pick_kind(form, "test:post")
      |> form(form, %{
        "form" => %{"title" => "Essentials Kind", "path" => "/essentials-kind/:slug"}
      })
      |> render_submit()

      assert created!(MishkaCmsCore.Runtime.Page, "essentials-kind").extra["record"] ==
               "test:post"
    end

    # A COMPONENT IS REACHED BY NAME. It has no `path` attribute at all, so the resource's form never
    # declared one and there is nothing here to hide.
    test "a component is not asked for a path", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/component")

      refute has_element?(view, "#{essentials_form("component")} input[name='form[path]']")

      start_document(view, "component", %{"name" => "essentials-component"}, site)

      assert created!(MishkaCmsCore.Runtime.Component, "essentials-component")
    end

    # A LAYOUT DEMANDED REAL MARKUP until now — its create action grew the same blank-template change
    # a page and a component already had, or hiding the field would have made it unsaveable.
    test "a layout is created with the starter template", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout")

      start_document(
        view,
        "layout",
        %{"name" => "essentials-layout", "path" => "/essentials-layout"},
        site
      )

      record = created!(MishkaCmsCore.Runtime.Layout, "essentials-layout")
      assert record

      # AND IT WRAPS SOMETHING. A layout renders the page inside it through `@inner_content`; one
      # without it would swallow every page that used it, which is a broken site rather than an
      # empty one.
      assert record.template == PageStarter.blank(:layout)
      assert record.template =~ "@inner_content"
    end

    test "an error page is created and opened", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/error-page")

      start_document(
        view,
        "error-page",
        %{"name" => "essentials-error-page", "path" => "/essentials-error-page"},
        site
      )

      record = created!(MishkaCmsCore.Runtime.ErrorPage, "essentials-error-page")
      assert record
      assert_redirect(view, "/admin/dashboard/runtime/builder/error-page/#{record.id}")
    end

    # THE RESOURCE SAYS WHAT IS REQUIRED, and it is the resource that answers — this step adds no
    # rules of its own, so an empty title is refused by the same validation the list page uses.
    test "an empty title is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")

      html =
        view |> form(essentials_form("page"), %{"form" => %{"title" => ""}}) |> render_submit()

      assert html =~ "must be present" or html =~ "required"
      refute_redirected(view, "/admin/dashboard/runtime/builder/page")
    end

    # AN ID THAT RESOLVES TO NOTHING IS NOT AN INVITATION TO CREATE — AND NOT AN EDITOR EITHER. It
    # used to open the whole thing over a nil record, where every save was a silent no-op, so the
    # work went nowhere and said so nowhere. The link is turned away at the door instead.
    test "a link carrying an id that resolves to nothing is turned away", %{conn: conn} do
      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/dashboard/runtime/builder/page/#{Ash.UUID.generate()}")

      assert to == "/admin/dashboard/runtime/pages"
      assert flash["error"] =~ "could not be opened"
    end

    test "a malformed id is turned away the same way", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} =
               live(conn, "/admin/dashboard/runtime/builder/layout/not-a-uuid")

      assert to == "/admin/dashboard/runtime/layouts"
    end

    # A SHARED DOCUMENT IS NOT A MISSING ONE. A tenant reads a site-less component perfectly well —
    # they place it on their pages — and the editor is still not theirs to open, because a save here
    # rewrites what every other site is rendering. The words are the whole point of the case: told
    # "may have been deleted", a reader goes looking for something that is sitting in their list.
    # `MishkaCmsCoreWeb.Test.EditorTenancyTest` asks this of all four sections and both actors.
    test "a tenant is turned away from a global component, and told why", %{
      conn: conn,
      site: site
    } do
      component = create_component!(site_id: nil, name: "pb-shared-card")
      tenant = create_admin("tenant-global@example.com", site.id)

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               conn
               |> log_in(tenant)
               |> live("/admin/dashboard/runtime/builder/component/#{component.id}")

      assert to == "/admin/dashboard/runtime/components"
      assert flash["error"] =~ "shared with every site"
      refute flash["error"] =~ "deleted"
    end

    test "and a master opens the same one", %{conn: conn} do
      component = create_component!(site_id: nil, name: "pb-shared-card-master")

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert has_element?(view, "#pb-root")
      assert editor(view).section == "component"
    end
  end

  # §A — THE OTHER WAY IN. Choosing, on the "+ Add" button, to keep going into the editor instead of
  # landing back on the list. The choice is made BEFORE the form is filled, which is where the reader
  # is deciding how to make one.
  describe "create and open the editor" do
    # A RELATION FIELD IS PICKED, NOT TYPED. Its value lives on a hidden input the form only writes
    # through `relation_select`, so `form/3` refuses to set it directly — the way in is the way a
    # reader takes: focus the search box, then choose from what it offers.
    defp pick_site(view, form_id, site) do
      scope = String.replace_suffix(form_id, "-form", "")

      view |> element("##{form_id} input[name='_search_site_id']") |> render_focus()
      view |> element("#search-select-#{scope}-site_id button", site.name) |> render_click()
      view
    end

    test "a page created after choosing it lands in the editor", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")

      view |> element("#pb-create-open-page") |> render_click()

      view
      |> pick_site("page_form-form", site)
      |> form("#page_form-form", %{
        "form" => %{"title" => "Carry On Page", "path" => "/carry-on-page"}
      })
      |> render_submit()

      record = created!(MishkaCmsCore.Runtime.Page, "carry-on-page")
      assert record
      assert_redirect(view, "/admin/dashboard/runtime/builder/page/#{record.id}")
    end

    # NON-VACUITY: the same form, saved without choosing it first, stays on the list. The redirect
    # above is the menu item's doing and nothing else's.
    #
    # The form is reached through the menu's ordinary way, because it lives on the inspector modal's
    # Configuration tab now and nothing mounts it until somebody asks — which is the point of that
    # change, and does not alter what this test is about.
    test "an ordinary Create stays where it is", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")

      view |> element("#pb-create-form-page") |> render_click()

      view
      |> pick_site("page_form-form", site)
      |> form("#page_form-form", %{
        "form" => %{"title" => "Stay Put Page", "path" => "/stay-put-page"}
      })
      |> render_submit()

      assert created!(MishkaCmsCore.Runtime.Page, "stay-put-page")
      assert render(view) =~ "Page created successfully"
    end

    # AND FORGOTTEN IF THE FORM IS ABANDONED. The intent outlives the click, so a cancelled modal
    # must clear it or the NEXT ordinary Create would carry it into the editor.
    test "cancelling forgets the choice", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")

      view |> element("#pb-create-open-page") |> render_click()
      send(view.pid, {:form_cancelled, MishkaCmsCore.Runtime.Page})

      # Cancelling closes the inspector, so the next create starts the way any create starts.
      view |> element("#pb-create-form-page") |> render_click()

      view
      |> pick_site("page_form-form", site)
      |> form("#page_form-form", %{
        "form" => %{"title" => "After Cancel Page", "path" => "/after-cancel-page"}
      })
      |> render_submit()

      assert created!(MishkaCmsCore.Runtime.Page, "after-cancel-page")
      assert render(view) =~ "Page created successfully"
    end

    test "a component created after choosing it lands in the editor", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/components")

      view |> element("#pb-create-open-component") |> render_click()

      view
      |> pick_site("component_form-form", site)
      |> form("#component_form-form", %{"form" => %{"name" => "carry-on-component"}})
      |> render_submit()

      record = created!(MishkaCmsCore.Runtime.Component, "carry-on-component")
      assert record
      assert_redirect(view, "/admin/dashboard/runtime/builder/component/#{record.id}")
    end

    # THE BUTTON IS THE EDITOR, THE FORM IS UNDER THE CARET — on every section's list page, and the
    # menu is markup the browser unfolds rather than anything this process has to be asked for.
    test "every section's + Add button opens the editor, with the form under the caret", %{
      conn: conn
    } do
      for {path, slug, section} <- [
            {"/admin/dashboard/runtime/pages", "page", "page"},
            {"/admin/dashboard/runtime/components", "component", "component"},
            {"/admin/dashboard/runtime/layouts", "layout", "layout"},
            {"/admin/dashboard/runtime/error-pages", "error_page", "error-page"}
          ] do
        {:ok, view, _html} = live(conn, path)

        assert view
               |> element("#add-#{slug}-ways")
               |> render()
               |> Kernel.=~("pb-create-form-#{slug}"),
               "#{path} does not offer the full form"

        assert has_element?(view, "#pb-create-open-#{slug}"),
               "#{path} does not offer 'fill it in, then open the editor'"

        assert has_element?(view, "#add-#{slug}-ways.hidden"),
               "#{path}'s menu should ship folded away"

        assert view
               |> element("a", "+ Add")
               |> render()
               |> Kernel.=~("/admin/dashboard/runtime/builder/#{section}"),
               "#{path}'s main half must go straight to the editor"
      end
    end
  end

  describe "the examples modal" do
    setup %{site: site} do
      create_component!(
        site_id: site.id,
        name: "promo-card",
        extra: %{
          "examples" => [
            %{
              "label" => "Base",
              "base" => true,
              "section" => nil,
              "requires" => %{"components" => ["promo-title"]},
              "source" =>
                ~s(<.component component_name="promo-card" site="Global" variant="bordered" color="info"><h3>Deal</h3></.component>)
            },
            %{
              "label" => "Filled",
              "base" => false,
              "section" => "Variants",
              "requires" => %{},
              # Furnished, like the Base one: curation now ranks an empty-bodied example below any
              # with content and drops it when the component has better — see `Examples.substance/1`.
              "source" =>
                ~s(<.component component_name="promo-card" site="Global" variant="filled"><h3>Filled deal</h3></.component>)
            }
          ]
        }
      )

      :ok
    end

    test "a component with examples shows a badge that opens the modal", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")

      html = render(view)
      assert html =~ "pb-examples"
      assert html =~ "2 variants"
      assert html =~ "Base"
      assert html =~ "Filled"
      # It opens on the first variant, showing the preview rather than the source.
      assert has_element?(view, "#pb-example-preview-0-desktop")
      assert has_element?(view, "#pb-example-insert")
      assert html =~ "also uses promo-title"
    end

    # §8: the old editor read only `ast[0][0]`, so an example's attributes and children never made
    # it onto the page. The whole parsed subtree is inserted here.
    test "inserting an example keeps its attributes AND its children", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")
      render_click(view, "insert_example", %{"index" => "0"})

      tree = view |> editor() |> Map.fetch!(:tree)
      inserted = tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "promo-card"))

      assert Node.attr(inserted, "variant") == {:string, "bordered"}
      assert Node.attr(inserted, "color") == {:string, "info"}
      assert tree |> Tree.walk() |> Enum.any?(&(&1.tag == "h3"))
    end

    # Every kit example hardcodes site="Global"; on a tenant page that would bind the node to the
    # wrong compiled module.
    test "inserting an example rebinds site to this page's scope", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")
      render_click(view, "insert_example", %{"index" => "1"})

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "promo-card"))

      assert Node.attr(inserted, "site") == {:string, "localhost"}
      refute Node.attr(inserted, "site") == {:string, "Global"}
    end

    # The other half of the same rule: a GLOBAL component's module is hashed with "Global", so
    # rebinding it to the page's site named a module nobody built and the canvas showed the runtime's
    # red "failed to render" on every global component inserted from an example.
    test "inserting a GLOBAL component's example leaves it bound to Global", %{
      conn: conn,
      page: page
    } do
      create_component!(
        name: "kit-footer",
        extra: %{
          "examples" => [
            %{
              "label" => "Base",
              "base" => true,
              "source" => ~s(<.component component_name="kit-footer" site="Global" />)
            }
          ]
        }
      )

      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "kit-footer")
      render_click(view, "insert_example", %{"index" => "0"})

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "kit-footer"))

      assert Node.attr(inserted, "site") == {:string, "Global"}
    end

    test "the inserted example survives a save", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      show_examples!(view, "promo-card")
      render_click(view, "insert_example", %{"index" => "0"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(variant="bordered")
      assert reloaded.template =~ ~s(site="localhost")
      assert reloaded.template =~ "Deal"
    end

    # The modal is a chooser, not a source dump: picking a variant only changes what the preview
    # renders, and nothing is inserted until Insert is pressed.
    test "picking a variant moves the preview without touching the document", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      show_examples!(view, "promo-card")
      assert has_element?(view, "#pb-example-preview-0-desktop")

      view |> element("#pb-example-1") |> render_click()
      assert has_element?(view, "#pb-example-preview-1-desktop")
      refute has_element?(view, "#pb-example-preview-0")

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # A drawer under the preview, not a replacement for it: the source is the answer to a second
    # question, and closing the picture to read it makes comparing the two impossible.
    test "the Code drawer shows the source without hiding the preview", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "promo-card")

      # The drawer is a fold the browser opens, so both are in the document at once — which is the
      # point: reading the source must not close the picture.
      assert has_element?(view, "#pb-example-code-body")
      assert has_element?(view, "#pb-example-preview-0-desktop")
      assert render(view) =~ "variant=&quot;bordered&quot;"
    end

    test "the device toggle narrows the stage to a phone width", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      show_examples!(view, "promo-card")

      view |> element("#pb-example-device-mobile") |> render_click()

      assert view |> element("#pb-example-preview-0-mobile") |> render() =~ "w-[320px]"
    end

    # The preview is drawn by the CANVAS in preview mode, in a document carrying the SITE's
    # stylesheet — the admin's CSS would draw a different component than the site draws, and a second
    # renderer would draw a different one than inserting produces.
    test "the preview route renders the chosen example with the site's own CSS", %{
      conn: conn,
      page: page
    } do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: "abc",
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, preview, body} = live(conn, example_path(token(view), "promo-card", 0))

      # The same stylesheet the editing canvas gets, by the same cacheable URL — carried as the
      # address here, because the `<link>` is the root layout's now. See the canvas tests.
      assert css_hrefs(preview) == ["/assets/css/__shared_base__/abc"]
      # The example's own subtree, resolved through the runtime the way the canvas resolves it.
      assert body =~ ~s(data-component="promo-card")
      # Preview mode: no drop tail, no element toolbar, no chrome stylesheet.
      refute body =~ "pb-canvas-tail"
      refute body =~ "pb-el-toolbar"

      # And not the page preview's bar: an example is not the author's page, and its way back would
      # toggle the editor's own preview from inside the modal.
      refute has_element?(preview, "#pb-preview-bar")
    end

    test "an unknown example says so rather than crashing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _preview, body} = live(conn, example_path(token(view), "promo-card", 99))

      assert body =~ "no longer available"
    end

    test "closing the modal leaves the document untouched", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      show_examples!(view, "promo-card")
      render_click(view, "close_examples", %{})

      refute render(view) =~ "pb-examples"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end
  end

  # Selecting an element has been the slowest thing in this editor twice: once at 2.2s, when every
  # mouse move pushed a `hover` event, and again at ~0.5s, when the selection ring was a server-
  # rendered inline style so a click re-rendered all ~200 nodes. Both were found in a browser, not
  # here — so this is the guard: the ring is client-side now, and the server's share of a selection
  # is a small, bounded thing.
  describe "selection cost" do
    test "a selection round trip stays cheap on a large document", %{conn: conn, site: site} do
      sections =
        Enum.map_join(1..40, fn i ->
          ~s(<section id="s#{i}"><h2>Section #{i}</h2><p>Body #{i}</p></section>)
        end)

      page = create_page!(site_id: site.id, template: ~s(<div id="root">#{sections}</div>))
      {:ok, view, _html} = open_builder(conn, page)

      tree = editor(view).tree
      assert Tree.size(tree) > 150
      ids = tree |> Tree.walk() |> Enum.map(& &1.id) |> Enum.take(10)

      # The first click after a fresh compile pays for module loading, which is not what this
      # measures — warm up, then time.
      render_click(view, "select", %{"id" => hd(ids)})

      times =
        for id <- ids do
          {microseconds, _html} = :timer.tc(fn -> render_click(view, "select", %{"id" => id}) end)
          div(microseconds, 1000)
        end

      # THE MIDDLE SAMPLE, NOT THE WORST ONE. Measured at 5–24ms on an idle machine, and what this
      # has to catch is a change in KIND — re-rendering the document on every click, which is
      # seconds, and which moves EVERY sample. A single 415ms outlier among nine samples of 86–174ms
      # is a GC pause or a busy scheduler, and asserting on the max made the whole suite hostage to
      # one of them: it failed on a run sharing this machine with two other suites and a dev server.
      #
      # Raising the ceiling again would have been the wrong repair — it trades away the very
      # sensitivity the test exists for. The median keeps it.
      median = times |> Enum.sort() |> Enum.at(div(length(times), 2))

      assert median < 400,
             "a selection cost #{median}ms (median) on a #{Tree.size(tree)}-node page: #{inspect(times)}"
    end
  end

  describe "drag and drop" do
    test "a drop carrying a node id is a move", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})

      tree = view |> editor() |> Map.fetch!(:tree)
      assert Tree.get(tree, h1.id).parent_id == nil
      assert hd(tree.roots) == h1.id
    end

    test "a drop carrying a template is an insert", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure")
    end

    test "the drop index is honoured", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "1"
      })

      tags =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.children(section.id)
        |> Enum.map(& &1.tag)

      assert Enum.at(tags, 1) == "figure"
    end

    # The client resolves geometry; it does not get to decide legality. A payload naming an illegal
    # parent is refused as a CHILD here even though no browser would have produced it — and lands
    # beside the target instead, which is the half of the contract the drag hint promises.
    test "a tampered drop is refused as a child and relocated beside the target", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      html =
        render_click(view, "drop", %{
          "template" => "<section></section>",
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "text and inline"
      assert html =~ "Placed after"

      tree = view |> editor() |> Map.fetch!(:tree)
      inserted = Enum.find(Tree.walk(tree), &(&1.tag == "section" and &1.children == []))

      assert inserted.parent_id == h1.parent_id
      refute inserted.parent_id == h1.id

      siblings = Tree.child_ids(tree, h1.parent_id || :root)

      assert Enum.find_index(siblings, &(&1 == inserted.id)) ==
               Enum.find_index(siblings, &(&1 == h1.id)) + 1
    end

    test "a drop with nowhere legal to land is refused outright", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      # Beside the h1 is still inside the section being moved, so the retry fails too.
      html =
        render_click(view, "drop", %{
          "node_id" => section.id,
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "inside itself" or html =~ "text and inline"
      refute html =~ "Placed after"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "dropping a node into its own descendant is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")

      html =
        render_click(view, "drop", %{
          "node_id" => section.id,
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "inside itself" or html =~ "text and inline"
      assert Tree.get(view |> editor() |> Map.fetch!(:tree), section.id).parent_id == nil
    end

    # WHAT THE RAIL OFFERS TO DROP INTO, AND HOW IT SAYS SO.
    #
    # This was a separate strip under every expanded COMPONENT — so every plain tag, the `<div>`,
    # `<main>` and `<footer>` a page is actually built out of, had no target in the tree at all, and
    # an empty `<div>` could not even be expanded to get one (`expandable?/1` is false for it on all
    # four counts). It was also permanent, standing on every expanded component whether or not
    # anything was being dragged.
    #
    # Revealing it per hover was the obvious repair and is the wrong shape: showing an in-flow box
    # only moves what is BELOW its own row, but hiding the previous one moves the row now UNDER the
    # pointer, and the strip was taller than a row. So the answer is written on the row, which
    # already has its size.
    test "a container row says so, on itself, only while it is the target", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: ~s(<main><p>Words</p></main><div></div>))
      {:ok, view, _html} = open_builder(conn, page)

      for tag <- ["main", "div"] do
        row = view |> element(~s([data-layer-row="#{node_with_tag(view, tag).id}"])) |> render()

        assert row =~ ~s(data-role="pb-drop-inside"), "#{tag} can be dropped into"
        assert row =~ "drop inside"
        assert row =~ "hidden", "and says nothing until a drag makes it the target"
        assert row =~ "group-data-[drop=inside]:flex"
      end
    end

    test "a row that cannot hold children never offers to", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>Words</p><img src="/a.png" />))
      {:ok, view, _html} = open_builder(conn, page)

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      for id <- [text.id, node_with_tag(view, "img").id] do
        row = view |> element(~s([data-layer-row="#{id}"])) |> render()

        refute row =~ ~s(data-role="pb-drop-inside")
        refute row =~ ~s(data-container="true")
      end
    end

    # The map of where this drag could land. `data-can` is written by the hook from the server's own
    # verdict; the row has to be able to DRAW it, and as an outline rather than a border or a tint
    # because both of those are already spoken for by the drop marker.
    test "a row can be drawn as somewhere this drag would go", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      row =
        view |> element(~s([data-layer-row="#{node_with_tag(view, "section").id}"])) |> render()

      assert row =~ "data-[can=true]:[outline:1px_dashed_#cfcdf0]"
      assert row =~ "data-[drop=inside]:bg-[#f2f1fc]"
      assert row =~ ~s(data-container="true")
    end

    # A SHUT BRANCH IS NOT IN THE DOCUMENT AT ALL, so a drag cannot reach into one — and
    # `default_expanded/1` opens the roots and one level below them and nothing else, so a tree of
    # any depth is mostly shut. A `<span>` inside a `<p>` inside a `<div>` had no row to aim at, and
    # the only way to reach it was to let go of what you were holding, click down to it, and pick it
    # up again. The hook springs a shut row open after a dwell; this is what tells it which rows are
    # worth waiting on.
    test "a row says whether it is shut over something", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section><div><p><span>Deep</span></p></div></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      # Open by default: `default_expanded/1` takes the roots and the branch children of the roots,
      # and stops. Two levels, however deep the document goes.
      for tag <- ["section", "div"] do
        assert view |> element(~s([data-layer-row="#{node_with_tag(view, tag).id}"])) |> render() =~
                 ~s(data-open="true")
      end

      # Shut, and worth waiting on — this is the row the drag has to open to get any further, and
      # the `<span>` under it is not in the document at all until it does.
      assert view |> element(~s([data-layer-row="#{node_with_tag(view, "p").id}"])) |> render() =~
               ~s(data-open="false")

      refute has_element?(view, ~s([data-layer-row="#{node_with_tag(view, "span").id}"]))
    end

    test "a row with nothing under it says nothing, so no drag waits on it", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: ~s(<section><hr /></section>))
      {:ok, view, _html} = open_builder(conn, page)

      row = view |> element(~s([data-layer-row="#{node_with_tag(view, "hr").id}"])) |> render()
      refute row =~ ~s(data-open=)
    end

    # The event the spring pushes is the chevron's own, which is what keeps one behaviour rather than
    # two: whatever a click opens, a dwell opens.
    test "the branch a drag opens is the branch a click opens", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section><div><p><span>Deep</span></p></div></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      paragraph = node_with_tag(view, "p")
      span = node_with_tag(view, "span")
      refute has_element?(view, ~s([data-layer-row="#{span.id}"]))

      render_click(view, "toggle_expand", %{"id" => paragraph.id})

      assert has_element?(view, ~s([data-layer-row="#{span.id}"]))

      assert view |> element(~s([data-layer-row="#{paragraph.id}"])) |> render() =~
               ~s(data-open="true")
    end

    # A COMPONENT'S OWN MARKUP IS NOT THE PAGE'S TREE.
    #
    # It was drawn loose, at the same indent as the page's own children and directly among them, with
    # nothing saying what it was — for a `chelekom-footer`, nine rows of somebody else's markup
    # between the component and the one line of content the page actually put in it. Rows that look
    # like children, are not, and accept nothing. It now sits behind a heading, like `.properties`
    # and `.slots`, and costs one row until it is asked for.
    test "a component's own markup is folded behind a heading of its own", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "deepish",
        template: ~s|<footer><div><span>a</span></div></footer>|,
        slots: []
      )

      page = create_page!(site_id: site.id, template: ~s|<.component component_name="deepish" />|)
      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)

      assert has_element?(view, "#pb-markup-#{node.id}")

      heading = view |> element("#pb-markup-#{node.id}") |> render()
      assert heading =~ ".markup"
      assert heading =~ "(4)", "footer, div, span and its text — the rows it will draw"

      refute render(view) =~ "read only", "nothing of it is drawn until the heading is opened"

      render_click(view, "toggle_expand", %{"id" => "markup:" <> node.id})

      html = render(view)
      assert html =~ "read only"
      assert html =~ "shared by every page using this component"
    end

    # Reading what is in there and going to edit it are different intents, so the heading carries the
    # fold and a separate arrow carries the trip — a link inside a button swallows the click, and a
    # heading that navigated away would take the fold with it.
    test "the markup heading is also the way to go and edit it", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "openable",
          template: ~s|<footer><div>a</div></footer>|,
          slots: []
        )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="openable" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)

      back =
        URI.encode_query(%{"return_to" => "/admin/dashboard/runtime/builder/page/#{page.id}"})

      assert has_element?(
               view,
               ~s(#pb-markup-open-#{node.id}[href="/admin/dashboard/runtime/builder/component/#{component.id}?#{back}"])
             )

      # The component's own row carries the same trip, and the same way back.
      assert has_element?(
               view,
               ~s(#pb-layer-open-#{node.id}[href="/admin/dashboard/runtime/builder/component/#{component.id}?#{back}"])
             )

      # And it is a sibling of the fold, not inside it: a link nested in a button never gets the click.
      assert view |> element("#pb-markup-#{node.id}") |> render() =~ "toggle_expand"
      refute view |> element("#pb-markup-#{node.id}") |> render() =~ "href="
    end

    # And it stays a window rather than becoming part of the document: no drag handle, no id a drop
    # could resolve to. Editing it here would rewrite the component under every other page silently.
    test "a component's own markup is not a drop target", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "windowed",
        template: ~s|<footer><div>a</div></footer>|,
        slots: []
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="windowed" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "markup:" <> node.id})

      rows = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.id)

      # Every addressable row in the rail is a node of the PAGE's tree. The markup contributes none.
      for id <- rail_row_ids(view) do
        assert id in rows, "#{id} is drawn as a drop target but is not in the document"
      end
    end

    # `Inspector.addable_slots/1` leaves out `inner_block` — that is not a slot anybody adds, it is
    # whatever you write between the tags — so a component declaring only `inner_block` counted zero
    # and was told "this component takes no slots". That is the opposite of true, and it is the
    # commonest shape in the kit: the rail marks such a component a container and a drop into it
    # lands. The line said the one thing that would stop an author trying.
    test "a component whose only slot is inner_block is not told it takes none", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "holds-anything",
        template: ~s|<div>{render_slot(@inner_block)}</div>|,
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}]
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="holds-anything">hi</.component>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      html = render(view)
      refute html =~ "this component takes no slots"
      assert html =~ "goes straight inside"

      # And the rail really does accept a drop into it, which is what makes the old line a lie.
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~
               ~s(data-container="true")
    end

    test "a component that takes nothing inside still says so", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "holds-nothing",
        template: ~s|<hr class="r" />|,
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="holds-nothing" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert render(view) =~ "takes nothing inside"
    end

    # `+ :source` USED TO BREAK THE PAGE.
    #
    # The button wrote `<:source></:source>` and nothing else, but a slot declares attributes of its
    # own and eleven of the kit's slots declare REQUIRED ones. The component reads them directly —
    # `chelekom-video` does `src={source.src}` — so a bare slot is not an empty slot, it is a missing
    # key: "chelekom-video could not render — key :src not found", the instant the button was
    # pressed. The one control whose whole job is "add the thing this component asks for" was the one
    # that stopped the page rendering.
    test "adding a slot writes the attributes that slot cannot render without", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "mediaish",
        template: ~s|<video><source :for={s <- @source} src={s.src} type={s.type} /></video>|,
        slots: [
          %{
            "name" => "source",
            "opts" => %{},
            "attrs" => [
              %{"name" => "src", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "type", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "label", "type" => "string", "opts" => %{}}
            ]
          }
        ]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="mediaish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      ghost = view |> element("#pb-slot-add-#{node.id}-source") |> render()
      assert ghost =~ ~s(src=)
      assert ghost =~ ~s(type=)
      refute ghost =~ ~s(label=), "optional attributes are what the Inspector is for"

      # And pressing it leaves a slot the component can actually render.
      view |> element("#pb-slot-add-#{node.id}-source") |> render_click()

      slot =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :slot))

      assert slot, "the slot was inserted"

      written = Enum.map(slot.attrs, fn {name, _value} -> name end)
      assert "src" in written
      assert "type" in written
    end

    # A slot with nothing required stays as bare as it always was — there is nothing to seed.
    test "a slot that requires nothing is still added bare", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "looseish",
        template: ~s|<div><div :for={a <- @extra}>{render_slot(a)}</div></div>|,
        slots: [%{"name" => "extra", "opts" => %{}, "attrs" => []}]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="looseish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert view |> element("#pb-slot-add-#{node.id}-extra") |> render() =~
               ~s(phx-value-template="&lt;:extra&gt;&lt;/:extra&gt;")
    end

    # The kit declares defaults for some of them, and a default beats an empty every time: it is the
    # value the component was designed around.
    test "a required attribute with a declared default is seeded with it", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "defaultish",
        template: ~s|<div><span :for={i <- @item}>{i.kind}</span></div>|,
        slots: [
          %{
            "name" => "item",
            "opts" => %{},
            "attrs" => [
              %{
                "name" => "kind",
                "type" => "string",
                "opts" => %{"required" => true, "default" => "info"}
              }
            ]
          }
        ]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="defaultish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert view |> element("#pb-slot-add-#{node.id}-item") |> render() =~ "info"
    end

    # A REQUIRED PROPERTY LEFT BLANK REFUSES THE PUBLISH BUTTON, and the rail never said so — the
    # first anyone heard was a flash naming a field several rows inside a component that may not even
    # be open. Read off the DECLARATION, so a kit nobody here has seen is marked the same way.
    test "the property row says which ones are compulsory", %{conn: conn, site: site} do
      needy(site.id)
      page = create_page!(site_id: site.id, template: ~s|<.component component_name="needful" />|)
      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "props:" <> node.id})

      required = view |> element("#pb-prop-row-#{node.id}-src") |> render()
      optional = view |> element("#pb-prop-row-#{node.id}-alt") |> render()

      assert required =~ "required"
      refute optional =~ "required"
    end

    # Loud while empty, quiet once filled: a satisfied requirement is worth knowing before you
    # clear it, and worth nothing louder than that.
    test "and stops shouting once it is filled", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="needful" src="/a.png" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "props:" <> node.id})

      row = view |> element("#pb-prop-row-#{node.id}-src") |> render()
      assert row =~ "required"
      refute row =~ "#c0473d", "filled, so it is not drawn as a problem"
    end

    # The number the badge shows is the SUBTREE's, which is the whole point: a shut component says
    # something inside it is unfinished without being opened.
    test "the row counts everything unfinished under it, shut or open", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<div><.component component_name="needful" /></div>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      wrapper = node_with_tag(view, "div")
      row = view |> element(~s([data-layer-row="#{wrapper.id}"])) |> render()

      assert row =~ "needed", "the div itself needs nothing; the component inside it does"
      assert row =~ "2 needed", "one blank required property and one missing required slot"
    end

    # A count on a shut row is a riddle without it, and the two cases need different words: a row
    # whose own properties are fine and whose CHILD is unfinished must not claim the problem is here.
    test "the badge says what is behind its number, in the right number", %{
      conn: conn,
      site: site
    } do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<div><.component component_name="needful" src="/a.png" /></div>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      component = needful_node(view)
      wrapper = node_with_tag(view, "div")

      # Its own: one required slot, never added.
      assert view |> element(~s([data-layer-row="#{component.id}"])) |> render() =~
               "1 slot required here is still empty"

      # The wrapper's: nothing of its own, one thing underneath.
      assert view |> element(~s([data-layer-row="#{wrapper.id}"])) |> render() =~
               "1 required thing inside this is still empty"
    end

    test "and says nothing at all once everything is filled", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<.component component_name="needful" src="/a.png"><:caption>hi</:caption></.component>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      refute view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "needed"
    end

    # THE BADGE AND THE BUTTON READ THE SAME ANSWER. Two implementations of one rule drift, and a
    # badge that disagrees with the refusal beside it is worse than no badge.
    test "the badge counts exactly what publishing refuses", %{conn: conn, site: site} do
      needy(site.id)
      page = create_page!(site_id: site.id, template: ~s|<.component component_name="needful" />|)
      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "2 needed"

      html = render_click(view, "publish", %{})
      assert html =~ "needful.src"
      assert html =~ "needful.:caption"
    end

    # A kit this editor has never seen declares its requirements the same way, so nothing here is
    # keyed to a component name or an attribute name.
    test "a component nobody has heard of is marked the same way", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "zzz-unknown-widget",
        template: ~s|<div data-x={@mandatory}></div>|,
        attrs: [%{"name" => "mandatory", "type" => "string", "opts" => %{"required" => true}}],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="zzz-unknown-widget" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "1 needed"
    end

    # THE END OF THE PAGE, which no row can stand for. A document with one root had exactly one place
    # to aim at in the rail and an EMPTY one had none at all — so the tray's whole gesture, dragging
    # a card into a page with nothing in it yet, could only be done on the canvas. It is the last
    # element in the rail, which is why it is allowed to appear and disappear when nothing else is.
    test "the rail offers the end of the page as a target", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s([data-role='pb-root-drop'][data-parent-id='root']))

      tail = view |> element(~s([data-role='pb-root-drop'])) |> render()
      assert tail =~ "drop at the end of the page"
      assert tail =~ "data-[show=true]:flex"
      refute tail =~ ~s(data-show=)
    end

    # The same payload the rail's tail sends, taken at its word by the server: a template with no
    # `node_id` is an insert, and an index past the end appends.
    test "a template dropped at the end of the page becomes a new root", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      roots = length(view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots))

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => "root",
        "index" => "9999"
      })

      tree = view |> editor() |> Map.fetch!(:tree)
      assert length(tree.roots) == roots + 1
      assert Tree.get(tree, List.last(tree.roots)).tag == "figure"
    end

    test "a move is undoable like any other edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})
      undo!(view)

      assert Tree.get(view |> editor() |> Map.fetch!(:tree), h1.id).parent_id != nil
    end

    # 183 components carrying their templates, attrs, slots and examples is 3.4 MB and 1.6 seconds.
    # Reading it during mount meant the editor drew nothing until it landed; it now arrives after,
    # and the panel says so rather than claiming there are no components.
    test "the palette loads after mount, showing a skeleton until it lands", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "late-arrival")

      {:ok, view, html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      # Before the async read returns: a skeleton, and NOT the "no components" answer — an empty
      # palette and one that has not arrived are different things to say.
      assert html =~ "pb-palette-skeleton"
      refute html =~ "No components match."

      loaded = render_async(view)

      refute loaded =~ "pb-palette-skeleton"
      assert loaded =~ "pb-comp-late-arrival"
      # It lands on the SESSION too, because the canvas binds components to a site from that list.
      assert view |> editor() |> Map.fetch!(:components) != []
    end

    test "palette cards advertise the same template click-to-place inserts", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "drag-me")
      {:ok, view, html} = open_builder(conn, page)

      assert html =~ ~s(data-template="&lt;.component component_name=&quot;drag-me&quot;)
      assert has_element?(view, "#pb-comp-drag-me[draggable]")
    end

    # The hint is what the drag paints its line from. It is asked for ONCE, at dragstart, and it has
    # to agree with the check that later admits the drop — which is why both come from the same
    # function. A hint that says yes where the drop says no is the bug this guards.
    test "dragstart answers with the whole tree's verdict for the thing being dragged", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      section = node_with_tag(view, "section")

      render_click(view, "drag_start", %{"template" => "<section></section>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: accepts})

      assert accepts[section.id] == true
      assert accepts[h1.id] == false
      assert map_size(accepts) == view |> editor() |> Map.fetch!(:tree) |> Tree.size()
    end

    # The hint is only worth having if the drop keeps its promise, so this asserts the promise on both
    # sides: where it says yes the node lands inside, where it says no the node lands beside instead.
    test "the drop keeps the promise the hint made", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "drag_start", %{"template" => "<figure></figure>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: accepts})

      tree = view |> editor() |> Map.fetch!(:tree)
      {yes, true} = Enum.find(accepts, fn {_id, allowed?} -> allowed? end)

      # A refused node whose PARENT accepts — so "beside it" is a place the retry can actually land.
      refused =
        Enum.find_value(accepts, fn
          {id, false} ->
            with %{} = node <- Tree.get(tree, id), true <- accepts[node.parent_id], do: node

          {_id, true} ->
            nil
        end)

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => yes,
        "index" => "0"
      })

      assert node_with_tag(view, "figure").parent_id == yes

      render_click(view, "drop", %{
        "template" => "<aside></aside>",
        "parent_id" => refused.id,
        "index" => "0"
      })

      assert node_with_tag(view, "aside").parent_id == refused.parent_id
    end

    test "a locked node accepts nothing, and a locked node being dragged is offered nowhere", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")

      {:ok, _locked} = EditorSession.toggle_lock(token(view), section.id)

      render_click(view, "drag_start", %{"template" => "<figure></figure>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: locked_target})
      assert locked_target[section.id] == false

      render_click(view, "drag_start", %{"node_id" => section.id})
      assert_push_event(view, "pb:drop-hints", %{accepts: locked_source})
      assert Enum.all?(locked_source, fn {_id, allowed?} -> allowed? == false end)
      assert locked_source[h1.id] == false
    end

    # SELECTING FIRST IS ALREADY SAYING WHERE. Picking with something selected used to arm the palette
    # and wait for a click on the element the reader had just clicked; it places into it instead.
    test "picking with an element selected places into it at once", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "straight-in")
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => "straight-in"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "straight-in"))

      assert placed, "one click on the palette should have been enough"
      assert placed.parent_id == section.id
      assert placed.id == List.last(Tree.get(editor(view).tree, section.id).children)

      # And nothing is left armed, so the next click on a row selects.
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # A BAND IS A SLICE OF THE PAGE, so it goes beside the other slices rather than into whatever was
    # selected. Every block in the library is one, which is why the whole library follows this rule
    # and a kit component, one test above, does not.
    test "picking a block with a section selected places it after that section", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      before = Tree.get(editor(view).tree, section.id).children
      block = hd(MishkaCmsCore.Runtime.PageBuilder.Blocks.all())
      render_click(view, "pick_block", %{"block" => block.id})

      tree = editor(view).tree
      assert Tree.get(tree, section.id).children == before, "the section was not opened up"

      placed = Tree.get(tree, List.last(tree.roots))
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # AND A BLOCK AN EXTENSION BROUGHT IS ONE OF THEM. The palette draws the merged library while the
    # click was resolved in the core one, so a contributed card answered "that element is no longer
    # on the page" — and dragging the identical card worked, which is what made it look like a
    # palette bug rather than a lookup that never asked the registry.
    test "and a block an extension contributed lands the same way", %{conn: conn, page: page} do
      register_plugin(BlockPlugin, "builder:blocks")

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick_block", %{"block" => BlockPlugin.block().id})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert Serializer.serialize(tree) =~ "They loved it.", "the plugin's own template"
    end

    # AN ELEMENT RIDES THE SAME ROUTE AS A BLOCK — one armed slot, two libraries — so a `<section>`
    # arrives by exactly the mechanism a finished Hero does, and lands by the same rule.
    test "picking a structural element places an empty container beside it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-section"})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert placed.tag == "section"
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert placed.children == [], "a layout element is a hole to put things in"
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # THE REPORTED BUG. A call to action clicked while the page header was selected became a third
    # item in the header's flex row and rendered a quarter of the width.
    test "a band clicked into a header lands beside the header, not in it", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<header class="flex"><a href="/">Logo</a><nav></nav></header><main></main>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      header = node_with_tag(view, "header")
      before = Tree.get(editor(view).tree, header.id).children

      render_click(view, "select", %{"id" => header.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      tree = editor(view).tree
      assert Tree.get(tree, header.id).children == before, "the header was left alone"

      placed = Tree.get(tree, Enum.at(tree.roots, 1))
      assert placed.tag == "section"
      assert placed.parent_id == nil
    end

    # CLIMBING MORE THAN ONE LEVEL. Clicking the heading inside a hero has to pop the band out of the
    # heading AND out of the hero — and that landing place is one the selection ring does not explain
    # on its own, so it is the one case that says where it went.
    test "a band clicked deep inside a section climbs out of the whole branch", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      html = render_click(view, "pick_block", %{"block" => "cta-band"})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert placed.tag == "section"
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert html =~ "Sections sit beside each other"
    end

    # THE CLIMB STOPS AT A WRAPPER THAT ALREADY HOLDS BANDS. A page wrapped in one div is an ordinary
    # shape, and lifting every new section out of it would put them somewhere the page does not live.
    test "a band is not lifted out of a wrapper that already holds bands", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="app"><section id="a"><p>One</p></section><section id="b"></section></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      wrapper = node_with_tag(view, "div")
      p = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => p.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      placed =
        editor(view).tree
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "section" and Node.attr(&1, "id") == nil))

      assert placed.parent_id == wrapper.id
    end

    # AN EMPTY BOX IS A HOLE TO PUT THINGS IN. It is the one container that cannot squeeze the band
    # into a narrow column, because there is nothing beside it — and it is the escape hatch that
    # keeps "make a section, then fill it" working.
    test "a band clicked into an empty section goes inside it", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section class="py-16"></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      assert Tree.get(editor(view).tree, section.id).children != []
    end

    # `<main>` is a band host by vocabulary, so a band clicked into one goes in rather than beside.
    test "a band clicked into main goes inside it", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<main><p>One</p></main>))

      {:ok, view, _html} = open_builder(conn, page)
      main = node_with_tag(view, "main")

      render_click(view, "select", %{"id" => main.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      assert Tree.get(editor(view).tree, main.id).children |> length() == 2
    end

    # WHAT MUST NOT CHANGE. Only a band climbs. A paragraph, a heading or a kit component clicked
    # while a section is selected still goes straight inside it — the gesture this editor is built on.
    test "a leaf clicked into a section still goes inside it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-paragraph"})

      children = Tree.get(editor(view).tree, section.id).children
      assert Tree.get(editor(view).tree, List.last(children)).tag == "p"
    end

    # `header` AND `footer` ARE NOT BANDS BY TAG. The spec puts them inside `<article>` and
    # `<section>` as readily as at page level, and treating them as page slices made "give this
    # section its own header" impossible to do by clicking.
    test "a bare header element goes inside the section that was selected", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<section id="s"><p>One</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-header"})

      children = Tree.get(editor(view).tree, section.id).children
      assert Tree.get(editor(view).tree, List.last(children)).tag == "header"
    end

    # WHAT MAKES THE PAGE FOOTER DIFFERENT IS THE LIBRARY. `footer-columns` is rooted in a `<footer>`
    # exactly like the element above, and it still climbs — every entry in Blocks is a slice of the
    # page by construction.
    test "the footer block still lands beside, not inside", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section id="s"><p>One</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      before = Tree.get(editor(view).tree, section.id).children
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "footer-columns"})

      tree = editor(view).tree
      assert Tree.get(tree, section.id).children == before
      assert Tree.get(tree, List.last(tree.roots)).tag == "footer"
    end

    # THE RULE IS A CLICK-PATH POLICY. A drag names its parent with the pointer, and a deliberate one
    # must still be obeyed — every builder in the field keeps these two answers separate.
    test "a dragged band still lands exactly where it was dropped", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<header class="flex"><a>Logo</a></header>))

      {:ok, view, _html} = open_builder(conn, page)
      header = node_with_tag(view, "header")

      render_click(view, "drop", %{
        "template" => "<section></section>",
        "parent_id" => header.id,
        "index" => "0"
      })

      placed = Tree.get(editor(view).tree, hd(Tree.get(editor(view).tree, header.id).children))
      assert placed.tag == "section", "a pointer knows better than a policy"
    end

    test "the Blocks panel lists the elements alongside the sections", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      assert has_element?(view, "#pb-el-el-section")
      assert has_element?(view, "#pb-el-el-columns-3")
      assert has_element?(view, "#pb-el-el-h2")
      assert has_element?(view, "#pb-block-hero-centred"), "the sections are still there"
    end

    # The categories filter one library or the other, never a mix of both — choosing Layout should
    # not leave eight finished marketing sections underneath it.
    test "an element category hides the sections", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      render_click(view, "block_cat", %{"cat" => "Layout"})

      assert has_element?(view, "#pb-el-el-section")
      refute has_element?(view, "#pb-block-hero-centred")
      refute has_element?(view, "#pb-el-el-h2"), "H2 is Text, not Layout"
    end

    # WITH NOTHING SELECTED IT STILL ARMS, because there is no answer yet — the canvas and the tree
    # are both waiting to give one.
    test "picking with no selection arms the palette instead", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "waits-for-a-click")
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "pick", %{"name" => "waits-for-a-click"})

      assert view |> editor() |> Map.fetch!(:picked) == "waits-for-a-click"

      refute view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.walk()
             |> Enum.find(&(Node.component_name(&1) == "waits-for-a-click"))
    end

    # Click-to-place accepts a click on the TREE as well as on the canvas, and lands in the row that
    # was clicked — inside it when it can hold the component, immediately after it when it cannot.
    test "a picked component is placed by clicking a layer row", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "place-me")
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "pick", %{"name" => "place-me"})
      render_click(view, "select", %{"id" => section.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "place-me"))

      assert placed.parent_id == section.id

      # The pick is spent, so the next click on a row selects again rather than placing a second one.
      assert view |> editor() |> Map.fetch!(:picked) == nil

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      assert view |> editor() |> Map.fetch!(:selection) == h1.id
    end

    # A component row pushes `inspect` rather than `select`, so placing had to be taught there too —
    # otherwise the tree could place into a `<div>` but not into the component you meant.
    test "a picked component is placed by clicking a component row", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-shell",
        slots: [%{"name" => "inner_block", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      create_component!(site_id: nil, name: "goes-inside")

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-shell" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      shell =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick", %{"name" => "goes-inside"})
      render_click(view, "inspect", %{"id" => shell.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "goes-inside"))

      assert placed.parent_id == shell.id

      # With nothing picked the same click still opens the Inspector on that component.
      render_click(view, "inspect", %{"id" => shell.id})
      assert view |> editor() |> Map.fetch!(:selection) == shell.id
      assert has_element?(view, "#pb-lefttab-inspector")
    end

    # A component that declares `id` as required raises the moment it renders without one. Generating
    # it where such nodes are created means that never has to be handled later — and it is written
    # into the template as an ordinary attribute, so it can be renamed. A node that declares no `id`
    # is left alone, plain HTML included: minting one for every `<figure>` would rewrite a document
    # nobody edited.
    test "a node that declares an id is given one", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: nil,
        name: "needs-id",
        attrs: [%{"name" => "id", "type" => "string", "opts" => %{"required" => true}}],
        template: "<div id={@id}>x</div>"
      )

      create_component!(site_id: site.id, name: "no-id-attr")
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert is_nil(Node.attr(node_with_tag(view, "figure"), "id"))

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="needs-id" site="Global"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      declared = component_node(view, "needs-id")
      assert Node.attr_text(declared, "id") =~ ~r/\S/

      # A component that never declared `id` is not given one — an undeclared assign is noise.
      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="no-id-attr" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert is_nil(Node.attr(component_node(view, "no-id-attr"), "id"))

      # An empty one is no id either — a snippet shipping `id=""` is as broken as one shipping none,
      # so a DECLARING node fills it. This `<article>` declares nothing, and keeps what it was given.
      render_click(view, "drop", %{
        "template" => ~s(<article id=""></article>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert Node.attr_text(node_with_tag(view, "article"), "id") == ""

      # An expression is a VALUE — the author bound the id to their data, and it is left alone.
      render_click(view, "drop", %{
        "template" => ~s(<aside id={@row.id}></aside>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert {:expr, expr} = Node.attr(node_with_tag(view, "aside"), "id")
      assert expr =~ "@row.id"
    end

    # A raise inside the canvas takes the LiveView with it, and the reload costs the author every
    # unsaved edit. A required attribute that is empty is knowable before rendering, so it is checked
    # rather than caught — no `try` on a path that runs for every component on every diff.
    test "a component missing a required attribute renders a placeholder, not a crash", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "strict-card",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{"required" => true}}],
        template: "<div>{@title}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="strict-card" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-incomplete="true"]))
      assert html =~ "strict-card"
      assert html =~ "needs title"

      # And it is still a node: selectable, so the missing field can be filled in the inspector.
      card = component_node(view, "strict-card")
      assert has_element?(canvas, ~s([data-node-id="#{card.id}"]))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => card.id,
        "name" => "title",
        "value" => "filled in"
      })

      refute has_element?(canvas, ~s([data-incomplete="true"]))
    end

    # THE OTHER HALF, AND THE HARDER ONE. A missing required attribute is knowable before rendering,
    # so it gets a check. Everything else a component might do — a bad value shape, an atom that does
    # not exist, an outright `raise` — is not, and it used to take the canvas LiveView with it:
    # crash, reload, and every unsaved edit in the session gone.
    #
    # It has to be a REAL compiled component. A database row whose module was never built takes the
    # runtime's "failed to render" branch and never runs at all, which is a different case and was
    # already handled — that is why this uses `MishkaCmsCore.Test.RaisingComponent`, whose one
    # attribute is declared, defaulted, and perfectly fine until it is given a value that names no
    # atom.
    test "a component that raises leaves the canvas standing", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root">) <>
              ~s(<MishkaCmsCore.Test.RaisingComponent.boom tone="nope-not-an-atom" />) <>
              ~s(<p>after</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-render-error="true"]))
      assert html =~ "could not render"

      # THE PAGE AROUND IT IS UNHARMED, which is the whole point — one bad component costs its own
      # box and nothing else.
      assert html =~ "after"
      assert Process.alive?(canvas.pid)

      # And it is still a node: selectable, so it can be inspected and deleted.
      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert has_element?(canvas, ~s([data-node-id="#{node.id}"]))

      render_click(view, "op", %{"kind" => "delete", "node_id" => node.id})

      assert Process.alive?(canvas.pid)
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # THE BOUND `contain/2` CANNOT GIVE. It covers every way a render can LEAVE; it cannot cover one
    # that does not leave, and a render allocating without limit takes the whole node rather than one
    # iframe. A heap ceiling is the only bound available without a second process, and a second
    # process is not available here — the sandbox does not cross one.
    test "the canvas runs under a heap ceiling, so a runaway render cannot take the node", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      {:max_heap_size, limit} = Process.info(canvas.pid, :max_heap_size)

      assert limit.size > 0, "an unbounded canvas is one component away from an unbounded node"
      assert limit.kill, "a ceiling that only logs is not a ceiling"

      # And it is nowhere near what an honest canvas uses, or it would be a new way to lose work.
      {:total_heap_size, used} = Process.info(canvas.pid, :total_heap_size)
      assert used < div(limit.size, 10)
    end

    # A `rescue` catches an exception and NOTHING ELSE. A component that throws, or that calls a
    # GenServer which is not running — an `exit`, and the likeliest of the three in a component that
    # talks to anything — went straight past the guard above and killed the canvas, which is the very
    # outcome that guard exists to prevent.
    for {function, leaving} <- [{"tossed", "throws"}, {"departed", "exits"}] do
      test "a component that #{leaving} leaves the canvas standing too", %{
        conn: conn,
        site: site
      } do
        page =
          create_page!(
            site_id: site.id,
            template:
              ~s(<div id="root">) <>
                ~s(<MishkaCmsCore.Test.RaisingComponent.#{unquote(function)} />) <>
                ~s(<p>after</p></div>)
          )

        {:ok, view, _html} = open_builder(conn, page)
        {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

        assert has_element?(canvas, ~s([data-render-error="true"]))
        assert html =~ "after", "the page around it is unharmed"
        assert Process.alive?(canvas.pid)
        assert Process.alive?(view.pid)
      end
    end

    test "layer rows are addressable as sortable items", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      assert has_element?(view, "#pb-layers[phx-hook='PbLayers']")
      assert has_element?(view, "[data-layer-id='#{section.id}']")
    end
  end

  # A COMPONENT'S INTERFACE, IN THE BUILDER. `attrs` and `slots` are columns on the component and
  # they drive nearly everything the page builder does with it — the Inspector's controls,
  # `.properties`, `.slots`, the required badges, the drop rules — and the builder could not edit
  # them at all. The only way in was the Components table form, where a slot's options are raw JSON.
  describe "the Interface tab" do
    defp open_component(conn, component) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      render_click(view, "open_source", %{})
      {:ok, view}
    end

    defp declarable(site) do
      create_component!(
        site_id: site,
        name: "declarable",
        template: ~s|<div class={@size}>{render_slot(@inner_block)}{@title}</div>|,
        attrs: [],
        slots: []
      )
    end

    test "is offered for a component and for nothing else", %{conn: conn, site: site, page: page} do
      {:ok, view} = open_component(conn, declarable(site.id))
      assert has_element?(view, "#pb-sourcetab-interface")

      {:ok, pages, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
      _loaded = render_async(pages)
      render_click(pages, "open_source", %{})

      refute has_element?(pages, "#pb-sourcetab-interface"),
             "a page takes no attributes and has no slots"
    end

    # A window headed "Page code" while it edits a component is lying about what it changes.
    test "and the window says which record it is editing", %{conn: conn, site: site, page: page} do
      {:ok, view} = open_component(conn, declarable(site.id))
      assert render(view) =~ "Component code"

      {:ok, pages, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
      _loaded = render_async(pages)
      render_click(pages, "open_source", %{})
      assert render(pages) =~ "Page code"
    end

    # THE CHECK THAT MATTERS MOST. A template reading `@size` with no `attr :size` compiles and then
    # raises `KeyError` the first time the component renders on somebody's page.
    test "names what the template reads and the component never declares", %{
      conn: conn,
      site: site
    } do
      {:ok, view} = open_component(conn, declarable(site.id))
      render_click(view, "source_tab", %{"tab" => "interface"})

      html = render(view)
      assert html =~ "does not declare them"
      assert has_element?(view, "#pb-interface-declare-attr-size")
      assert has_element?(view, "#pb-interface-declare-attr-title")
      assert has_element?(view, "#pb-interface-declare-slot-inner_block")
    end

    test "and declaring one writes it to the component", %{conn: conn, site: site} do
      component = declarable(site.id)
      {:ok, view} = open_component(conn, component)
      render_click(view, "source_tab", %{"tab" => "interface"})

      render_click(view, "declare_missing", %{"kind" => "attr", "name" => "size"})

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)
      assert Enum.any?(Interface.attrs(stored), &(&1["name"] == "size"))

      # And it stops being reported, because it is no longer missing.
      refute has_element?(view, "#pb-interface-declare-attr-size")
    end

    test "a slot is declared the same way", %{conn: conn, site: site} do
      component = declarable(site.id)
      {:ok, view} = open_component(conn, component)
      render_click(view, "source_tab", %{"tab" => "interface"})

      render_click(view, "declare_missing", %{"kind" => "slot", "name" => "inner_block"})

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)
      assert Enum.any?(Interface.slots(stored), &(&1["name"] == "inner_block"))
    end

    # THE FORM IS THE RESOURCE'S OWN. The first version of this tab was hand-rolled inputs beside a
    # `field :attrs, :nested` the resource had declared all along — two editors for one pair of
    # columns. This is the sixth `MishkaGervaz.Form.Web.Live` mount in the builder.
    test "the rows are the resource's own form, not a second one", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, declarable(site.id))
      render_click(view, "source_tab", %{"tab" => "interface"})

      # Gervaz names its own wrapper from the id it is mounted with.
      assert has_element?(view, "#pb-interface-form-form-wrapper")
      refute has_element?(view, ~s([name^="attr["])), "no hand-rolled rows"
    end

    # Every field but the two, asked of the form rather than listed — so a field added to the
    # resource tomorrow is hidden here without anyone remembering to come back.
    test "and it draws the interface columns and nothing else", %{conn: conn, site: site} do
      {:ok, view} = open_component(conn, declarable(site.id))
      render_click(view, "source_tab", %{"tab" => "interface"})

      hidden = Panels.interface_hidden_fields(MishkaCmsCore.Runtime.Component)

      refute :attrs in hidden
      refute :slots in hidden
      assert :name in hidden, "the component's own name belongs to the header, not here"
      assert :template in hidden, "the markup is what the canvas is for"
    end

    # The whole point of writing it here: the page builder reads it immediately.
    test "what is declared here is what a page then offers", %{conn: conn, site: site} do
      component = declarable(site.id)

      {:ok, _updated} =
        component
        |> Ash.Changeset.for_update(
          :update,
          %{attrs: [%{"name" => "size", "type" => "string", "opts" => %{"required" => true}}]},
          authorize?: false
        )
        |> Ash.update()

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="declarable" />|
        )

      {:ok, builder, _html} = open_builder(conn, page)
      node = needful_node(builder)

      assert builder |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "1 needed",
             "the required property it was just given"
    end

    # THE SAME SAVE AS THE COMPONENTS TABLE'S, and it lost the same things. The tab draws Required,
    # Default and Doc for an attribute, Required and Doc for a slot, and a flat row for each of a
    # slot's attributes, whose `required` and `doc` the record keeps under `opts`. Writing one doc
    # wrote back only what those controls held.
    test "a save keeps every option the form does not show", %{conn: conn, site: site} do
      slots = [
        %{
          "name" => "item",
          "opts" => %{"required" => false, "validate_attrs" => false, "doc" => "One entry"},
          "attrs" => [
            %{
              "name" => "title",
              "type" => "string",
              "opts" => %{"required" => true, "doc" => "Title of the entry"}
            },
            %{"name" => "kind", "type" => "string", "opts" => %{"values" => ["a", "b"]}}
          ]
        }
      ]

      component =
        create_component!(
          site_id: site.id,
          name: "shapes",
          template: every_option_template(),
          attrs: every_option_shape(),
          slots: slots
        )

      {:ok, view} = open_component(conn, component)
      render_click(view, "source_tab", %{"tab" => "interface"})
      render_async(view)

      view
      |> form("#pb-interface-form-form", %{
        "form" => %{"attrs" => %{"1" => %{"opts" => %{"doc" => "How big"}}}}
      })
      |> render_submit()

      stored = Ash.get!(MishkaCmsCore.Runtime.Component, component.id, authorize?: false)

      expected =
        Enum.map(every_option_shape(), fn
          %{"name" => "size"} = row -> put_in(row, ["opts", "doc"], "How big")
          row -> row
        end)

      assert Map.new(Interface.attrs(stored), &{&1["name"], &1["opts"]}) ==
               Map.new(expected, &{&1["name"], &1["opts"]})

      assert MishkaCmsCore.Runtime.Helpers.stringify_keys(stored.slots) == slots
    end
  end

  # THE SAME DECLARATION, AS THE FIRST ROW OF THE TREE. The Interface tab is where it is edited; the
  # rail is where it is SEEN, beside the markup that reads it. Before this the rail opened on a
  # component's elements with no mention of what the component takes — the one thing everything
  # below it depends on was the one thing with no row.
  describe "the .interface group in the layers rail" do
    defp declared_component(site) do
      create_component!(
        site_id: site,
        name: "declared",
        template: ~s|<div class={@size}>{render_slot(@inner_block)}</div>|,
        attrs: [%{"name" => "size", "type" => "string", "opts" => %{"required" => true}}],
        slots: [%{"name" => "inner_block"}, %{"name" => "actions"}]
      )
    end

    defp open_component_rail(conn, component) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      {:ok, view}
    end

    test "is drawn for a component, counting what it declares", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      assert has_element?(view, "#pb-interface-group")

      assert view |> element("#pb-interface-group") |> render() =~ "(3)",
             "one attribute and two slots"
    end

    # FIRST, which is what it was asked to be: a component's declaration comes before its markup the
    # way it does in the source, and reading the rail top to bottom should read the same way.
    test "before every element in the tree", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      html = render(view)
      group = :binary.match(html, "pb-interface-group") |> elem(0)
      first_row = :binary.match(html, "data-layer-row=") |> elem(0)

      assert group < first_row, "the group has to come before the first element row"
    end

    # A page takes no attributes and has no slots, so there is nothing here for it to be a view of.
    test "and nowhere else", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-interface-group")
    end

    # Folded until asked for, like `.properties` and `.markup` — it costs one row until then.
    test "folded, and opening it names what is declared", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      refute has_element?(view, "#pb-interface-attr-size")

      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      assert has_element?(view, "#pb-interface-attr-size")
      assert has_element?(view, "#pb-interface-slot-inner_block")
      assert has_element?(view, "#pb-interface-slot-actions")
    end

    # NAMED THE WAY THE MARKUP NAMES IT. `@size` and `<:actions>` are what somebody would type; the
    # column's spelling is this editor's business and not the reader's.
    test "written the way the markup writes them", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))
      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      rail = view |> element("#pb-interface-group") |> render()
      assert rail =~ ".interface"

      html = render(view)
      assert html =~ "@size"
      assert html =~ "&lt;:actions&gt;"
      assert html =~ "inner content", "the unnamed slot is written as what it holds"
    end

    test "marking the ones the component cannot do without", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))
      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      assert view |> element("#pb-interface-attr-size") |> render() =~ "required"
      refute view |> element("#pb-interface-slot-actions") |> render() =~ "required"
    end

    # A VIEW, NOT A SECOND EDITOR. Every row is a way into the form that owns these columns, and the
    # window opens on THAT tab rather than wherever it was last left.
    test "and every row opens the Interface tab", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))
      render_click(view, "toggle_expand", %{"id" => "iface:root"})

      view |> element("#pb-interface-attr-size") |> render_click()

      assert has_element?(view, "#pb-interface-form-form-wrapper"),
             "the Interface tab, not the Template one"
    end

    test "as does the pencil on the group itself", %{conn: conn, site: site} do
      {:ok, view} = open_component_rail(conn, declared_component(site.id))

      view |> element("#pb-interface-edit") |> render_click()

      assert has_element?(view, "#pb-interface-form-form-wrapper")
    end

    # Silence reads as "not loaded". A component that declares nothing says so.
    test "a component with nothing declared says so rather than showing an empty fold", %{
      conn: conn,
      site: site
    } do
      bare =
        create_component!(
          site_id: site.id,
          name: "bare-declaration",
          template: ~s|<div>hello</div>|,
          attrs: [],
          slots: []
        )

      {:ok, view} = open_component_rail(conn, bare)
      assert view |> element("#pb-interface-group") |> render() =~ "(0)"

      render_click(view, "toggle_expand", %{"id" => "iface:root"})
      assert render(view) =~ "nothing declared yet"
    end
  end

  # A COMPONENT MADE OUT OF OTHER COMPONENTS, which is what most of the kit is. Three things about
  # the inner node were wrong, and the first of them destroyed data.
  describe "a component that nests another" do
    defp nesting(site) do
      create_component!(
        site_id: site,
        name: "inner-one",
        template: ~s|<span class={@tone}>x</span>|,
        attrs: [%{"name" => "tone", "type" => "string"}],
        slots: []
      )

      create_component!(
        site_id: site,
        name: "outer-one",
        template:
          ~s|<div><.component component_name="inner-one" site="Global" tone={@mood} /></div>|,
        attrs: [%{"name" => "mood", "type" => "string"}],
        slots: []
      )
    end

    defp inner_node(view) do
      Enum.find(
        Tree.walk(editor(view).tree),
        &(&1.kind == :component and
            MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "inner-one")
      )
    end

    defp open_component_builder(conn, component) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      _loaded = render_async(view)
      {:ok, view}
    end

    # An attribute the outer component passes DOWN is an expression, and editing it through any
    # ordinary control posted the source back with no kind — so `tone={@mood}` became
    # `tone="@mood"`, a literal that looks identical in the panel and is bound to nothing.
    test "editing an inherited attribute keeps it bound", %{conn: conn, site: site} do
      outer = nesting(site.id)
      {:ok, view} = open_component_builder(conn, outer)
      node = inner_node(view)

      assert node, "the fixture has to nest the inner component"
      assert Node.attr(node, "tone") == {:expr, "@mood"}

      render_change(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node.id,
        "name" => "tone",
        "value" => "@mood_two"
      })

      assert Node.attr(inner_node(view), "tone") == {:expr, "@mood_two"}
      assert {:ok, heex} = Serializer.to_heex(editor(view).tree)
      assert heex =~ "tone={@mood_two}"
      refute heex =~ ~s(tone="@mood_two")
    end

    # And the panel says which boxes are bound, because `name={@icon}` and `name="hero-bolt"` drew
    # the same box — with a way to stop it being one on purpose.
    test "and says so, with a way out", %{conn: conn, site: site} do
      outer = nesting(site.id)
      {:ok, view} = open_component_builder(conn, outer)
      node = inner_node(view)

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      assert has_element?(view, "#pb-attr-literal-#{node.id}-tone")

      view |> element("#pb-attr-literal-#{node.id}-tone") |> render_click()

      assert Node.attr(inner_node(view), "tone") == {:string, "@mood"}
    end

    # A component that renders ITSELF is kept out of its own palette, so it could never be dropped
    # into itself — and the palette is also where the inspector looks for declarations, so its own
    # inner node drew a panel with no properties at all.
    test "a component that renders itself still knows what it declares", %{conn: conn, site: site} do
      recursive =
        create_component!(
          site_id: site.id,
          name: "recursive-one",
          template:
            ~s|<ul><.component component_name="recursive-one" site="Global" depth={@depth} /></ul>|,
          attrs: [%{"name" => "depth", "type" => "integer"}],
          slots: []
        )

      {:ok, view} = open_component_builder(conn, recursive)

      node =
        Enum.find(
          Tree.walk(editor(view).tree),
          &(&1.kind == :component and
              MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "recursive-one")
        )

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      assert has_element?(view, "#pb-attr-#{node.id}-depth"),
             "the declaration is on the record in hand"

      refute has_element?(view, "#pb-insp-edit-component"),
             "the Inspector offered to open the editor the author is already in"

      # And it is still kept out of the palette, which is what stops it being dropped into itself.
      refute has_element?(view, "#pb-comp-recursive-one"),
             "the recursion guard is the palette, and it still holds"
    end

    # THE RAIL HAS TO AGREE WITH THE PANEL. It counts what a node still needs from the same palette
    # the inspector reads, so a required property on a self-rendered component was never counted:
    # the panel said "required, empty" and the row beside it said nothing at all.
    test "and the rail counts what one of these still needs", %{conn: conn, site: site} do
      recursive =
        create_component!(
          site_id: site.id,
          name: "needful-self",
          template: ~s|<ul><.component component_name="needful-self" site="Global" /></ul>|,
          attrs: [%{"name" => "depth", "type" => "integer", "opts" => %{"required" => true}}],
          slots: []
        )

      {:ok, view} = open_component_builder(conn, recursive)

      node =
        Enum.find(
          Tree.walk(editor(view).tree),
          &(&1.kind == :component and
              MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "needful-self")
        )

      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "1 needed"
    end

    # A private helper — `<.badge_dismiss>` and twenty-two others across the kit — is declared in the
    # component's own `helpers` column, which the palette deliberately does not carry.
    test "and a private helper declares its own properties too", %{conn: conn, site: site} do
      holder =
        create_component!(
          site_id: site.id,
          name: "with-helper",
          template: ~s|<div><.badge_dismiss tone={@mood} /></div>|,
          attrs: [%{"name" => "mood", "type" => "string"}],
          slots: [],
          helpers: [
            %{
              "name" => "badge_dismiss",
              "args" => "assigns",
              "code" => "nil",
              "attrs" => [%{"name" => "tone", "type" => "string"}],
              "slots" => []
            }
          ]
        )

      {:ok, view} = open_component_builder(conn, holder)

      node =
        Enum.find(
          Tree.walk(editor(view).tree),
          &(&1.kind == :component and
              MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(&1) == "badge_dismiss")
        )

      assert node, "a dotted tag is a component node"

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      assert has_element?(view, "#pb-attr-#{node.id}-tone")

      refute has_element?(view, "#pb-insp-edit-component"),
             "a private helper is the component being edited, not another one to open"
    end

    test "and the one it nests opens in its own editor, with the way back here", %{
      conn: conn,
      site: site
    } do
      outer = nesting(site.id)
      {:ok, view} = open_component_builder(conn, outer)
      node = inner_node(view)

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})

      inner = view |> editor() |> Map.fetch!(:components) |> Enum.find(&(&1.name == "inner-one"))

      back =
        URI.encode_query(%{
          "return_to" => "/admin/dashboard/runtime/builder/component/#{outer.id}"
        })

      assert has_element?(
               view,
               ~s(#pb-insp-edit-component[href="/admin/dashboard/runtime/builder/component/#{inner.id}?#{back}"])
             )
    end
  end

  # THE ROUND TRIP. A component opened from a page's Inspector carries that page's builder in
  # `return_to`, and its back link goes there instead of to the component list. The address is
  # something a URL supplied, so only another builder is honoured — anything that could point the
  # back link off-site falls back to the list.
  describe "the way back from a component's editor" do
    defp back_link(conn, component, query) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}?#{query}")

      view
    end

    test "goes back to the builder it was opened from", %{conn: conn, site: site, page: page} do
      component = create_component!(site_id: site.id, name: "round-trip")
      page_builder = "/admin/dashboard/runtime/builder/page/#{page.id}"

      view = back_link(conn, component, URI.encode_query(%{"return_to" => page_builder}))

      assert has_element?(view, ~s(#pb-back[href="#{page_builder}"]))
    end

    test "and an error page's entry is kept on the way back", %{conn: conn, site: site} do
      component = create_component!(site_id: site.id, name: "round-trip-status")
      entry = "/admin/dashboard/runtime/builder/error-page/#{Ecto.UUID.generate()}?status=500"

      view = back_link(conn, component, URI.encode_query(%{"return_to" => entry}))

      assert has_element?(view, ~s(#pb-back[href="#{entry}"]))
    end

    test "but never anywhere that is not a builder", %{conn: conn, site: site} do
      component = create_component!(site_id: site.id, name: "round-trip-refused")

      for elsewhere <- [
            "//evil.example/admin/dashboard/runtime/builder/page/x",
            "https://evil.example/admin/dashboard/runtime/builder/page/x",
            "/admin/dashboard/runtime/components/../../../elsewhere",
            "javascript:alert(1)",
            ""
          ] do
        view = back_link(conn, component, URI.encode_query(%{"return_to" => elsewhere}))

        assert has_element?(view, ~s(#pb-back[href="/admin/dashboard/runtime/components"])),
               "#{inspect(elsewhere)} was honoured as a way back"
      end

      view = back_link(conn, component, "")
      assert has_element?(view, ~s(#pb-back[href="/admin/dashboard/runtime/components"]))
    end
  end

  # A TAB THE SAVE WILL THROW AWAY IS WORSE THAN NO TAB. `events` and `infos` are Page columns; a
  # Layout, a Component and an error page have `helpers` and nothing else. `code_keys/1` has always
  # asked the resource and dropped the rest, so a handler typed on a layout was written nowhere and
  # then flashed as "Saved to the layout" — the window and the writer disagreed, and the writer won
  # silently.
  describe "the code window offers only the tabs the record has a column for" do
    defp open_code(conn, path) do
      {:ok, view, _html} = live(conn, path)
      _loaded = render_async(view)
      render_click(view, "open_source", %{})
      {:ok, view}
    end

    test "a page has handlers and messages", %{conn: conn, page: page} do
      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert has_element?(view, "#pb-sourcetab-events")
      assert has_element?(view, "#pb-sourcetab-infos")
      assert has_element?(view, "#pb-sourcetab-helpers")
    end

    test "a layout has helpers and neither of the other two", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "tabbed-shell",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert has_element?(view, "#pb-sourcetab-helpers")
      refute has_element?(view, "#pb-sourcetab-events"), "a layout holds no handlers"
      refute has_element?(view, "#pb-sourcetab-infos"), "nor any messages"
    end

    test "and neither does a component", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "tabbed-one",
          template: ~s|<div>x</div>|,
          attrs: [],
          slots: []
        )

      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert has_element?(view, "#pb-sourcetab-helpers")
      refute has_element?(view, "#pb-sourcetab-events")
      refute has_element?(view, "#pb-sourcetab-infos")
    end

    # The columns decide it, so the answer is read off the resource rather than off a list of
    # section names kept somewhere near the window.
    test "which is the resource's own answer, not a list kept here", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "tabbed-shell-two",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      {:ok, view} = open_code(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      for key <- [:events, :infos] do
        assert is_nil(Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Layout, key)),
               "the fixture only means something while a Layout has no #{key}"

        refute has_element?(view, "#pb-sourcetab-#{key}")
      end

      assert Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Layout, :helpers)
      assert has_element?(view, "#pb-sourcetab-helpers")
    end
  end

  # WHAT THE DOCUMENT CAN ACTUALLY DO. Three of the four are rendered by a LiveView; an error page is
  # rendered by a controller, and `phx-click` and `phx-hook` are attached by the LiveView client
  # against a view. With no view owning that DOM the binding never attaches, so the panel was
  # offering a click that cannot fire.
  describe "bindings are offered only where a LiveView owns the DOM" do
    defp select_first_tag(view) do
      node = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :tag))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})
      node
    end

    test "a page offers On click and a JS hook", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      select_first_tag(view)

      assert has_element?(view, "#pb-act-toggle")
      assert has_element?(view, "#pb-hook-toggle")
    end

    test "and an error page offers neither", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          name: "bindingless",
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => ~s(<div id="oops">Not found</div>)}]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      _loaded = render_async(view)
      select_first_tag(view)

      refute has_element?(view, "#pb-act-toggle"), "a controller renders this, not a LiveView"
      refute has_element?(view, "#pb-hook-toggle")
    end
  end

  # The three form blocks ship `phx-change` and `phx-submit` bound to handlers, and only a Page has
  # an `events` column to hold one.
  describe "the blocks a section can use" do
    test "a page is offered the form blocks", %{conn: _conn} do
      ids = Enum.map(Blocks.for_section("page"), & &1.id)

      assert "form-contact" in ids
      assert "form-newsletter" in ids
    end

    test "and a layout, a component and an error page are not" do
      for section <- ~w(layout component error-page) do
        ids = Enum.map(Blocks.for_section(section), & &1.id)

        refute "form-contact" in ids, section
        refute "form-fieldset" in ids, section
        refute "form-newsletter" in ids, section

        assert "hero-split" in ids or ids != [],
               "everything else still belongs everywhere"
      end
    end

    # The same rule the elements already follow, so the exception has to be declared rather than
    # inferred from a category name.
    test "a block that declares no sections belongs everywhere" do
      everywhere = Enum.reject(Blocks.all(), &Map.has_key?(&1, :sections))

      for section <- ~w(page layout component error-page) do
        ids = Enum.map(Blocks.for_section(section), & &1.id)
        assert Enum.all?(everywhere, &(&1.id in ids)), section
      end
    end
  end

  # THE FORM MACHINERY IS THE PAGE'S. Every control in the Form section writes `phx-change`,
  # `phx-submit` or the `for=` they are bound through, and two of the Validation controls write
  # `data-format` / `data-confirms`, which nothing checks but the page's own form runtime. The other
  # six validation controls are HTML attributes a browser enforces on its own, everywhere.
  describe "the form controls a section can use" do
    # A field only counts as validated when it is BOUND through the form's `:let` — a bare
    # `<input name="email">` is markup, not a form field, so this is the shape the form blocks ship.
    @bound_form ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><.input field={f[:email]} type="email" required /></.form>)

    defp bound_field(view) do
      node = Enum.find(Tree.walk(editor(view).tree), &(&1.tag == ".input"))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node.id})
      render(view)
    end

    test "a page gets the Form section and every validation rule", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: "<div>#{@bound_form}</div>")
      {:ok, view, _html} = open_builder(conn, page)

      html = bound_field(view)

      assert html =~ "Pattern", "an HTML rule the browser enforces"
      assert html =~ "Confirms", "and one only the page's own form runtime checks"
    end

    test "a layout keeps the browser's rules and loses the other two", %{conn: conn, site: site} do
      layout =
        create_layout!(
          name: "formish-shell",
          site_id: site.id,
          template: ~s(<div id="shell">#{@bound_form}{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _loaded = render_async(view)

      html = bound_field(view)

      assert html =~ "Pattern", "the browser-enforced rules belong everywhere"
      refute html =~ "Confirms", "nothing on a layout reads data-confirms"
      refute html =~ "Format", "nor data-format"
    end

    # Asked of the resource, so the answer follows the columns rather than a list kept in the panel.
    test "and the question asked is which resource holds handlers" do
      assert Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Page, :events)

      for resource <- [
            MishkaCmsCore.Runtime.Layout,
            MishkaCmsCore.Runtime.Component,
            MishkaCmsCore.Runtime.ErrorPage
          ] do
        refute Ash.Resource.Info.attribute(resource, :events),
               "#{inspect(resource)} holds no handlers, so it gets no form controls"
      end
    end
  end

  # THE STUDIO OPENS, AND THEN ITS CONTENTS ARRIVE. Everything the sheet shows was read before
  # anything could paint — a stylesheet parse and a kit-bundle parse, 10.8 MB of JSON for Chelekom
  # alone — so pressing Studio did nothing at all until they finished. The tests here needed
  # `render_async` the moment that changed, which is the clearest statement of what the reader was
  # waiting for.
  describe "the Studio loads off the click that opens it" do
    test "the sheet is there before its data is", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      opened = render_click(view, "open_sheet", %{"sheet" => "studio"})

      assert opened =~ "pb-studio-skeleton", "the shape of what is coming"
      assert has_element?(view, "#pb-studio-tokens"), "and the tabs are live already"
      refute opened =~ "pb-token-export", "while the contents are not here yet"
    end

    test "and the skeleton gives way to the real thing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})

      loaded = render_async(view, 5_000)

      refute loaded =~ "pb-studio-skeleton"
      assert has_element?(view, "#pb-token-export")
    end

    # A read that fails is an empty Studio, not a dead editor — so the shape it falls back to has to
    # carry every key the sheet reads. One key added to the loader and forgotten there is a KeyError
    # in a render, which takes the whole editor down rather than one sheet.
    test "and the shape it falls back to answers everything the sheet asks" do
      empty = Panels.empty_studio_data()

      for key <- [:tokens, :token_categories, :presets, :packages, :package_categories] do
        assert Map.fetch(empty, key) == {:ok, []}, "the failed read still has to answer #{key}"
      end
    end
  end

  # NOT A LIST WRITTEN OUT BY HAND. The Registry's chips named `data`, `input`, `layout` and
  # `marketing`; the kit's components are typed `general`, `forms`, `navigations`, `media`,
  # `feedback` and `overlays`. Four of six chips matched nothing, and picking one showed an empty
  # registry under the words "everything is already installed".
  describe "the Registry's categories come from the catalogue" do
    test "they are the kit's own types, not an invented list" do
      categories = Marketplace.package_categories(%{})

      refute "data" in categories, "no component has ever had this type"
      refute "input" in categories
      refute "layout" in categories
      refute "marketing" in categories
    end

    # Whatever the adapter is, the chips describe the packages it actually returns.
    test "and every category offered is one some package really has" do
      offered = MapSet.new(Marketplace.package_categories(%{}))

      real =
        %{category: "all"}
        |> Marketplace.packages()
        |> Enum.map(& &1.category)
        |> MapSet.new()

      assert MapSet.subset?(real, offered),
             "a package whose category has no chip cannot be filtered to"
    end

    # An adapter written before `package_categories/1` existed still gets chips that match its data.
    test "an adapter that cannot answer is asked its packages instead" do
      Application.put_env(:mishka_cms_core, :builder_marketplace, Marketplace.Mock)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      refute MishkaGervaz.Helpers.exports?(Marketplace.Mock, :package_categories, 1),
             "the fallback only means something while Mock has no answer of its own"

      derived = Marketplace.package_categories(%{})
      from_packages = %{} |> Marketplace.packages() |> Enum.map(& &1.category) |> Enum.uniq()

      assert Enum.sort(derived) == Enum.sort(from_packages)
    end
  end

  describe "durability" do
    # Reopening the same document used to mint a new token and rebuild from the database. The session
    # outlives a reload — that is what stops a refresh throwing the sitting away — and this is the
    # lookup that finds it. What the session is POINTED AT is a separate question, answered by the
    # two tests below.
    test "reopening the page resumes the session instead of starting a new one", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      h1 = node_with_tag(first, "h1")
      render_click(first, "op", %{"kind" => "delete", "node_id" => h1.id})
      token = token(first)

      {:ok, second, _html} = open_builder(conn, page)

      assert token(second) == token
    end

    # OPENING IS THE LIVE PAGE, ALWAYS. Once autosave has put the work in a draft, reopening lands on
    # the live record and OFFERS that draft by name — walking back in and silently being somewhere
    # other than the live page is what the draft model exists to avoid. The session itself is still
    # the same one; only what it is pointed at changed.
    test "reopening a session that was in a draft lands on the live page", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      h1 = node_with_tag(first, "h1")
      render_click(first, "op", %{"kind" => "delete", "node_id" => h1.id})
      render_click(first, "apply_stage", %{})

      {:ok, second, _html} = open_builder(conn, page)

      assert node_with_tag(second, "h1"), "the live page came back"
      assert has_element?(second, "#pb-inherited-bar")
      assert has_element?(second, "#pb-inherited-continue")
    end

    # AND CARRY ON ACTUALLY CARRIES ON. It used to only dismiss the bar — the session had already
    # been resumed into the draft before the bar rendered, so the button had nothing left to do and
    # looked broken.
    test "and Carry on opens the draft it named", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      h1 = node_with_tag(first, "h1")
      render_click(first, "op", %{"kind" => "delete", "node_id" => h1.id})
      render_click(first, "apply_stage", %{})

      {:ok, second, _html} = open_builder(conn, page)
      assert node_with_tag(second, "h1")

      second |> element("#pb-inherited-continue") |> render_click()

      assert is_nil(node_with_tag(second, "h1")), "the draft's own work is back"
      refute has_element?(second, "#pb-inherited-bar")
    end

    test "a different document still opens its own session", %{conn: conn, page: page, site: site} do
      other = create_page!(site_id: site.id, template: "<section><h2>Other</h2></section>")
      {:ok, first, _html} = open_builder(conn, page)
      {:ok, second, _html} = open_builder(conn, other)

      refute token(second) == token(first)
    end
  end

  describe "drafts" do
    test "save as writes a NAMED draft and the editor switches to it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "save_as_draft", %{"label" => "  Black Friday  "})

      editor = editor(view)
      assert editor.draft_label == "Black Friday"
      assert is_binary(editor.draft_id)

      # And it is listed, so it can be reopened.
      render_click(view, "draft_sheet", %{})
      _listed = render_async(view)
      assert has_element?(view, "#pb-draft-#{editor.draft_id}")
    end

    # Arriving at the tab is a route to the list like any other. It used to only switch the view, so a
    # page whose resume bar was offering unsaved work showed "No drafts yet" one click away.
    test "reaching the Drafts tab by the tab loads them", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "By tab"})
      draft_id = editor(view).draft_id

      # Open the sheet on Record history, the way the toolbar button does, then switch.
      render_click(view, "open_sheet", %{"sheet" => "history"})
      refute has_element?(view, "#pb-draft-#{draft_id}")

      render_click(view, "history_tab", %{"tab" => "drafts"})
      _listed = render_async(view)
      assert has_element?(view, "#pb-draft-#{draft_id}")
    end

    # Full access: a draft can be opened, copied, or thrown away.
    test "a draft can be forked into a new one", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "Promo"})
      original = editor(view).draft_id

      render_click(view, "history_tab", %{"tab" => "drafts"})
      render_click(view, "fork_draft", %{"id" => original})

      actor = :sys.get_state(view.pid).socket.assigns.current_user
      labels = "page" |> Drafts.list(page, actor) |> Enum.map(& &1.label)

      assert "Promo" in labels
      assert "Promo copy" in labels
      # The copy is a NEW row; the original is untouched and still the target.
      assert editor(view).draft_id == original

      # A second fork does not collide with the first copy.
      render_click(view, "fork_draft", %{"id" => original})
      labels = "page" |> Drafts.list(page, actor) |> Enum.map(& &1.label)
      assert "Promo copy 2" in labels
    end

    test "a draft can be deleted, and stops being the save target", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "Throwaway"})
      draft_id = editor(view).draft_id

      render_click(view, "history_tab", %{"tab" => "drafts"})
      render_click(view, "delete_draft", %{"id" => draft_id})
      _refreshed = render_async(view)

      refute has_element?(view, "#pb-draft-#{draft_id}")
      assert is_nil(editor(view).draft_id), "the deleted draft is no longer the save target"
      assert is_nil(editor(view).draft_label)

      actor = :sys.get_state(view.pid).socket.assigns.current_user
      refute Enum.any?(Drafts.list("page", page, actor), &(&1.id == draft_id))
    end

    # Opening a panel must never wait on a database read — it opens with its own shape and fills in.
    test "the drafts list loads asynchronously behind a skeleton", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "Async"})
      draft_id = editor(view).draft_id

      html = render_click(view, "draft_sheet", %{})

      # The panel is open immediately, and never claims "no drafts" while it does not yet know.
      assert html =~ "Name this draft"
      refute html =~ "No drafts yet"
      refute html =~ "pb-draft-#{draft_id}"

      # The read happens off the click — awaiting it is what makes the rows appear.
      assert render_async(view) =~ "pb-draft-#{draft_id}"
    end

    # A name already taken is never silently overwritten.
    test "a repeated name asks before overwriting", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "Promo"})
      first_id = editor(view).draft_id

      render_click(view, "draft_sheet", %{})
      html = render_click(view, "save_as_draft", %{"label" => "Promo"})

      assert html =~ "already exists"
      # Nothing was written until the author chooses.
      assert editor(view).draft_id == first_id

      render_click(view, "save_as_draft", %{"label" => "Promo", "draft_id" => first_id})
      assert editor(view).draft_id == first_id
    end

    test "an empty name is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      html = render_click(view, "save_as_draft", %{"label" => "   "})

      assert html =~ "Give the draft a name"
      assert is_nil(editor(view).draft_label)
    end

    # Opening a draft replaces the working tree AND moves the save target, together — a target that
    # moved without the content, or content without the target, is how work lands in the wrong row.
    test "opening a draft loads its content and retargets saves", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      # The first change makes this session's own draft, and it is the one being written.
      h1 = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      _written = render_async(view)
      without_h1 = editor(view).draft_id
      assert is_binary(without_h1)

      # "Save as" forks a SECOND draft and points the session at it, so the undo below lands there.
      render_click(view, "save_as_draft", %{"label" => "Alt"})
      assert editor(view).draft_id != without_h1
      undo!(view)
      _written = render_async(view)
      assert node_with_tag(view, "h1")

      render_click(view, "draft_sheet", %{})
      render_click(view, "open_draft", %{"id" => without_h1})

      refute node_with_tag(view, "h1"), "the other draft's own content came back"
      assert editor(view).draft_id == without_h1
    end

    # One autosave row per document, reused across sessions. Every session that opened without a
    # draft id used to create another, and the picker filled with a column of "Autosave".
    test "autosave reuses its own row instead of adding one per session", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      h1 = node_with_tag(first, "h1")
      render_click(first, "op", %{"kind" => "delete", "node_id" => h1.id})
      _written = render_async(first)
      first_id = editor(first).draft_id
      assert is_binary(first_id), "the first change wrote a draft"

      # A brand new session on the same page — no draft id of its own.
      EditorSession.close(token(first))
      {:ok, second, _html} = open_builder(conn, page)

      # A draft is written by a CHANGE, so the second session has to make one.
      render_click(second, "op", %{
        "kind" => "delete",
        "node_id" => node_with_tag(second, "h1").id
      })

      _written = render_async(second)

      assert is_binary(editor(second).draft_id)
      assert editor(second).draft_id != first_id, "a sitting keeps its own row"

      actor = :sys.get_state(second.pid).socket.assigns.current_user
      labels = "page" |> Drafts.list(page, actor) |> Enum.map(& &1.label)

      assert length(labels) == 2
      assert Enum.all?(labels, &String.starts_with?(&1, "Draft · ")), inspect(labels)
    end

    # THE DRAFT SAYS WHEN ITS ORIGINAL MOVED ON. A notice, not a block: publishing still writes the
    # draft over what changed, and the author is the one to decide.
    test "a draft whose page was changed after it was made says so when it is opened again", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      draft_id = autosave!(first)
      refute has_element?(first, "#pb-original-changed")
      EditorSession.close(token(first))

      page
      |> Ash.Changeset.for_update(:update, %{title: "Changed elsewhere"},
        tenant: page.site_id,
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      {:ok, view, _html} = open_builder(conn, page)
      refute has_element?(view, "#pb-original-changed")

      render_click(view, "open_draft", %{"id" => draft_id})
      assert has_element?(view, "#pb-original-changed")
    end

    # A save shares the row with whatever draft is open, so it must not rename it.
    test "autosave keeps the name of the draft being edited", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "Keep me"})

      send(view.pid, :autosave)
      _rendered = render_async(view)

      assert editor(view).draft_label == "Keep me"
    end

    test "drafts of another document are not listed", %{conn: conn, page: page, site: site} do
      other = create_page!(site_id: site.id, template: @template)

      {:ok, elsewhere, _html} = open_builder(conn, other)
      render_click(elsewhere, "save_as_draft", %{"label" => "Somewhere else"})
      elsewhere_id = editor(elsewhere).draft_id

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "Right here"})
      own_id = editor(view).draft_id

      render_click(view, "draft_sheet", %{})
      html = render_async(view)

      assert html =~ "pb-draft-#{own_id}"
      refute html =~ "pb-draft-#{elsewhere_id}"
    end

    # The four selected/unselected treatments are the sheet's visual contract, and a restyle that
    # keeps the ids can still lose them. Each pairs the row's base classes with the branch, so the
    # assertion cannot be satisfied by the top-bar chip, which shares the selected palette.
    test "a row keeps both of its treatments and the list keeps its spacing", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "save_as_draft", %{"label" => "Older"})
      render_click(view, "save_as_draft", %{"label" => "Being edited"})

      render_click(view, "draft_sheet", %{})
      html = render_async(view)

      assert html =~ "border px-3 py-2.5 border-[#dcdbf5] bg-[#f2f1fc]"
      assert html =~ "rounded-[8px] bg-[#e4e2f7] text-[#4f4bcc]"
      assert html =~ "text-[12px] font-bold text-[#2e2b6b]"
      assert html =~ "tracking-[0.08em] text-[#4f4bcc]"

      assert html =~ "border px-3 py-2.5 border-[#ecebe6] bg-white hover:bg-[#f7f6f3]"
      assert html =~ "rounded-[8px] bg-[#f2f1ec] text-[#6d6a63]"
      assert html =~ "text-[12px] font-semibold text-[#1b1a18]"

      assert html =~ "rounded-[7px] text-[#a8a5a0] hover:bg-white hover:text-[#4f4bcc]"
      assert html =~ "rounded-[7px] text-[#a8a5a0] hover:bg-white hover:text-[#c0392b]"
      assert html =~ "Delete the draft “Being edited”? This cannot be undone."
      assert html =~ "flex flex-col gap-1.5"
    end

    test "an empty list says so, in its own words", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "draft_sheet", %{})
      html = render_async(view)

      # The empty state is the shared card scaffold's now, not hand-written markup, so the contract
      # is the SENTENCE — the classes belong to the scaffold and are its to change.
      assert html =~ "No drafts yet. “Save as” keeps one you can come back to."
    end
  end

  # Work a previous session left behind, offered rather than loaded. The bar reads the same rows the
  # drafts list does, and had no coverage at all.
  describe "resume bar" do
    test "an autosave newer than the page offers a resume bar", %{conn: conn, page: page} do
      {_autosave_id, view} = resumable_session(conn, page)

      assert has_element?(view, "#pb-resume-bar")
      assert has_element?(view, "#pb-resume")
      assert has_element?(view, "#pb-resume-discard")
    end

    # TWO BANNERS IN A ROW FOR ONE SITUATION. A disconnected mount BUILDS a session rather than
    # resuming one, so it cannot know it walked back into a draft: `inherited_draft` is nil, this
    # bar's guard passes, and the amber bar paints for one frame before the connected mount replaces
    # it with the violet one. The static render has no business answering this question at all — it
    # does not know the answer — so it does not ask it, and skips the drafts query with it.
    test "the static render offers neither bar", %{conn: conn, page: page} do
      resumable_session(conn, page)

      html = conn |> get("/admin/dashboard/runtime/builder/page/#{page.id}") |> html_response(200)

      refute html =~ "pb-resume-bar"
      refute html =~ "pb-inherited-bar"
    end

    test "resuming opens that draft and retargets saves", %{conn: conn, page: page} do
      {autosave_id, view} = resumable_session(conn, page)

      render_click(view, "resume_autosave", %{})

      assert editor(view).draft_id == autosave_id
      refute has_element?(view, "#pb-resume-bar")
    end

    test "discarding deletes the row, not just the bar", %{conn: conn, page: page} do
      {_autosave_id, view} = resumable_session(conn, page)

      render_click(view, "discard_autosave", %{})
      actor = :sys.get_state(view.pid).socket.assigns.current_user

      refute has_element?(view, "#pb-resume-bar")
      assert Drafts.list("page", page, actor) == []
    end

    test "deleting the resumable draft clears the bar", %{conn: conn, page: page} do
      {autosave_id, view} = resumable_session(conn, page)

      render_click(view, "delete_draft", %{"id" => autosave_id})
      _refreshed = render_async(view)

      refute has_element?(view, "#pb-resume-bar")
    end

    # THE BAR IS ABOUT THE LIVE PAGE, so it has nothing to say once a draft is the target. Every word
    # of it is wrong then — you are not looking at the live page — and Resume would swap the draft
    # you deliberately chose for a different one.
    # WALKING BACK INTO A DRAFT. The session outlives a reload, so reopening the page used to put you
    # silently inside whatever draft was open — showing something other than the live page and saying
    # nothing. It asks once per visit instead.
    test "reopening a page that had a draft open asks before carrying on", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      draft_id = autosave!(first)
      assert is_binary(draft_id)

      again = reopen(first, conn, page)

      assert has_element?(again, "#pb-inherited-bar")
      assert has_element?(again, "#pb-inherited-continue")
      assert has_element?(again, "#pb-inherited-fresh")
      assert render(again) =~ "You were working in"
    end

    test "carrying on keeps writing to the same draft", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      draft_id = autosave!(first)

      again = reopen(first, conn, page)
      again |> element("#pb-inherited-continue") |> render_click()

      refute has_element?(again, "#pb-inherited-bar")
      assert editor(again).draft_id == draft_id
    end

    # THE BAR ASKS "WHICH DOCUMENT DO YOU WANT?", and opening any draft answers it — however it was
    # answered. Only the Carry-on BUTTON used to clear it, so choosing a different draft from the
    # drafts sheet left the offer standing over a document the author had just moved past, still
    # pointing at the one they had navigated away from. Clicking it then took them backwards.
    test "choosing a different draft puts the carry-on bar away", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      inherited = autosave!(first)

      # A second, deliberately named draft to pick instead.
      render_click(first, "save_as_draft", %{"label" => "The other one"})
      _written = render_async(first)

      actor = actor(first)
      other = Drafts.list("page", page, actor) |> Enum.find(&(&1.label == "The other one"))
      assert other && other.id != inherited

      again = reopen(first, conn, page)

      assert has_element?(again, "#pb-inherited-bar"),
             "the fixture has to start with the offer up"

      # Not the button — the drafts sheet, which is the route that was broken.
      render_click(again, "open_draft", %{"id" => other.id})

      refute has_element?(again, "#pb-inherited-bar"),
             "the offer outlived the choice it was asking about"

      assert editor(again).draft_id == other.id
    end

    # START AGAIN means "not that one", never "throw that away" — the draft stays in the list, and
    # the document comes back from the live record.
    test "starting fresh detaches from the draft without deleting it", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      draft_id = autosave!(first)
      refute node_with_tag(first, "h1"), "the draft has the h1 deleted"

      again = reopen(first, conn, page)
      recorded = actor(again)
      again |> element("#pb-inherited-fresh") |> render_click()

      refute has_element?(again, "#pb-inherited-bar")
      assert editor(again).draft_id == nil, "the next change starts a new one"
      assert node_with_tag(again, "h1"), "the live page is back"

      assert Enum.any?(Drafts.list("page", page, recorded), &(&1.id == draft_id)),
             "and the old draft is still there"
    end

    test "a change after starting fresh writes a NEW draft", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      old = autosave!(first)

      again = reopen(first, conn, page)
      recorded = actor(again)
      again |> element("#pb-inherited-fresh") |> render_click()

      render_click(again, "op", %{"kind" => "delete", "node_id" => node_with_tag(again, "p").id})
      _written = render_async(again)

      assert editor(again).draft_id != old

      labels = "page" |> Drafts.list(page, recorded) |> Enum.map(& &1.label)
      assert length(labels) == 2, "drafts: #{inspect(labels)}"
    end

    # A session with nothing written to it has nothing to ask about.
    test "reopening an untouched page asks nothing", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      again = reopen(first, conn, page)

      refute has_element?(again, "#pb-inherited-bar")
    end

    test "choosing a draft from the list puts the bar away", %{conn: conn, page: page} do
      {_autosave_id, view} = resumable_session(conn, page)
      assert has_element?(view, "#pb-resume-bar")

      render_click(view, "save_as_draft", %{"label" => "Tuesday's attempt"})
      _written = render_async(view)
      chosen = editor(view).draft_id

      assert is_binary(chosen)
      refute has_element?(view, "#pb-resume-bar")
    end

    # AND THE CHIP FOLLOWS THE TARGET. Choosing a draft is choosing where the work goes; a chip left
    # on Publish would sit above a draft it refuses to write to.
    test "choosing a draft puts the chip back on Draft", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)

      render_click(view, "set_stage", %{"stage" => "published"})
      assert :sys.get_state(view.pid).socket.assigns.stage == :published

      render_click(view, "open_draft", %{"id" => draft_id})

      assert :sys.get_state(view.pid).socket.assigns.stage == :draft
      assert view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"

      # ONE WRITE, NOT TWO. The stage used to be a second `set_stage/2` call — a second ETS read
      # copying the whole tree out, a second write, and a second broadcast to every canvas frame for
      # one click, on the path already reported as slow.
      assert editor(view).stage == :draft
    end

    # THE FRAME NEVER NAVIGATES ON A SWAP, so its own loading state can never come back. `FrameLoader`
    # hides the spinner on the iframe's `load`, which fires exactly once; opening a draft replaces
    # the whole document inside a frame that stays where it is, and the author looked at the OLD page
    # for as long as the new one took to render. Reported as "the page stuck until it loads".
    test "opening a draft raises the canvas busy overlay, carrying the revision to settle it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)

      render_click(view, "open_draft", %{"id" => draft_id})

      assert_push_event(view, "pb:frame-busy", %{label: label, revision: revision})
      assert label =~ "Opening"
      assert is_integer(revision)

      # The revision travels so the overlay is settled by the canvas painting THAT document — the
      # editor's own re-render answers first otherwise, and the spinner would blink out before
      # anything had changed.
      assert revision == editor(view).revision
    end

    test "reverting a step raises it too, because that is a document swap as well", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~s(<p>a step to revert</p>),
        "parent_id" => section.id,
        "index" => "0"
      })

      render_click(view, "revert", %{"index" => "0"})

      assert_push_event(view, "pb:frame-busy", %{label: label})
      assert label =~ "Reverting"
    end

    # THE FIFTEEN SECONDS, AND IT WAS A TIMEOUT RATHER THAN A RENDER.
    #
    # `revision` is how anything downstream tells one document from the next. The canvas publishes
    # the revision it has painted; the editor's frame overlay raises on the click and waits to hear
    # that number back. `edit_draft/3` replaced the entire tree without counting it as a move, so
    # the canvas had nothing to announce, the overlay was never told the swap had landed, and it sat
    # until its own fifteen-second failsafe gave up — on a 1918-byte draft whose every measured
    # server stage is under a second.
    test "opening a draft counts as a move, so the canvas can say it has painted it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)

      before = editor(view).revision

      render_click(view, "open_draft", %{"id" => draft_id})

      after_open = editor(view).revision

      assert after_open > before,
             "the tree was replaced and the revision did not move — the canvas cannot announce it"

      # And the overlay is told to wait for exactly that number.
      assert_push_event(view, "pb:frame-busy", %{revision: revision})
      assert revision == after_open
    end

    # A PUBLISHED DRAFT IS SPENT. Its content IS the live page now, so leaving the row behind fills
    # the list with copies of things already finished — and the bar would keep offering work that has
    # nowhere left to go.
    test "publishing deletes the draft it published", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      draft_id = autosave!(view)
      assert is_binary(draft_id)

      actor = :sys.get_state(view.pid).socket.assigns.current_user
      assert Enum.any?(Drafts.list("page", page, actor), &(&1.id == draft_id))

      publish!(view)

      refute Enum.any?(Drafts.list("page", page, actor), &(&1.id == draft_id))
      refute editor(view).draft_id
      refute has_element?(view, "#pb-resume-bar")
    end

    # AND THE NEXT CHANGE STARTS A NEW ONE, rather than reviving what was just published. Publishing
    # is an act, not a mode to stay in: the chip falls back to Draft, so the work that follows is
    # kept the way all unpublished work is.
    test "editing after a publish opens a fresh draft", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      first = autosave!(view)
      publish!(view)

      assert render(view) =~ "Draft", "the chip goes back to Draft once the page is live"

      render_click(view, "op", %{
        "kind" => "delete",
        "node_id" => node_with_tag(view, "p").id
      })

      _written = render_async(view)

      assert is_binary(editor(view).draft_id)
      assert editor(view).draft_id != first
    end

    # Published or superseded work is no longer news, and a bar that keeps offering it is one people
    # learn to click past.
    test "a draft older than the page is not offered", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      autosave!(first)
      publish!(first)
      EditorSession.close(token(first))

      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-resume-bar")
    end
  end

  # ARRIVING WITH THE ANSWER ALREADY GIVEN. The preview modal's drafts strip is a picker, and its
  # Visual Editor button leaves for the builder — but the choice used to stay behind on the modal.
  # The editor read the drafts table for itself and offered whichever was newest, so picking the
  # second badge and clicking through landed on an offer to carry on with the first.
  describe "a draft named in the URL" do
    defp open_with_draft(conn, page, draft_id) do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?draft_id=#{draft_id}")

      _loaded = render_async(view)
      view
    end

    # Two drafts of one page, deliberately named, so "the newest" and "the one I picked" are
    # different rows and a test cannot pass by accident.
    defp two_drafts(conn, page) do
      {:ok, first, _html} = open_builder(conn, page)
      render_click(first, "save_as_draft", %{"label" => "The older one"})
      _written = render_async(first)

      render_click(first, "save_as_draft", %{"label" => "The newer one"})
      _written = render_async(first)

      actor = actor(first)
      EditorSession.close(token(first))

      by_label =
        "page" |> Drafts.list(page, actor) |> Map.new(&{&1.label, &1})

      {first, Map.fetch!(by_label, "The older one"), Map.fetch!(by_label, "The newer one")}
    end

    test "is the one the bar offers, even when it is not the newest", %{conn: conn, page: page} do
      {first, older, newer} = two_drafts(conn, page)
      GenServer.stop(first.pid)

      view = open_with_draft(conn, page, older.id)

      assert has_element?(view, "#pb-inherited-bar")
      html = render(view)
      assert html =~ "You picked “The older one”"
      refute html =~ newer.label
    end

    # The sentence has to change with the arrival. "You were working in" is news about the last
    # sitting; said about a draft chosen ten seconds ago on the previous screen it reads like the
    # editor misunderstood the click.
    test "asks in the words of the click that got here", %{conn: conn, page: page} do
      {first, older, _newer} = two_drafts(conn, page)
      GenServer.stop(first.pid)

      view = open_with_draft(conn, page, older.id)
      html = render(view)

      refute html =~ "You were working in"
      assert html =~ "Open it"
      assert html =~ "Stay on the live page"
    end

    test "and opening it points the editor at THAT draft", %{conn: conn, page: page} do
      {first, older, _newer} = two_drafts(conn, page)
      GenServer.stop(first.pid)

      view = open_with_draft(conn, page, older.id)
      view |> element("#pb-inherited-continue") |> render_click()

      assert editor(view).draft_id == older.id
      refute has_element?(view, "#pb-inherited-bar")
    end

    # THE OFFER IS OVER THE LIVE PAGE, always — the URL names a draft, it does not open one. Landing
    # inside it would be the surprise this whole feature exists to remove.
    test "but arriving does not open it", %{conn: conn, page: page} do
      {first, older, _newer} = two_drafts(conn, page)
      GenServer.stop(first.pid)

      view = open_with_draft(conn, page, older.id)

      assert editor(view).draft_id == nil
      assert node_with_tag(view, "h1"), "the live page is what is on screen"
    end

    # The resume bar's sentence — "never published, you are looking at the live page" — is about work
    # nobody asked for, and its Discard DELETES. Neither belongs over a draft just chosen by hand.
    test "takes the amber bar's place rather than sitting beside it", %{conn: conn, page: page} do
      {_autosave_id, view} = resumable_session(conn, page)
      actor = actor(view)
      chosen = "page" |> Drafts.list(page, actor) |> List.first()
      GenServer.stop(view.pid)

      again = open_with_draft(conn, page, chosen.id)

      assert has_element?(again, "#pb-inherited-bar")
      refute has_element?(again, "#pb-resume-bar")
    end

    # A SESSION SITTING IN ONE DRAFT, ARRIVING WITH ANOTHER NAMED. `save_as_draft` retargets the
    # session to what it just wrote, so the fixture points it back at the first draft — otherwise
    # the session and the URL name the same row and there is no contest to test.
    defp session_in_one_and_url_naming_another(conn, page) do
      {:ok, first, _html} = open_builder(conn, page)
      open = autosave!(first)

      render_click(first, "save_as_draft", %{"label" => "The one I picked"})
      _written = render_async(first)

      actor = actor(first)
      picked = "page" |> Drafts.list(page, actor) |> Enum.find(&(&1.label == "The one I picked"))
      assert picked && picked.id != open

      render_click(first, "open_draft", %{"id" => open})
      assert editor(first).draft_id == open, "the session has to be sitting in the OTHER draft"

      ref = Process.monitor(first.pid)
      GenServer.stop(first.pid)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000

      {open, picked}
    end

    # THE SESSION'S OWN DRAFT LOSES TO THE CLICK. A resumed session used to win outright, so the
    # carry-on bar named whatever the last sitting was in and the URL was read by nobody.
    test "beats the draft the last sitting was in", %{conn: conn, page: page} do
      {_open, picked} = session_in_one_and_url_naming_another(conn, page)

      again = open_with_draft(conn, page, picked.id)

      assert render(again) =~ "You picked “The one I picked”"
      again |> element("#pb-inherited-continue") |> render_click()
      assert editor(again).draft_id == picked.id
    end

    # AND THE DRAFT IT WAS SITTING IN IS STILL THERE TO GO BACK TO. Reopening detaches the session
    # from it — the canvas is the live page — so the only thing the URL's ask displaces is the offer,
    # never the row.
    test "without touching the draft the last sitting was in", %{conn: conn, page: page} do
      {open, picked} = session_in_one_and_url_naming_another(conn, page)

      again = open_with_draft(conn, page, picked.id)
      recorded = actor(again)

      assert editor(again).draft_id == nil, "reopening puts the live page on the canvas"
      assert Enum.any?(Drafts.list("page", page, recorded), &(&1.id == open))
    end

    # A URL naming the draft the session is already in has asked for nothing. The ordinary carry-on
    # bar is what says which draft that is, and it keeps its own words.
    test "a draft the editor is already in is left to the ordinary bar", %{conn: conn, page: page} do
      {:ok, first, _html} = open_builder(conn, page)
      open = autosave!(first)

      ref = Process.monitor(first.pid)
      GenServer.stop(first.pid)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000

      html = conn |> open_with_draft(page, open) |> render()

      assert html =~ "You were working in"
      refute html =~ "You picked"
    end

    # An id from a stale tab, another document, or another site's row. It is read against the list
    # this actor can see, so it resolves to nothing and the URL is simply ignored.
    test "an id that names nothing is ignored, not obeyed", %{conn: conn, page: page} do
      {_autosave_id, view} = resumable_session(conn, page)
      GenServer.stop(view.pid)

      again = open_with_draft(conn, page, Ecto.UUID.generate())

      refute has_element?(again, "#pb-inherited-bar")
      assert has_element?(again, "#pb-resume-bar"), "the ordinary offer is still made"
    end

    # DECLINING AN OFFER YOU NEVER ACCEPTED IS NOT A MOVE. Reparsing the template and reloading the
    # frames to arrive where the reader already is would be a loading overlay for no movement.
    test "staying on the live page just puts the bar away", %{conn: conn, page: page} do
      {first, older, _newer} = two_drafts(conn, page)
      GenServer.stop(first.pid)

      view = open_with_draft(conn, page, older.id)
      recorded = actor(view)
      view |> element("#pb-inherited-fresh") |> render_click()

      refute has_element?(view, "#pb-inherited-bar")
      refute render(view) =~ "Back on the live page"
      assert editor(view).draft_id == nil

      assert Enum.any?(Drafts.list("page", page, recorded), &(&1.id == older.id)),
             "declining an offer never deletes what was offered"
    end

    # The static render answers no draft question at all — see the resume bar's own note on why two
    # banners in a row for one situation is worse than a frame of neither.
    test "the static render still offers neither bar", %{conn: conn, page: page} do
      {first, older, _newer} = two_drafts(conn, page)
      GenServer.stop(first.pid)

      html =
        conn
        |> get("/admin/dashboard/runtime/builder/page/#{page.id}?draft_id=#{older.id}")
        |> html_response(200)

      refute html =~ "pb-inherited-bar"
      refute html =~ "pb-resume-bar"
    end
  end

  describe "saving" do
    test "save writes the serialized tree back to the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "headline"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="headline")
      assert reloaded.template =~ "Contact Us"
    end

    test "save clears the dirty flag", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      assert editor(view).dirty?

      publish!(view)
      refute editor(view).dirty?
    end

    test "the saved template still parses — a save can never corrupt a page", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert {:ok, _tree} = Tree.parse(reloaded.template)
    end
  end

  describe "chrome controls" do
    test "the device switcher changes the frame", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-device-mobile") |> render_click()
      assert has_element?(view, "#pb-frame-mobile")

      view |> element("#pb-device-frames") |> render_click()
      assert has_element?(view, "#pb-frame-1180")
      assert has_element?(view, "#pb-frame-560")
    end

    # The drawer is the sliver under the canvas, opened from its own strip or ⌘/. The TOP bar's Code
    # is a different surface now — see "the page source window" below.
    test "the code drawer opens and shows the serialized template", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_code", %{})

      html = render(view)
      assert html =~ "pb-codetab-html"

      assert html =~ "Contact Us"

      # The panes are inside `phx-no-curly-interpolation`, which is exactly where a `{…}` writes
      # itself out instead of rendering — so assert the placeholder never reaches the page.
      refute html =~ "{text}"
      refute html =~ "{number}"
    end

    # THE RIGHT PANE FOLLOWS THE SELECTION AND TAKES WHAT YOU TYPE. It used to render every styled
    # node on the page, ignoring the selection completely — so clicking an element changed the left
    # pane and left the right one showing a wall of other people's rules, with no way to type in it.
    test "the drawer's CSS pane shows the selected element's own CSS, and writes it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      assert has_element?(view, "[data-role=pb-drawer-css]"), "the box is there for a plain tag"

      view
      |> element("#pb-drawer-css-form")
      |> render_submit(%{"node_id" => heading.id, "css" => "letter-spacing: 3px;"})

      scope = Tree.scope(editor(view).tree, heading.id)
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules[scope] =~ "letter-spacing"
    end

    # THE LEFT PANE TAKES WHAT YOU TYPE TOO. It was a picture of the markup: the reader could see
    # the button's label and the `px-4` beside it and change neither.
    test "the drawer's HEEx pane holds the selected element's markup, and rewrites it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      assert view |> element("[data-role=pb-drawer-heex]") |> render() =~ "Contact Us"

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{
        "node_id" => heading.id,
        "source" => ~s(<h1 class="text-3xl">Talk To Us</h1>)
      })

      source = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()
      assert source =~ "Talk To Us"
      assert source =~ "text-3xl"
      refute source =~ "Contact Us"
    end

    # THE FIELD'S ID MUST MOVE WITH ITS WRAPPER. `phx-update="ignore"` means a changing wrapper id is
    # the only way new text reaches the editor — but morphdom matches by `id` first, so a CONSTANT id
    # on the textarea inside let the re-keyed wrapper adopt the old element and copy the server's
    # value over whatever had been typed. Invisibly: the textarea is hidden under CodeMirror, so the
    # screen kept showing the edit while the field that gets submitted had been reverted.
    test "the editor's field is keyed with its wrapper, not fixed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      first = view |> element("[data-role=pb-drawer-heex]") |> render()

      paragraph = node_with_tag(view, "p")
      render_click(view, "select", %{"id" => paragraph.id})
      second = view |> element("[data-role=pb-drawer-heex]") |> render()

      assert [_, one] = Regex.run(~r/id="([^"]+)"/, first)
      assert [_, two] = Regex.run(~r/id="([^"]+)"/, second)
      refute one == two, "a fixed id lets morphdom copy the server's text over what was typed"
    end

    # AN APPLY THAT CHANGED NOTHING MUST NOT LOOK LIKE ONE THAT WORKED. Re-submitting the markup a
    # node already carries used to record a history entry, mark the document dirty and broadcast —
    # so undo had a step in it that undid nothing.
    test "re-applying the same markup is not an edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      before = length(editor(view).past)
      same = Serializer.serialize_node(editor(view).tree, heading.id)

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => same})

      assert length(editor(view).past) == before
    end

    # WORDS INSIDE A COMPONENT THAT TAKES NO CHILDREN. `<.link navigate="/">Home</.link>` holds a
    # text node whose parent declares no slot, so replacing it as an element is rightly refused —
    # and retyping one word is not replacing an element.
    test "a text node's words can be rewritten inside a slotless component", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      link = ~s(<nav><.link navigate="/">Home</.link></nav>)
      render_click(view, "apply_source", %{"source" => link})

      text = node_with_kind(view, :text)
      render_click(view, "toggle_code", %{})
      render_click(view, "select", %{"id" => text.id})

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => text.id, "source" => "Start"})

      refute has_element?(view, "#pb-drawer-heex-error")
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Start"
    end

    # ONE UNDO STEP, not a delete and an insert the reader has to undo twice.
    test "rewriting an element is a single change", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      before = length(editor(view).past)

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => "<h1>Talk To Us</h1>"})

      assert length(editor(view).past) == before + 1

      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Contact Us"
    end

    # WHAT WAS TYPED SURVIVES A REFUSAL. Losing a page of hand-written markup is not a way to report
    # a missing brace — and the pane is `phx-update="ignore"`, so the text stays in the box while the
    # error is drawn under it.
    test "markup that will not parse is refused, and the document is untouched", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => "<h1>{@user.name</h1>"})

      assert view |> element("#pb-drawer-heex-error") |> render() =~ "expected closing"
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Contact Us"
    end

    # THE TOKENIZER IS NOT THE COMPILER. This tokenizes perfectly — it is a component tag like any
    # other — and 500s the first visitor, so the check that catches it is a real compile.
    @tag :slow
    test "markup that will not COMPILE is refused, and the document is untouched", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      view
      |> element("#pb-drawer-heex-form")
      |> render_submit(%{"node_id" => heading.id, "source" => "<h1><.no_such_thing /></h1>"})

      error = view |> element("#pb-drawer-heex-error") |> render()
      assert error =~ "undefined function no_such_thing/1"

      # The rehearsal module is called `C80201` and nothing else calls the page that.
      refute error =~ "CodeCheck.C"

      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "Contact Us"
    end

    # ONE VALUE, TWO SURFACES. The Inspector sets a property, the drawer gives room to write a
    # block — but a second copy of the same CSS is a second thing to keep in step, so there is
    # only one.
    test "the drawer's CSS pane holds the same value the Inspector's box does", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 7px;"})

      assert view |> element("[data-role=pb-drawer-css]") |> render() =~ "gap: 7px"
      assert view |> element("#pb-css-text") |> render() =~ "gap: 7px"

      # And writing from the drawer reaches the Inspector's box, because there is one value and not
      # a copy of it in each surface.
      view
      |> element("#pb-drawer-css-form")
      |> render_submit(%{"node_id" => heading.id, "css" => "gap: 9px;"})

      assert view |> element("#pb-css-text") |> render() =~ "gap: 9px"
      refute view |> element("#pb-css-text") |> render() =~ "gap: 7px"
    end

    test "the drawer's CSS pane follows the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      paragraph = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 7px;"})
      assert render(view) =~ "gap: 7px"

      render_click(view, "select", %{"id" => paragraph.id})
      refute render(view) =~ "gap: 7px", "the other element's rule is not shown here"
    end

    test "the drawer's CSS pane says so when nothing is selected", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      refute has_element?(view, "[data-role=pb-drawer-css]")
      assert render(view) =~ "Select an element to write CSS for it."
    end

    # The same question the Inspector asks, asked through the same function, so the two surfaces
    # can never disagree about which elements can hold a rule.
    test "the drawer's CSS pane refuses a component that takes no class", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})
      render_click(view, "select", %{"id" => node_with_kind(view, :component).id})

      refute has_element?(view, "[data-role=pb-drawer-css]")
      assert has_element?(view, "#pb-drawer-css-note")
    end

    test "the drawer's CSS pane refuses CSS that would escape the element", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_code", %{})

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      view
      |> element("#pb-drawer-css-form")
      |> render_submit(%{"node_id" => heading.id, "css" => "gap: 1px; } body { display: none; "})

      assert has_element?(view, "#pb-drawer-css-error")
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules == %{}
    end

    # The upper Code menu. What it shows has to be what a save WRITES, which is `to_heex/1`
    # (serialised, re-parsed, formatted) and not the drawer's raw `serialize/1`.
    # ATTACHING A HOOK, NOT WRITING ONE. Writing stays on Runtime → JS hooks — the right amount of
    # friction for shipping executable JavaScript — and this saves someone hand-typing `phx-hook`
    # into Advanced and getting the compiled name's capitalisation wrong.
    test "an element can be attached to a runtime hook", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      render_click(view, "select", %{"id" => p.id})

      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks
      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})

      node = Tree.get(editor(view).tree, p.id)
      assert Node.attr(node, "phx-hook") == {:string, hook.name}
      assert has_element?(view, "#flash-info", "Hook attached.")

      # LiveView silently never mounts a hook on an element with no id.
      assert {:string, "el-" <> _rest} = Node.attr(node, "id")
    end

    test "an id the author already set is left alone", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p id="mine">One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})

      assert Node.attr(Tree.get(editor(view).tree, p.id), "id") == {:string, "mine"}
    end

    test "choosing None detaches it, and takes back only the id it minted", %{
      conn: conn,
      site: site
    } do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})
      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => ""})

      node = Tree.get(editor(view).tree, p.id)
      refute Node.attr(node, "phx-hook")
      refute Node.attr(node, "id"), "the minted id went with the hook"
      assert has_element?(view, "#flash-info", "Hook removed.")
    end

    # An id the author wrote may be the target of a link or a stylesheet, so it stays.
    test "detaching leaves an id the author wrote", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p id="mine">One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})
      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => ""})

      assert Node.attr(Tree.get(editor(view).tree, p.id), "id") == {:string, "mine"}
    end

    # A name the site does not have must not be written as though it did — a hook archived in
    # another tab, or a value posted by hand. AND IT IS SAID OUT LOUD: the refusal used to report
    # "Hook attached.", which is the sentence an author reads before going to look for the hook.
    test "a hook this site does not have is refused", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => "NotARealHook"})

      refute Node.attr(Tree.get(editor(view).tree, p.id), "phx-hook")
      assert has_element?(view, "#flash-error", "no longer available")
      refute has_element?(view, "#flash-info")
    end

    # REFUSED MEANS NOTHING CHANGES, and this is the case that cost work. An unknown name fell to
    # the same branch as None, so Apply took the attached hook off along with the minted id — which
    # a link or a stylesheet may point at — and reported success. The element had a hook a moment
    # ago and the author has no reason to check.
    test "and the hook already on the element survives it, id and all", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "collapse")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => hook.name})
      minted = Node.attr(Tree.get(editor(view).tree, p.id), "id")
      assert {:string, "el-" <> _rest} = minted

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => "NotARealHook"})

      node = Tree.get(editor(view).tree, p.id)
      assert Node.attr(node, "phx-hook") == {:string, hook.name}
      assert Node.attr(node, "id") == minted
      assert has_element?(view, "#flash-error", "no longer available")
    end

    # AND A HOOK AN EXTENSION CONTRIBUTES APPLIES LIKE ANY OTHER. The picker read the appended list
    # and the write read the site's own rows, so a contributed hook was drawn in the select and then
    # refused by Apply — for every contribution, every time, with nothing archived anywhere.
    test "a hook an extension contributes is offered and applies", %{conn: conn, site: site} do
      {:ok, _} =
        Event.write(%{
          name: BuilderJsHookPlugin,
          event: "builder:js_hooks",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:js_hooks", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderJsHookPlugin, false) end)

      contributed = BuilderJsHookPlugin.hook()
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")
      offered = :sys.get_state(view.pid).socket.assigns.js_hooks

      assert contributed.name in Enum.map(offered, & &1.name)

      render_click(view, "save_hook", %{"node_id" => p.id, "hook" => contributed.name})

      assert Node.attr(Tree.get(editor(view).tree, p.id), "phx-hook") ==
               {:string, contributed.name}
    end

    # `is_global` IS A CALCULATION. Unloaded it is `%Ash.NotLoaded{}`, which is truthy, so
    # `browser_name/2` named every hook `Global…` — a site's own would have been written into
    # `phx-hook` under a name nothing registers and would silently never mount.
    test "a site's own hook is named for the site, not as a global", %{conn: conn, site: site} do
      create_js_hook!(site_id: site.id, name: "mine")
      page = create_page!(site_id: site.id, template: ~s(<div><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      hooks = :sys.get_state(view.pid).socket.assigns.js_hooks
      own = Enum.find(hooks, &(&1.hook == "mine"))

      refute own.global?
      refute String.starts_with?(own.name, "Global"), "got #{own.name}"
      assert String.ends_with?(own.name, "Mine")
    end

    test "a site with no hooks says so instead of showing an empty picker", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      assert render(view) =~ "pb-hook-empty"
    end

    # WHAT AN ELEMENT DOES WHEN CLICKED, without anyone writing JavaScript. Under LiveView a script
    # that changes a class is undone by the next patch that touches the element; a declared JS
    # command is part of what the server rendered and survives.
    test "an element can be given a click action", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      tree = editor(view).tree
      scope = Tree.scope(tree, section.id)
      html = Serializer.serialize(tree)

      assert html =~ ~s|phx-click={JS.toggle_class("is-open", to: ".#{scope}")}|
    end

    test "the action reads back into the panel", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "hide",
        "class" => ""
      })

      node = Tree.get(editor(view).tree, section.id)

      assert {:ok, "hide", %{}} =
               MishkaCmsCore.Runtime.PageBuilder.Interactions.read(Node.attr(node, "phx-click"))
    end

    # AIMING SURVIVES EDITING THE THING IT AIMS AT. The scope class is the entire link between a
    # button and the dialog it opens, and the inspector shows it in the target's own class box —
    # where it reads as junk and invites being typed over. Doing that used to take the aim with it:
    # the button kept a command pointing at a class nothing carried, the target `<select>` fell
    # silently back to "This element", and the next Apply overwrote the aim for good.
    test "editing the target's class does not un-aim the button", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      dialog = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => dialog.id,
        "action" => "show",
        "class" => ""
      })

      aim = Tree.scope(editor(view).tree, dialog.id)
      assert is_binary(aim)

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => dialog.id,
        "name" => "class",
        "value" => "shadow-2xl"
      })

      tree = editor(view).tree

      assert Tree.scope(tree, dialog.id) == aim, "the target lost the class the button names"

      assert Interactions.target(Node.attr(Tree.get(tree, button.id), "phx-click")) == aim

      assert Serializer.serialize(tree) =~ "shadow-2xl",
             "the author's own class was not written"
    end

    # A FIELD THAT IS NOT ON THE PAGE POSTS NOTHING, and nothing is not the same answer as "".
    # The target `<select>` renders only when the document has something to aim at, so while the
    # palette was still loading — or after it failed — pressing Apply to change the ACTION posted no
    # target at all, and "no target" meant "aim at yourself". A working "open the dialog" quietly
    # became "show this button", under a flash reading "Click action set."
    test "changing the action alone keeps the target it already had", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      dialog = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => dialog.id,
        "action" => "show",
        "class" => ""
      })

      aim = Tree.scope(editor(view).tree, dialog.id)

      # Exactly what the browser posts when the select is not rendered: no `target` key at all.
      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "action" => "hide",
        "class" => ""
      })

      written = Node.attr(Tree.get(editor(view).tree, button.id), "phx-click")

      assert Interactions.read(written) == {:ok, "hide", %{}}

      assert Interactions.target(written) == aim,
             "the aim was silently moved to the button itself"
    end

    # AND AN EMPTY ONE IS STILL AN ANSWER — the author choosing "This element" from a select that is
    # on the page. The two must not be read as the same thing.
    test "choosing This element does re-aim it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      dialog = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => dialog.id,
        "action" => "show",
        "class" => ""
      })

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "target" => "",
        "action" => "show",
        "class" => ""
      })

      tree = editor(view).tree
      written = Node.attr(Tree.get(tree, button.id), "phx-click")

      assert Interactions.target(written) == Tree.scope(tree, button.id)
    end

    test "choosing nothing takes the action and the scope back off", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle",
        "class" => ""
      })

      assert Tree.scope(editor(view).tree, section.id)

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "",
        "class" => ""
      })

      refute Serializer.serialize(editor(view).tree) =~ "phx-click"
    end

    # SAYING SOMETHING IS THE ONE VERB THE CLIENT CANNOT DO ALONE. The other six move classes and
    # visibility around with `Phoenix.LiveView.JS`; a message is Phoenix's own flash, so this one
    # pushes and the page answers with `put_flash/3`.
    test "a click can say something", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "action" => "say",
        "kind" => "info",
        "message" => "Thanks — we'll be in touch."
      })

      written = Node.attr(Tree.get(editor(view).tree, button.id), "phx-click")

      assert Interactions.read(written) ==
               {:ok, "say", %{"kind" => "info", "message" => "Thanks — we'll be in touch."}}

      assert Serializer.serialize(editor(view).tree) =~ ~s|JS.push("pb:say"|
    end

    test "with nothing to say it changes nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => button.id})

      render_click(view, "save_interaction", %{
        "node_id" => button.id,
        "action" => "say",
        "kind" => "info",
        "message" => "   "
      })

      refute Serializer.serialize(editor(view).tree) =~ "phx-click"
    end

    # A BOX IS IDENTIFIED BY ITS NAME, NOT BY THE VERB IT WAS FILLED IN UNDER. All three class verbs
    # ask for a field called `class`, so changing your mind between them must not empty it — it did,
    # and pressing Apply then refused the whole thing for want of a class nobody had removed.
    test "changing your mind between two class verbs keeps the class", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_click(view, "save_interaction", %{
        "node_id" => heading.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_change(view, "pick_interaction", %{"action" => "add_class"})

      assert inspector_html(view) =~ ~s(id="pb-act-class"),
             "the class box is not the box the chosen verb asks for"

      assert inspector_html(view) =~ ~s(value="is-open"),
             "the author's own class was cleared by changing the verb"
    end

    # And a box the new verb does not have starts empty rather than inheriting a stranger's word.
    test "but a different box starts empty", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_click(view, "save_interaction", %{
        "node_id" => heading.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_change(view, "pick_interaction", %{"action" => "say"})
      html = inspector_html(view)

      assert html =~ ~s(id="pb-act-message")
      refute html =~ ~s(id="pb-act-class"), "the class box is drawn for a verb that wants words"
      refute html =~ ~s(value="is-open"), "a class ended up in the message box"
    end

    # THE VERB DECIDES WHICH BOX SITS UNDER IT, and the box for the verb somebody just left is a box
    # that describes the previous element. Both halves reset when the selection moves.
    test "the verb mid-pick belongs to the element it was picked on", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      button = node_with_tag(view, "h1")
      other = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => button.id})
      render_change(view, "pick_interaction", %{"action" => "say"})
      assert :sys.get_state(view.pid).socket.assigns.act_action == "say"

      render_click(view, "select", %{"id" => other.id})
      assert :sys.get_state(view.pid).socket.assigns.act_action == nil
      assert :sys.get_state(view.pid).socket.assigns.aim_target == nil
    end

    # WHEN AN ELEMENT IS ON THE PAGE AT ALL. HEEx already has the feature, so the panel writes the
    # `:if` a developer would have written — and the author who later learns Elixir finds their own
    # condition in Advanced rather than a setting kept somewhere else.
    test "an element can be shown only to signed-in visitors", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => "signed_in"})

      node = Tree.get(editor(view).tree, heading.id)

      assert Conditions.read(Node.attr(node, Conditions.attribute())) == {:ok, "signed_in"}
      assert Serializer.serialize(editor(view).tree) =~ ":if="
    end

    test "and Always takes it back off", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => "said_ok"})
      assert Serializer.serialize(editor(view).tree) =~ ":if="

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => ""})
      refute Serializer.serialize(editor(view).tree) =~ ":if="
    end

    # A CONDITION IS NOT A WAY TO LOSE AN ELEMENT. The canvas renders the document, not the document
    # running, so an element that is conditionally absent on the published page is still drawn here —
    # otherwise setting the condition would be the last time its author could reach it.
    test "the canvas still draws a conditional element", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")

      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => "signed_in"})

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us", "the element the condition is on went missing from the canvas"
    end

    # CSS FOR ONE ELEMENT — the thing the panel above it cannot offer, because a panel can only
    # offer what somebody thought to add to it. Every builder in the field answers this with a
    # per-element CSS box; this one keys the rule on a class minted into the markup, so it survives
    # a save and travels with the node.
    test "an element can be given its own CSS", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "padding: 20px;\n\n&:hover { opacity: .8; }"
      })

      tree = editor(view).tree
      scope = Tree.scope(tree, section.id)

      assert scope =~ ~r/^pb-[a-f0-9]{8}$/, "the element was named"
      assert Serializer.serialize(tree) =~ scope, "and the name is in the markup"

      css = :sys.get_state(view.pid).socket.assigns.element_css_rules[scope]
      assert css =~ "padding: 20px;"
      assert css =~ "&:hover"
    end

    # A COMPONENT IS ONE NODE AND MANY ELEMENTS, and the rule is keyed on a class written into the
    # node — which reaches the DOM only if the component declares `class`. Offering the box anyway
    # took CSS that could never match anything, which is how this was found in the browser.
    test "a component that takes no class says so instead of taking CSS", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      html = render(view)
      assert html =~ "pb-css-unreachable"
      refute has_element?(view, "#pb-css-text")
    end

    # A DEAD END WITH A DOOR IN IT. Telling the reader to "put it inside a container" and leaving
    # them to work out how is the same as telling them no — the wrapper is an op the editor already
    # has, so it is offered rather than described.
    test "a component that takes no class is offered the wrapper that would work", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      assert has_element?(view, "#pb-css-wrap")
      render_click(view, "op", %{"kind" => "wrap", "node_id" => component.id, "tag" => "div"})

      wrapped = Tree.get(editor(view).tree, component.id)
      parent = Tree.get(editor(view).tree, wrapped.parent_id)

      assert parent.tag == "div"
      assert parent.id != component.id, "a new wrapper, not the one it was already in"

      render_click(view, "select", %{"id" => parent.id})
      assert has_element?(view, "#pb-css-text"), "and the wrapper can take CSS"
    end

    # `& > .badge` on a component aims a rule at markup the kit owns and the page does not. Not
    # refused — sometimes it is the only way — but said out loud, and named with the kit and version
    # so the reader knows what they are betting on.
    test "a rule reaching into a component's own markup says whose markup it is", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "badged",
        template: ~s(<div class={@class}><span class="badge">1</span></div>),
        attrs: [%{"name" => "class", "type" => "string", "opts" => %{}}],
        extra: %{"ui_kit" => "chelekom", "ui_kit_version" => "0.0.9"}
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="badged" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => component.id,
        "css" => "padding: 2px;\n&:hover { opacity: .9; }"
      })

      refute has_element?(view, "#pb-css-reaching"), "its own element and its own hover are fine"

      render_click(view, "save_element_css", %{
        "node_id" => component.id,
        "css" => "& > .badge { color: red; }"
      })

      # NOT the html `render_click` returned. Applying CSS announces the tree through the session, and
      # that message reaches this LiveView after the click handler has already replied — so the
      # snapshot the click hands back predates the panel that reads it.
      html = render(view)

      assert has_element?(view, "#pb-css-reaching")
      assert html =~ "chelekom 0.0.9", "named, so the reader knows what they are betting on"
      assert html =~ "&gt; .badge", "and which selector it was"
    end

    test "a plain tag's own markup belongs to the author, so nothing is said", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "& > .badge { color: red; }"
      })

      refute has_element?(view, "#pb-css-reaching")
    end

    test "the canvas is given the rule so it paints without a recompile", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 13px;"})

      html = render(canvas)
      assert html =~ "pb-canvas-element-css"
      assert html =~ "gap: 13px;"
    end

    test "clearing the box takes the name back off", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      assert Tree.scope(editor(view).tree, section.id)

      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => ""})

      refute Tree.scope(editor(view).tree, section.id),
             "nothing is left carrying a name for a rule that no longer exists"
    end

    # The one structural rule: the text is wrapped in `.pb-xxxxxxxx { … }`, and a `}` typed at the
    # top level closes that wrapper early and puts everything after it on the whole site.
    test "CSS that would escape the element is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      html =
        render_click(view, "save_element_css", %{
          "node_id" => section.id,
          "css" => "gap: 1px; } body { display: none; "
        })

      assert html =~ "unmatched"
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules == %{}
    end

    # A RULE IS KEYED ON A CLASS IN THE MARKUP, so deleting the element takes the only reference to
    # it away — and the rule stayed in the row, compiled into the site's stylesheet and served to
    # every visitor, for as long as the page existed. `live_rules/2` was written and tested for this
    # and had no caller at all.
    test "saving drops the CSS of an element that is no longer there", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, heading.id)

      # The stage says Draft, so the rule is held until a publish writes the markup carrying its
      # class. That publish is the one that puts it in the row for the delete below to take out.
      render_click(view, "publish", %{})

      assert stored_element_css(view, page)[scope] =~ "gap: 9px",
             "it was written in the first place"

      render_click(view, "op", %{"kind" => "delete", "node_id" => heading.id})
      render_click(view, "publish", %{})

      refute Map.has_key?(stored_element_css(view, page), scope), "the rule went with the element"
    end

    # THROUGH THE SAVE ITSELF. Paste styles used to carry the source's minted class onto the target,
    # which made the target answer with the source's name — and the prune then rewrote the row to
    # hold only the names the tree still answers with, so the author's CSS on the target went with
    # the paste. The unit tests for this ask `live_rules/2`; this one asks the row.
    test "styles pasted from one element leave the other's CSS alone", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      p = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "save_element_css", %{"node_id" => h1.id, "css" => "gap: 9px;"})
      render_click(view, "select", %{"id" => p.id})
      render_click(view, "save_element_css", %{"node_id" => p.id, "css" => "gap: 11px;"})

      source = Tree.scope(editor(view).tree, h1.id)
      target = Tree.scope(editor(view).tree, p.id)

      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})
      render_click(view, "ctx", %{"action" => "paste_styles", "node_id" => p.id})

      assert Tree.scope(editor(view).tree, p.id) == target,
             "the target still answers to its own name"

      render_click(view, "publish", %{})

      stored = stored_element_css(view, page)
      assert stored[target] =~ "gap: 11px", "the target kept the CSS the author wrote on it"
      assert stored[source] =~ "gap: 9px", "and the source's is untouched"
    end

    # Pruning against the tree in the editor rather than the tree that was saved would drop the CSS
    # of an element the author is one ⌘Z away from bringing back.
    test "an element still in the saved page keeps its CSS", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "publish", %{})

      assert stored_element_css(view, page)[scope] =~ "gap: 9px"
    end

    # WRITTEN BY ONE SESSION, READ BY THE NEXT — and both name the row through `css_owner/1`, which
    # is `ElementScopes.owner/2`. A second spelling anywhere in the round trip is an author shown an
    # empty CSS box in front of rules the page is visibly wearing, and a next save that prunes them
    # as belonging to no element at all.
    test "and is shown them again the next time the document is opened", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "publish", %{})

      {:ok, reopened, _html} = open_builder(conn, page)
      rules = :sys.get_state(reopened.pid).socket.assigns.element_css_rules

      assert Map.has_key?(rules, scope),
             "the open read a different row than the save wrote"

      assert rules[scope] =~ "gap: 9px"
    end

    # A CONTROL THAT HAS BEEN OVERRULED SAYS SO. Custom CSS is emitted last and unlayered, so where
    # the two name one property the CSS wins and dragging the control moves nothing — which, unmarked,
    # reads as a control that is broken rather than one that has been overridden.
    test "a control whose property the element's own CSS also sets is marked", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      refute has_element?(view, "#pb-css-wins-padding")

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "padding: 20px;"
      })

      assert has_element?(view, "#pb-css-wins-padding"), "the control it beats outright"
      assert has_element?(view, "#pb-css-wins-pt"), "and the longhands the shorthand swallows"
      refute has_element?(view, "#pb-css-wins-gap"), "but nothing it does not set"
    end

    # A hover rule does NOT beat `hover:p-4` — that carries a pseudo-class and therefore more
    # specificity — so the mark belongs to the bucket wearing the same selector and to no other.
    test "the mark follows the bucket the declaration was written for", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "&:hover { opacity: .5; }"
      })

      refute has_element?(view, "#pb-css-wins-opacity"), "not while Normal is the open state"

      render_click(view, "set_pseudo", %{"value" => "hover"})
      assert has_element?(view, "#pb-css-wins-opacity")
    end

    test "a declaration a control could hold is offered, and one it could not is not", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "border-image: url(x);\ngap: 4px !important;\nalign-items: center;"
      })

      assert has_element?(view, "#pb-css-movable")
      assert has_element?(view, "#pb-css-move-2"), "align-items has a control"
      refute has_element?(view, "#pb-css-move-0"), "border-image has none"
      refute has_element?(view, "#pb-css-move-1"), "and !important could not survive the move"
    end

    # THE ROW HAS TO NAME ITS LINE, or "Move to controls" is a button that moves something unnamed.
    # `phx-no-curly-interpolation` on the `<code>` printed the interpolation itself, and the author
    # read the template's own source where their declaration should have been.
    test "the movable row shows the declaration, not the interpolation", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "background-color: #dadada;"
      })

      row = view |> element("#pb-css-movable") |> render()

      assert row =~ "background-color: #dadada"
      refute row =~ "declaration.text"

      assert has_element?(view, "#pb-css-wins-background"),
             "and the control it overrules says so — once, or LiveViewTest raises on the id"
    end

    # `main { … }` parses, saves and matches nothing, so the box has no reason to refuse it and the
    # page simply does not change. The advice is the only thing that names the mistake, and it was
    # reaching the code drawer alone — `inspector/1` received it and passed it no further.
    test "advice about a selector that misses is shown in the box it was typed in", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "color: red;"
      })

      refute has_element?(view, "#pb-css-advice"), "a declaration on its own aims at the element"

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "main { color: red }"
      })

      advice = view |> element("#pb-css-advice") |> render()

      assert advice =~ "INSIDE this element"
      assert advice =~ "start the selector with"
    end

    # A BODY THAT WILL NOT PARSE HAS NO AIM TO COMMENT ON. The error and the advice share the slot
    # under the box, so the one the author has to fix first is the one that gets it.
    test "a refused body shows the error there instead of advice", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "main { color: red"
      })

      assert has_element?(view, "#pb-css-error")
      refute has_element?(view, "#pb-css-advice")
    end

    # ONE LINE, MOVED: written as the override the control holds, and taken out of the text. The two
    # never competed for storage, so nothing has to be merged — and what is left is a page that looks
    # exactly the same with one fewer place to change it.
    test "moving a declaration sets the control and takes the line out", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "align-items: center;\nborder-image: url(x);"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert Tree.get(editor(view).tree, section.id).meta.styles[:base]["align"] == "items-center"

      scope = Tree.scope(editor(view).tree, section.id)
      css = :sys.get_state(view.pid).socket.assigns.element_css_rules[scope]

      refute css =~ "align-items"
      assert css =~ "border-image", "the line it could not take is left where it was"
      refute has_element?(view, "#pb-css-wins-align"), "and the mark goes with it"

      # …and the control it landed in is on screen, on a `<section>` that is not a flex row. It was
      # not: the four flex rows were drawn only for a row, so this override had nowhere to be read
      # or undone.
      assert has_element?(view, "#pb-style-pics-base-align")

      view |> element("#pb-style-pic-base-align-items-center") |> render_click()
      assert styles_of(view, section.id) == %{}
    end

    # THE LINE THAT STARTED THIS. `#dadada` is none of the five swatches, so the swatch row showed
    # nothing selected, no field held the value, and the only way to take it off again was to clear
    # the whole bucket — a control that cannot represent what was moved into it.
    test "a moved background can be seen, changed and cleared", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "background-color: #dadada;"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert styles_of(view, section.id) == %{base: %{"background" => "#dadada"}}
      assert view |> element("#pb-style-base-background") |> render() =~ "#dadada"

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#101010"})
      assert styles_of(view, section.id) == %{base: %{"background" => "#101010"}}

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => ""})
      assert styles_of(view, section.id) == %{}
    end

    # A DECLARATION NAMES ITS OWN BUCKET, and the panel was left wherever it happened to be. The
    # State section is folded by default and carries no count, so a `&:hover` line moved into the
    # hover bucket left the author looking at a panel that had not changed.
    test "moving a hover line puts the panel on the state that holds it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "&:hover { opacity: .5; }"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert styles_of(view, section.id) == %{hover: %{"opacity" => ".5"}}
      assert has_element?(view, "#pb-state-recorded")
      assert view |> element("#pb-style-hover-opacity") |> render() =~ ~s(value=".5")
    end

    # THE AUDIT, RUN. Every line the panel offers to move has to land in a control the author can
    # then see — background landed in a swatch row with no swatch for it, and the four flex rows
    # landed on an element that drew none of them.
    test "every declaration a control can hold lands where the panel shows it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      for prop <- Styles.properties() do
        {css_prop, css_value} = Styles.declaration(prop, sample_style(prop))

        # Every property meets the same plain `<section>`: one that has moved a `display: flex` a
        # moment ago is a different element, and the four flex rows would draw for that reason
        # rather than for the value they now hold.
        render_click(view, "op", %{
          "kind" => "reset_styles",
          "node_id" => section.id,
          "bucket" => "base"
        })

        render_click(view, "save_element_css", %{
          "node_id" => section.id,
          "css" => "#{css_prop}: #{css_value};"
        })

        assert has_element?(view, "#pb-css-move-0"),
               "#{css_prop} is not offered, though #{prop} is a control"

        render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

        # `render/1` and not the click's own return: the op is announced to the LiveView rather than
        # assigned inside the handler, so the reply is drawn from the tree as it was BEFORE the move
        # and every picture row would read as missing.
        html = render(view)

        assert control_for?(html, prop),
               "#{css_prop} moved into #{prop}, and nothing on screen holds it"
      end
    end

    test "a stale index moves nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      html =
        render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "7"})

      assert html =~ "no longer there"
      scope = Tree.scope(editor(view).tree, section.id)
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules[scope] =~ "gap: 4px"
    end

    # Moving the last line empties the box, and an empty box takes the scope class back off — but
    # that class is also what an interaction on the same element points at.
    test "the name survives when a click action still points at it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert Tree.scope(editor(view).tree, section.id) == scope
      assert Serializer.serialize(editor(view).tree) =~ scope
    end

    test "and clearing the click action leaves the name when CSS still uses it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})
      scope = Tree.scope(editor(view).tree, section.id)

      render_click(view, "save_interaction", %{
        "node_id" => section.id,
        "action" => "",
        "class" => ""
      })

      assert Tree.scope(editor(view).tree, section.id) == scope,
             "the rule keyed on this name is still there"
    end

    # THE PAGE'S OWN ELIXIR, in the window that already holds its markup. `events`, `infos` and
    # `helpers` have been Page attributes since the resource was written and the compiler has always
    # turned them into `handle_event/3`, `handle_info/2` and plain `def`s — the only way to reach
    # them was the Pages form, which is not where anyone is when they need a handler for the button
    # they just placed.
    test "the code window has a tab for each thing a page can hold", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      html = view |> element("#pb-code") |> render_click()

      for {id, label} <- [
            {"pb-sourcetab-template", "Template"},
            {"pb-sourcetab-events", "Handlers"},
            {"pb-sourcetab-infos", "Messages"},
            {"pb-sourcetab-helpers", "Helpers"},
            {"pb-sourcetab-styles", "Styles"}
          ] do
        assert has_element?(view, "##{id}")
        assert html =~ label
      end
    end

    # AN INDEX, NOT A FIFTH CODE BOX. An author who styled six elements had six panels to reopen to
    # find out what they had written; this lists them, and the only thing you can do to one is go to
    # the element that owns it — which is the one place it can be edited.
    test "the Styles tab lists this page's element rules", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})

      scope = Tree.scope(editor(view).tree, heading.id)
      view |> element("#pb-code") |> render_click()

      assert render_click(view, "source_tab", %{"tab" => "styles"}) =~ "gap: 11px"
      assert has_element?(view, "#pb-style-rule-#{scope}")
      assert has_element?(view, "#pb-style-rule-go-#{scope}")
    end

    test "the empty state says where to write one", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      assert render_click(view, "source_tab", %{"tab" => "styles"}) =~ "No element on this page"
    end

    # A rule whose element has been deleted is still being served. Hiding it would make the prune on
    # the next save look like the editor losing something.
    test "a rule whose element is gone is shown, and says what will happen to it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})

      scope = Tree.scope(editor(view).tree, heading.id)
      render_click(view, "op", %{"kind" => "delete", "node_id" => heading.id})

      view |> element("#pb-code") |> render_click()
      html = render_click(view, "source_tab", %{"tab" => "styles"})

      assert html =~ "saving drops this rule"
      assert has_element?(view, "#pb-style-rule-#{scope}")
      refute has_element?(view, "#pb-style-rule-go-#{scope}"), "there is nothing to select"
    end

    test "selecting from the index closes the window on the element's inspector", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 11px;"})
      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})

      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "styles"})
      render_click(view, "select_from_code", %{"id" => heading.id})

      refute has_element?(view, "#pb-source-modal")
      assert editor(view).selection == heading.id
      assert :sys.get_state(view.pid).socket.assigns.left_tab == :inspector
    end

    test "a handler can be added, written and kept", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "source_tab", %{"tab" => "events"})
      assert render(view) =~ "No handlers yet"

      render_click(view, "add_code", %{"tab" => "events"})
      assert has_element?(view, "#pb-code-entry-events-0")

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "events",
          "entry" => %{"0" => %{"name" => "save", "code" => "{:noreply, socket}"}}
        })

      assert html =~ "Saved to the page"
      assert [%{"name" => "save"}] = fragments(view).events
    end

    # The wrapper is shown and not editable, because the compiler splices what is typed between
    # those two lines — an author who writes the whole clause gets a definition inside a definition.
    test "the generated wrapper is shown around the box", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      render_click(view, "add_code", %{"tab" => "events"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "events",
        "entry" => %{"0" => %{"name" => "save", "code" => "{:noreply, socket}"}}
      })

      html = render(view)
      assert html =~ "def handle_event(&quot;save&quot;, params, socket) do"
    end

    test "code that will not compile is refused where it was typed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "events"})
      render_click(view, "add_code", %{"tab" => "events"})

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "events",
          "entry" => %{"0" => %{"name" => "save", "code" => "{:noreply, socket"}}
        })

      assert html =~ "missing terminator"
      assert [%{"code" => "{:noreply, socket"}] = fragments(view).events, "the text is not lost"

      reloaded =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert reloaded.events == [], "nothing that will not compile reached the page"
    end

    test "a helper takes a name, an argument list and a body", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "helpers",
          "entry" => %{"0" => %{"name" => "add", "args" => "a, b", "code" => "a + b"}}
        })

      assert html =~ "Saved to the page"
      assert [%{"args" => "a, b"}] = fragments(view).helpers
    end

    test "an entry can be removed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "infos"})
      render_click(view, "add_code", %{"tab" => "infos"})

      assert has_element?(view, "#pb-code-entry-infos-0")
      render_click(view, "remove_code", %{"tab" => "infos", "index" => "0"})
      refute has_element?(view, "#pb-code-entry-infos-0")
    end

    # WRITTEN ON ITS OWN. Code is page configuration rather than document content: the draft stage
    # writes a Draft holding only the tree, so anything merely held in an assign would be lost when
    # the tab closed — and restoring an old draft would revert today's handlers.
    test "saving code writes it to the page immediately", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "helpers",
        "entry" => %{"0" => %{"name" => "shout", "args" => "t", "code" => "String.upcase(t)"}}
      })

      reloaded =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert [%{name: "shout", args: "t"}] = reloaded.helpers
    end

    test "the page source window shows what would be stored, and can be edited", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-source-modal")

      html = view |> element("#pb-code") |> render_click()
      assert html =~ "pb-source-modal"
      assert html =~ "Page code"

      {:ok, expected} =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.to_heex()

      assert render(view) =~ Phoenix.HTML.html_escape(expected) |> Phoenix.HTML.safe_to_string()

      # Editing it replaces the whole document, through the same call a draft restore makes.
      view
      |> element("#pb-source-form")
      |> render_submit(%{
        "source" => ~s(<section class="from-source"><h2>Rewritten</h2></section>)
      })

      refute has_element?(view, "#pb-source-modal")

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize() =~ "from-source"

      # …and it is one undo away, like any other edit.
      render_click(view, "undo", %{})

      refute view
             |> editor()
             |> Map.fetch!(:tree)
             |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize() =~ "from-source"
    end

    test "unparseable source is refused without losing what was typed", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      before = editor(view).tree

      view
      |> element("#pb-source-form")
      |> render_submit(%{"source" => "<div><span></div>"})

      assert has_element?(view, "#pb-source-modal"), "the window stays open"
      assert has_element?(view, "#pb-source-error")
      assert editor(view).tree == before
    end

    # The lower drawer is explicitly out of scope for this change and must still be there.
    test "the code drawer is untouched by the source window", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_code", %{})
      assert has_element?(view, "#pb-code-minimize")
      refute has_element?(view, "#pb-source-modal")
    end

    test "the command palette opens and filters", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_command", %{})
      assert has_element?(view, "#pb-command-input")
      assert has_element?(view, "#pb-cmd-publish")

      # By the command's own id, not by its text: "Publish" is also the label on the top bar's
      # button, so a whole-page text match would pass whether the palette filtered or not.
      render_change(view, "command_query", %{"value" => "undo"})
      assert has_element?(view, "#pb-cmd-undo")
      refute has_element?(view, "#pb-cmd-publish")
    end

    # The prototype's palette is two groups, and "Go to" is the real admin menu rather than a list of
    # routes retyped here — so it can never offer a page the viewer would be refused.
    test "the palette offers Go-to targets from the real admin menu", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      html = render(view)
      assert html =~ "Actions"
      assert html =~ "Go to"
      assert has_element?(view, ~s(a[href="/admin/dashboard/runtime/pages"]))
    end

    test "a query filters both groups, and no match says so", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      render_change(view, "command_query", %{"value" => "stylesheet"})
      html = render(view)
      assert has_element?(view, ~s(a[href="/admin/dashboard/runtime/stylesheets"]))
      refute html =~ "Actions"

      render_change(view, "command_query", %{"value" => "zzzznothing"})
      assert render(view) =~ "No matches."
    end

    test "a command's hint and shortcut both render", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      html = view |> element("#pb-cmd-save") |> render()
      assert html =~ "Write the draft"
      assert html =~ "⌘S"
    end

    # NOTHING SELECTED IS THE STATE THE BUILDER OPENS IN, and the palette offers "Delete selection"
    # in it — a plain button, no keyboard needed. It used to push a nil node id into the op funnel
    # and hand the author `Op.build/1`'s own complaint about the payload.
    test "a selection command with nothing selected answers in words", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)
      render_click(view, "toggle_command", %{})

      for id <- ~w(pb-cmd-delete pb-cmd-duplicate) do
        refute has_element?(clear_flashes(view), "#flash-info"), id
        view |> element("##{id}") |> render_click()

        assert flashes(view) =~ "Select an element on the page first.", id
        refute internals?(flashes(view)), id
        refute flashes(view) =~ "node_id", id
      end

      assert node_count(view) == before
    end

    test "the palette's delete removes the element that is selected", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "toggle_command", %{})

      view |> element("#pb-cmd-delete") |> render_click()
      refute node_with_tag(view, "h1")
    end

    # THE OTHER HALF OF THE SAME LEAK, and the one an author reaches by holding two elements and
    # clicking the bar above the page: the reason is a bare atom, which used to be printed as one.
    test "wrapping elements that are not side by side says so", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<header><h1>Title</h1></header><footer><a href="/x">Link</a></footer>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "a").id})

      view |> element("#pb-multi-wrap") |> render_click()

      refute internals?(flashes(view))
      assert flashes(view) =~ "side by side"
    end

    # THE WHOLE TABLE, SERVER-SIDE. The hook sends a name and nothing else — it knows nothing about
    # the selection or the clipboard — so every name it can send has to be answered in the author's
    # words: never an inspected struct, and never an internal field the author has no word for.
    #
    # The names are `PB_SHORTCUTS`' own (assets/js/admin_hooks.js), which is the whole list the two
    # key handlers and the preview bar can push. `code` and `preview` are toggles, so each is
    # pressed twice and the view ends where it started.
    test "every shortcut the hook can send is answered without internals", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)

      keys = ~w(undo redo save copy cut paste duplicate delete fit code code preview preview)

      for key <- keys ++ ["nosuchkey"] do
        clear_flashes(view)
        render_click(view, "shortcut", %{"key" => key})
        refute internals?(flashes(view)), key
        refute flashes(view) =~ "node_id", key
      end

      # None of them edits the page when nothing is selected and the clipboard is empty.
      assert node_count(view) == before

      render_click(view, "shortcut", %{"key" => "command"})
      assert has_element?(view, "#pb-command-input")

      render_click(view, "shortcut", %{"key" => "escape"})
      refute has_element?(view, "#pb-command-input")
    end

    # The toggle mirrors the PAGE, not the panels around it: an author checking a Persian or Arabic
    # layout wants the document flipped. It rides on the session, which is how it reaches the canvas
    # inside the iframe.
    # The all-breakpoints view is the whole page shown smaller — not a short window onto it. Its
    # frames therefore carry no fixed height and nothing scrolls inside them; the height is measured
    # in the browser and the box is simply the real width scaled down.
    test "each frame is a real device viewport, scaled", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      html = view |> element("#pb-framerow") |> render()

      # Each box is its real width times the zoom, and each frame is a real screen shown at it.
      assert html =~ "width:calc(1180px * var(--pb-frame-zoom))"
      assert html =~ "width:1180px;height:820px;zoom:var(--pb-frame-zoom)"
      assert html =~ "width:560px;height:844px;zoom:var(--pb-frame-zoom)"
      assert view |> element("#pb-canvas-scroll") |> render() =~ "--pb-frame-zoom:0.3"
    end

    # The frame row hugs the left edge in both directions. Centring it meant the frames slid sideways
    # as the zoom changed, and stacking them re-centred each one under the last.
    test "the frames view is left-aligned, in a row and stacked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      # The row's OWN opening tag: each frame's label line is legitimately `items-center`.
      row_class = fn -> view |> element("#pb-framerow") |> render() |> opening_tag() end

      assert row_class.() =~ "items-start"
      refute row_class.() =~ "items-center"
      assert view |> element("#pb-canvas-scroll") |> render() =~ "justify-start"

      view |> element("#pb-framedir") |> render_click()
      assert row_class.() =~ "flex-col"
      assert row_class.() =~ "items-start"
      refute row_class.() =~ "items-center"
    end

    test "a single frame stays centred", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert view |> element("#pb-canvas-scroll") |> render() =~ "justify-center"
    end

    # The zoom is the frame's `zoom` style, and the chrome scales a canvas right-click by exactly the
    # ratio that style paints — so the bounds it can reach are load bearing, not decoration.
    test "the canvas zoom steps, resets and stops at its bounds", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      note = fn -> view |> element("[data-role='pb-viewnote']") |> render() end
      frame = fn -> view |> element("#pb-canvas-scroll") |> render() |> opening_tag() end

      assert note.() =~ "100%"
      assert frame.() =~ "--pb-single-zoom:1.0"

      render_click(view, "zoom", %{"step" => "10"})
      assert note.() =~ "110%"
      assert frame.() =~ "--pb-single-zoom:1.1"

      render_click(view, "zoom_reset", %{})
      assert note.() =~ "100%"

      for _ <- 1..8, do: render_click(view, "zoom", %{"step" => "-10"})
      assert note.() =~ "40%"
      assert frame.() =~ "--pb-single-zoom:0.4"

      for _ <- 1..17, do: render_click(view, "zoom", %{"step" => "10"})
      assert note.() =~ "200%"
      assert frame.() =~ "--pb-single-zoom:2.0"

      # "Fit to screen" is the same reset under another name, from the keyboard.
      render_click(view, "shortcut", %{"key" => "fit"})
      assert note.() =~ "100%"
      assert frame.() =~ "--pb-single-zoom:1.0"
    end

    # The zoom is drawn once, as a custom property on the canvas scroll, and the frame reads it: a
    # zoom change re-renders no frame, and `PbZoom` can repaint the whole canvas with one write.
    test "the single frame reads the zoom from the canvas scroll", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 130})

      [scroll, frame] =
        view |> element("#pb-canvas-scroll") |> render() |> String.split(">", parts: 2)

      assert scroll =~ ~s(phx-hook="PbZoom")
      assert scroll =~ ~s(data-single-zoom="130")
      assert scroll =~ "--pb-single-zoom:1.3"
      assert frame =~ "zoom:var(--pb-single-zoom)"
      refute frame =~ "1.3"
      assert view |> element("[data-role='pb-viewnote']") |> render() =~ "130%"
    end

    # The buttons are stepped in the browser; the server hears the settled value once, so they carry
    # no `phx-click` of their own.
    test "the More menu zoom is a client control bounded by the server", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      controls = view |> element("#pb-zoom") |> render()

      assert opening_tag(controls) =~ ~s(phx-hook="PbZoom")
      assert opening_tag(controls) =~ ~s(data-min="40")
      assert opening_tag(controls) =~ ~s(data-max="200")
      assert opening_tag(controls) =~ ~s(data-event="zoom_set")
      refute controls =~ "phx-click"
      assert view |> element("#pb-zoom-in") |> render() =~ ~s(data-zoom-step="10")
      assert view |> element("#pb-zoom-out") |> render() =~ ~s(data-zoom-step="-10")
      assert view |> element("#pb-zoom-reset") |> render() =~ ~s(data-zoom-reset="100")

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 40})
      assert has_element?(view, "#pb-zoom-out[disabled]")
      refute has_element?(view, "#pb-zoom-in[disabled]")

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 200})
      assert has_element?(view, "#pb-zoom-in[disabled]")
      refute has_element?(view, "#pb-zoom-out[disabled]")
      assert view |> element("#pb-zoom-reset") |> render() =~ "200%"
    end

    test "zoom_set clamps to the bounds and ignores anything but an integer", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      zoom = fn -> :sys.get_state(view.pid).socket.assigns.zoom end

      set = fn value ->
        render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => value})
      end

      set.(150)
      assert zoom.() == 150

      set.(5)
      assert zoom.() == 40

      set.(900)
      assert zoom.() == 200

      set.("70")
      assert zoom.() == 70

      for garbage <- ["abc", "80px", "", 80.5, nil, true, %{"v" => 1}, [90]] do
        set.(garbage)
        assert zoom.() == 70, inspect(garbage)
      end

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{})
      assert zoom.() == 70
    end

    test "the frames view gets its own zoom and a row/column toggle", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      refute has_element?(view, "#pb-frzoom-in")

      render_click(view, "set_device", %{"device" => "frames"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "30%"

      controls = view |> element("#pb-frzoom") |> render()
      assert opening_tag(controls) =~ ~s(phx-hook="PbZoom")
      assert opening_tag(controls) =~ ~s(data-min="20")
      assert opening_tag(controls) =~ ~s(data-max="100")
      assert opening_tag(controls) =~ ~s(data-event="frame_zoom_set")
      refute controls =~ "phx-click"
      assert view |> element("#pb-frzoom-in") |> render() =~ ~s(data-zoom-step="10")
      assert view |> element("#pb-frzoom-out") |> render() =~ ~s(data-zoom-step="-10")
      assert view |> element("#pb-frzoom-reset") |> render() =~ ~s(data-zoom-reset="100")

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 40})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "40%"

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 100})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "100%"

      assert view |> element("#pb-framedir") |> render() =~ "In a row"
      view |> element("#pb-framedir") |> render_click()
      assert view |> element("#pb-framedir") |> render() =~ "Stacked"
    end

    test "zoom stops at the prototype's bounds", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      for _ <- 1..12, do: render_click(view, "frame_zoom", %{"step" => "-10"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "20%"
      assert has_element?(view, "#pb-frzoom-out[disabled]")

      for _ <- 1..14, do: render_click(view, "frame_zoom", %{"step" => "10"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "100%"
      assert has_element?(view, "#pb-frzoom-in[disabled]")
      refute has_element?(view, "#pb-frzoom-out[disabled]")
    end

    test "frame_zoom_set clamps to the bounds and ignores anything but an integer", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})
      zoom = fn -> :sys.get_state(view.pid).socket.assigns.frame_zoom end

      set = fn value ->
        render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => value})
      end

      set.(60)
      assert zoom.() == 60

      set.(0)
      assert zoom.() == 20

      set.(400)
      assert zoom.() == 100

      set.("50")
      assert zoom.() == 50

      for garbage <- ["abc", "60%", "", 60.0, nil, false, %{"v" => 1}, [70]] do
        set.(garbage)
        assert zoom.() == 50, inspect(garbage)
      end

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{})
      assert zoom.() == 50
    end

    # The frames never carry the zoom themselves: a zoom change rewrites the one custom property on
    # the canvas scroll and leaves every frame's markup exactly as it was.
    test "the frames read the zoom from the canvas scroll", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})
      row = view |> element("#pb-framerow") |> render()

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 60})

      scroll = view |> element("#pb-canvas-scroll") |> render() |> opening_tag()

      assert view |> element("#pb-framerow") |> render() == row
      assert scroll =~ ~s(data-frame-zoom="60")
      assert scroll =~ "--pb-frame-zoom:0.6"
      refute row =~ "zoom:0."
    end

    # The frame matching the breakpoint being edited is ringed and names the selection, so the row
    # doubles as a reminder of where an override would land.
    test "the frame for the breakpoint being edited is marked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "set_device", %{"device" => "frames"})

      html = view |> element("#pb-framerow") |> render()
      assert html =~ "border-[#8481de]"
      assert html =~ "&lt;h1&gt;"

      render_click(view, "set_breakpoint", %{"value" => "mobile"})
      assert view |> element("#pb-framerow") |> render() =~ "border-[#8481de]"
    end

    test "the direction toggle flips the canvas, not the editor chrome", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-dir-rtl") |> render_click()

      assert editor(view).dir == "rtl"

      # The chrome's own root tag only — `phx-value-dir="rtl"` on the toggle itself contains that
      # same string, so a whole-page match would pass no matter what.
      [_before, after_id] = view |> render() |> String.split("pb-root", parts: 2)
      [opening_tag, _rest] = String.split(after_id, ">", parts: 2)
      refute opening_tag =~ "dir="

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ ~s(dir="rtl")

      view |> element("#pb-dir-ltr") |> render_click()
      assert editor(view).dir == "ltr"
    end

    # Preview has to reach the CANVAS — that is where the outlines, chips and floating toolbar are
    # drawn. Held in the chrome, the button lit up and the page looked exactly the same.
    # Preview cleans the CANVAS — outlines, chips, the floating toolbar, the drop tail — and leaves
    # the editor around it alone, which is what the prototype does. Folding the panels away as well
    # made "see the page without chrome" mean "leave the editor", and there is a full-page preview
    # for that already.
    # Under 900px both panels are gone, so the bar is the only way to reach them. Four of its tabs
    # are overlays rather than panels, and one is the direction toggle.
    # Searching and filtering the library belong to the Gervaz table now — they are declared on
    # `Runtime.Media` and work the same here as on the Media page. What this pins is that the sheet
    # did not quietly lose them by mounting the component without its chrome.
    test "the library keeps the resource's own search and filters", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_media!(site_id: site.id, name: "hero-bg", type: :images)
      create_media!(site_id: site.id, name: "team-photo", type: :images)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "assets"})
      _loaded = render_async(view)

      html = render(view)
      assert html =~ "hero-bg"
      assert html =~ "team-photo"

      state = :sys.get_state(view.pid).socket.assigns
      refute state[:media_query], "the sheet no longer keeps a search of its own"
    end

    test "the registry search narrows the package list", %{conn: conn, page: page} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      assert has_element?(view, "#pb-pkg-chelekom-datatable")

      render_keyup(view, "studio_query", %{"value" => "charts"})

      refute has_element?(view, "#pb-pkg-chelekom-datatable")
      assert has_element?(view, "#pb-pkg-chelekom-charts")
    end

    # The mock adapter cannot install anything and says so; the button must surface that rather than
    # looking like it worked.
    # The default adapter is the kits on disk, so Install is a real operation: it adds the component
    # AND what it depends on, and the palette has to notice — a component you cannot then place is
    # not installed as far as the author is concerned.
    test "Install adds the component, its dependencies, and the palette entry", %{
      conn: conn,
      page: page,
      site: site
    } do
      # The on-disk kits adapter, named explicitly: the shipped default is the prototype's sample
      # catalogue, which by design has nothing real to install.
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      refute has_element?(view, "#pb-comp-chelekom-card")

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      # A master is asked where it lands; "This site" is the answer this test is about.
      view |> element("#pb-pkg-install-site-chelekom-card") |> render_click()

      html = render(view)
      assert html =~ "chelekom-card installed"

      # `card` draws an icon, so the flash says what came with it rather than only what was clicked.
      assert html =~ "it depends on"

      names = site_component_names(site)
      assert "chelekom-card" in names
      assert "chelekom-icon" in names

      # …and it is placeable now, without a reload.
      assert has_element?(view, "#pb-comp-chelekom-card")
    end

    # WHO INSTALLED IT. Every row the Registry writes went in with `authorize?: false`, so the
    # Component policy never ran on the one surface in the admin that installs a package, and its
    # version history recorded nobody. The site it lands on was already derived from the actor —
    # `UiKitHandler.install_scope/2` — and now the write is theirs too.
    test "Install is written as the admin who pressed it", %{conn: conn, page: page, site: site} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      actor = :sys.get_state(view.pid).socket.assigns.current_user
      assert is_nil(actor.site_id), "this suite logs in a master"

      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      # WHAT THIS CLICK WROTE, and not what the fixture did: everything already on this site was
      # written by a seed or a fixture with no actor, which is correct and is not what is on trial.
      before = MapSet.new(component_versions(site), & &1.id)

      view |> element("#pb-pkg-install-site-chelekom-card") |> render_click()

      written = Enum.reject(component_versions(site), &MapSet.member?(before, &1.id))

      refute written == [], "the install wrote no component versions at all"

      assert Enum.all?(written, &(&1.user_id == actor.id)),
             "a component this admin installed is attributed to nobody in its own history"
    end

    # AND THE SECOND GATE IS THE RESOURCE'S OWN. `install_scope/2` decides WHICH site a package may
    # land on; whether this actor may write a component there at all is `Component`'s policy, and
    # with the write unauthorized it was never asked. Driven below the LiveView because nobody who
    # fails that policy can open the builder in the first place — which is exactly why the write
    # had never been tested against it.
    test "Install is refused to an actor the component resource refuses", %{site: site} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      nobody = create_user_without_permissions("registry-nobody@example.com")

      assert_raise Ash.Error.Forbidden, fn ->
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.install(
          :package,
          "chelekom-card",
          site.id,
          nobody
        )
      end

      refute "chelekom-card" in site_component_names(site),
             "a refused install left components behind"
    end

    test "Install reports what the configured registry can actually do", %{conn: conn, page: page} do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-registry") |> render_click()

      view |> element("#pb-pkg-install-site-chelekom-charts") |> render_click()

      assert render(view) =~ "cannot be installed from the mock registry"
    end

    # An audit that only lists failures reads as "not checked". The prototype lists what passed too,
    # and a green row here means a real check ran over the real document.
    test "the audit lists what passed, not only what failed", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>Title</h1><a href="/x">Read more</a></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Interactive elements are labelled"
      assert html =~ "Page opens at h1"
      # A pass is not an issue, and it has nothing to fix.
      assert html =~ "healthy"
      refute has_element?(view, "#pb-audit-fix-ok-link-text")
    end

    test "a failed check replaces its passing row", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><h1>T</h1><a href="/x"></a></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      html = render(view)
      assert html =~ "Link has no visible text"
      refute html =~ "Interactive elements are labelled"
    end

    test "a preset card offers Apply for free presets and Unlock for paid ones", %{
      conn: conn,
      page: page
    } do
      Application.put_env(
        :mishka_cms_core,
        :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
      )

      on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-presets") |> render_click()

      assert has_element?(view, "#pb-preset-apply-editorial")
      assert has_element?(view, "#pb-preset-unlock-docs-portal")
      # Paid presets are the ones that carry the lock, so the two must agree.
      refute has_element?(view, "#pb-preset-apply-docs-portal")

      # The button is honest about the adapter rather than silently doing nothing.
      view |> element("#pb-preset-apply-editorial") |> render_click()
      assert render(view) =~ "Connect a registry"
    end

    test "the mobile bar swaps the body for the panel it names", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      # Nothing is duplicated: the same panels are re-pointed by the media query, so the layers panel
      # is the one that was already there.
      assert view |> element("#pb-right") |> render() =~ "max-[900px]:hidden"

      view |> element("#pb-mobtab-layers") |> render_click()

      assert view |> element("#pb-right") |> render() =~ "max-[900px]:flex"
      assert view |> element("#pb-left") |> render() =~ "max-[900px]:hidden"
      assert has_element?(view, "#pb-layers")

      view |> element("#pb-mobtab-canvas") |> render_click()
      assert view |> element("#pb-right") |> render() =~ "max-[900px]:hidden"
    end

    test "a mobile panel tab also selects that panel's tab", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-mobtab-inspector") |> render_click()

      assert has_element?(view, "#pb-lefttab-inspector.bg-white")
    end

    test "the mobile bar's overlay tabs open overlays, not panels", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-mobtab-assets") |> render_click()
      assert has_element?(view, "#pb-sheet")
      refute has_element?(view, "#pb-mobpanel")

      view |> element("#pb-mobtab-palette") |> render_click()
      assert has_element?(view, "#pb-command")
    end

    test "the mobile bar's direction tab flips the canvas", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert editor(view).dir == "ltr"

      view |> element("#pb-mobtab-dir") |> render_click()

      assert editor(view).dir == "rtl"
      assert view |> element("#pb-mobtab-dir") |> render() =~ "RTL"
    end

    test "preview strips the canvas's editor overlays and keeps the panels", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ "pb-el-toolbar"

      view |> element("#pb-preview") |> render_click()

      assert editor(view).preview?
      refute render(canvas) =~ "pb-el-toolbar"
      refute render(canvas) =~ "pb-canvas-tail"
      assert has_element?(view, "#pb-left")
      assert has_element?(view, "#pb-right")
      assert has_element?(view, "#pb-code-strip")

      view |> element("#pb-preview") |> render_click()

      refute editor(view).preview?
      assert has_element?(view, "#pb-left")
      assert render(canvas) =~ "pb-el-toolbar"
    end

    # A comment renders nothing on the live page, so preview must not show one — not even one the
    # author unfolded. An expression is the opposite: something real will be there, and hiding its
    # chip would show a gap the page lacks.
    test "preview hides comment chips but keeps expression chips", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><%!-- EDITORNOTE --%><p><%= @title %></p><!-- HTMLNOTE --></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      for kind <- [:eex_comment, :html_comment] do
        render_click(view, "toggle_hidden", %{"id" => node_with_kind(view, kind).id})
      end

      unfolded = render(canvas)
      assert unfolded =~ "EDITORNOTE"
      assert unfolded =~ "HTMLNOTE"

      view |> element("#pb-preview") |> render_click()

      previewed = render(canvas)
      refute previewed =~ "EDITORNOTE"
      refute previewed =~ "HTMLNOTE"
      assert previewed =~ "@title"
    end

    # A COMMENT IS A NOTE TO THE AUTHOR, not a thing on the page, so its chip starts folded and the
    # eye on its layers row is what unfolds it. An expression is the opposite — something real WILL
    # render there — so its chip is drawn from the first paint.
    test "comment chips start folded and the eye unfolds one", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><%!-- EDITORNOTE --%><p><%= @title %></p><!-- HTMLNOTE --></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "EDITORNOTE"
      refute html =~ "HTMLNOTE"
      assert html =~ "@title", "an expression is not a comment"

      render_click(view, "toggle_hidden", %{"id" => node_with_kind(view, :eex_comment).id})

      unfolded = render(canvas)
      assert unfolded =~ "EDITORNOTE"
      refute unfolded =~ "HTMLNOTE", "the other note was not asked for"
    end

    # A FOLDED NODE IS STILL A DOM CHILD. The canvas drop resolver reads an insertion index by
    # counting `[data-node-id]` children in order, so a folded note that left no trace would land the
    # next drop one position early — and `data-ws` is what stops it counting as content, or the `div`
    # holding nothing but a note would never get its drop floor.
    test "a folded comment keeps its place among the canvas children", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<div><!-- HTMLNOTE --><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      note = node_with_kind(view, :html_comment)

      assert html =~ ~s(data-node-id="#{note.id}"), "the slot is still a DOM child"
      assert html =~ ~s(data-ws="true" data-folded="true")
      assert html =~ ~s([data-folded="true"] { display: none; })
      refute html =~ "HTMLNOTE", "but nothing of it is drawn"
      refute html =~ ~s(phx-value-id="#{note.id}"), "and it cannot be clicked on the canvas"
    end

    # THE ROW IS THE WAY BACK. Fold the chip and the tree must still say the note is there, or the
    # only thing left pointing at it is the saved source.
    test "a comment's layers row is listed with its eye already off", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<div><%!-- EDITORNOTE --%><p>One</p></div>))

      {:ok, view, _html} = open_builder(conn, page)
      note = node_with_kind(view, :eex_comment)

      row = view |> element(~s([data-layer-row="#{note.id}"])) |> render()
      assert row =~ "Show on canvas"
      refute row =~ "Fold away on canvas"

      sibling = view |> element(~s([data-layer-row="#{node_with_tag(view, "p").id}"])) |> render()

      assert sibling =~ "Fold away on canvas",
             "nothing changed for anything that is not a comment"

      render_click(view, "toggle_hidden", %{"id" => note.id})

      assert view |> element(~s([data-layer-row="#{note.id}"])) |> render() =~
               "Fold away on canvas"
    end

    test "an open canvas follows the direction without being reloaded", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ ~s(dir="ltr")

      view |> element("#pb-dir-rtl") |> render_click()

      assert render(canvas) =~ ~s(dir="rtl")
    end

    # Filtering the view must not change which point in history a Revert button restores — the index
    # stays the one from the full list.
    test "the history sheet filters by kind without moving the revert points", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      # THE ROW IS WRITTEN ASYNCHRONOUSLY, so the delete has to be flushed before the next op or the
      # sheet opens over a list this one has not reached yet — which is what made this test pass in
      # file order and fail on its own. Its neighbour below already flushes for the same reason.
      _flushed = render_async(view)

      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => p.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "8px"
      })

      render_click(view, "open_sheet", %{"sheet" => "history"})

      html = render_async(view)
      assert html =~ "Every change to this page"
      assert html =~ "Deleted element"
      assert html =~ "Set gap (base)"

      # The pills are the resource's own filter, so they are driven the way Gervaz drives it rather
      # than by a bespoke event — and a row keeps its own id, so nothing depends on its position.
      styled = filter_history(view, "style")
      assert styled =~ "Set gap (base)"
      refute styled =~ "Deleted element"

      content = filter_history(view, "content")
      assert content =~ "Deleted element"
      refute content =~ "Set gap (base)"
    end

    test "a filter that matches nothing offers nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      _flushed = render_async(view)

      render_click(view, "open_sheet", %{"sheet" => "history"})
      assert render_async(view) =~ "Deleted element"

      # One content change and no style change: the style pill has to come back with nothing to
      # restore, rather than with the content row it was asked to exclude.
      styled = filter_history(view, "style")

      assert styled =~ "No changes recorded yet"
      refute styled =~ "Deleted element"
      refute styled =~ "history_revert"
    end

    test "the history sheet lists the session's edits", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      _flushed = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "history"})

      assert render_async(view) =~ "Deleted element"
    end

    test "collapsing a panel hides it and leaves a rail", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_left", %{})
      refute has_element?(view, "#pb-left")
      assert render(view) =~ "Components"
    end
  end

  # A FAILED READ IS NOT AN EMPTY SITE. The palette read used to end `_error -> collect_palette([])`,
  # so a dropped connection under load painted a rail with nothing in it — no flash, no log line,
  # nothing to act on — and that is indistinguishable from a site with no components installed. In
  # production it reads as "my components vanished"; in this suite it was an intermittent failure
  # that never reproduced in isolation, because it needed contention to provoke.
  #
  # `assign_async/3` already carried a failure state and the panel already rendered a `:failed` slot
  # for it. The error simply never got that far.
  # HIDING A TAB IS A COURTESY, NOT THE SECURITY. `Validations.CodeChange` refuses the write whatever
  # the editor draws — which is what makes it safe to hide anything here at all, and it is covered
  # where it belongs, against the resource, in `CodeAccessTest`.
  #
  # These drive the editor half through the DEPLOYMENT SWITCH rather than through a permission,
  # because the switch closes the surface for everybody including the `*` admin this suite signs in.
  # It is the same `code_allowed?` either way, and this keeps the assertions about the tabs rather
  # than about the login.
  describe "when this deployment does not allow author-written Elixir" do
    setup do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      :ok
    end

    test "the Code window keeps Template and Styles and loses the three that store Elixir", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      assert has_element?(view, "#pb-sourcetab-template"), "markup is what the editor is for"
      assert has_element?(view, "#pb-sourcetab-styles")

      refute has_element?(view, "#pb-sourcetab-events")
      refute has_element?(view, "#pb-sourcetab-infos")
      refute has_element?(view, "#pb-sourcetab-helpers")
    end

    # A TEMPLATE TYPED BY HAND IS CODE the server runs; what the builder generates is not.
    test "and a template typed by hand is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "apply_source", %{"source" => ~s(<div id="typed">typed</div>)})
      assert flashes(view) =~ CodeAccess.refusal()

      render_click(view, "apply_element_heex", %{"source" => ~s(<p>typed</p>)})
      refute Serializer.serialize(editor(view).tree) =~ "typed"
    end

    # A hidden tab is not a closed door: the event can be sent without one.
    test "and the events behind them are refused, not merely undrawn", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "add_code", %{"tab" => "events"})

      assert render(view) =~ "turned off on this deployment"
      refute has_element?(view, "#pb-code-entry-events-0")
      assert :sys.get_state(view.pid).socket.assigns.fragments[:events] in [nil, []]
    end

    # The block's source is markup, and markup is what the Template tab keeps for everybody.
    test "a block expression still opens its code", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><%= for post <- @posts do %><p>x</p><% end %></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      block = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :eex_block))
      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => block.id})
      view |> element("#pb-expr-block-open-code") |> render_click()

      assert has_element?(view, "#pb-sourcetab-template")
      refute has_element?(view, "#pb-sourcetab-helpers")
    end

    test "but the rest of the editor is untouched", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-root")

      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => heading.id,
        "name" => "class",
        "value" => "headline"
      })

      assert Serializer.serialize(editor(view).tree) =~ "headline"
    end
  end

  test "an author who may write code sees all five tabs", %{conn: conn, page: page} do
    {:ok, view, _html} = open_builder(conn, page)
    view |> element("#pb-code") |> render_click()

    for tab <- ~w(template events infos helpers styles) do
      assert has_element?(view, "#pb-sourcetab-#{tab}")
    end
  end

  # ONE BADGE, BESIDE THE CODE IT IS ABOUT — and not a second page listing them, which is what this
  # replaced. A warning belongs where somebody would fix it.
  describe "the code flag badge" do
    test "appears on a helper that calls something worth reading twice", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      html =
        view
        |> element("#pb-code-form")
        |> render_submit(%{
          "tab" => "helpers",
          "entry" => %{
            "0" => %{"name" => "sweep", "args" => "path", "code" => ~s|System.cmd("rm", [path])|}
          }
        })

      assert has_element?(view, "#pb-code-flag-helpers-0")
      assert html =~ "runs a program"
    end

    test "and stays away from ordinary code", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "helpers",
        "entry" => %{"0" => %{"name" => "money", "args" => "c", "code" => "c / 100"}}
      })

      refute has_element?(view, "#pb-code-flag-helpers-0")
    end

    # ORDINARY ELIXIR TOOK THE BUILDER DOWN. The badge is rendered inline in the drawer, and reading
    # the alias chain of `__MODULE__.Helpers.run/1` raised — so the save crashed the LiveView, and
    # because the fragments are loaded from the record, so did every mount after it.
    test "and a call it cannot name leaves the window standing, now and on the next mount", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()
      render_click(view, "source_tab", %{"tab" => "helpers"})
      render_click(view, "add_code", %{"tab" => "helpers"})

      view
      |> element("#pb-code-form")
      |> render_submit(%{
        "tab" => "helpers",
        "entry" => %{
          "0" => %{"name" => "sweep", "args" => "path", "code" => "__MODULE__.Helpers.run(path)"}
        }
      })

      refute has_element?(view, "#pb-code-flag-helpers-0")

      {:ok, reopened, _html} = open_builder(conn, page)
      reopened |> element("#pb-code") |> render_click()

      assert render_click(reopened, "source_tab", %{"tab" => "helpers"}) =~ "sweep"
      refute has_element?(reopened, "#pb-code-flag-helpers-0")
    end
  end

  # THE BOX IS FED FROM THE TREE, and the tree does not change when a parse fails — so the typed text
  # held out only for as long as nothing else re-rendered. One op from a collaborator, one autosave,
  # and LiveView patched the textarea back to the document, taking a page of hand-written markup with
  # it.
  describe "a refused source edit" do
    test "keeps what was typed, even after an unrelated edit re-renders the window", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      typed = "<div><p>half written"
      render_click(view, "apply_source", %{"source" => typed})

      assert has_element?(view, "#pb-source-error")
      assert render(view) =~ "half written"

      # The unrelated op: it changes the tree, which is what used to overwrite the box.
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "headline"
      })

      assert render(view) =~ "half written", "the draft outlived a tree change"
    end

    test "and lets it go once it applies", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "apply_source", %{"source" => "<div><p>half written"})
      render_click(view, "apply_source", %{"source" => "<div><p>mended</p></div>"})

      assert :sys.get_state(view.pid).socket.assigns.source_draft == nil
      assert Serializer.serialize(editor(view).tree) =~ "mended"
    end

    test "closing the window drops the draft rather than keeping it forever", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-code") |> render_click()

      render_click(view, "apply_source", %{"source" => "<div><p>half written"})
      render_click(view, "close_source", %{})

      assert :sys.get_state(view.pid).socket.assigns.source_draft == nil
    end
  end

  # A STORED TEMPLATE THE BUILDER CANNOT TOKENIZE. The Ash gate checks that a template COMPILES, and
  # the builder's own tokenizer is a different parser with different rules — `<div><p>x</div>` is
  # valid enough for HEEx and unbalanced for the tree. A page from a seed, from a hand edit, or from
  # before the gate existed therefore reaches the editor unparseable, and `mount_section/4`
  # destructured the result, so the answer was a MatchError and a crash loop on a page nobody could
  # then open to fix.
  describe "opening a page the tokenizer refuses" do
    # STRAIGHT INTO THE COLUMN, on purpose. The Ash actions refuse a template that will not compile,
    # so this state cannot be created through the front door — which is the point: it is what a seed,
    # a hand edit, or a page saved before that validation existed leaves behind, and the editor still
    # has to open it.
    defp break_template!(page, template) do
      repo = Application.fetch_env!(:mishka_cms_core, :repo)
      {:ok, id} = Ecto.UUID.dump(page.id)
      repo.query!("UPDATE pages SET template = $1 WHERE id = $2", [template, id])
      page
    end

    test "shows what is wrong and offers the source, instead of crashing", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert html =~ "could not be opened"
      assert has_element?(view, "#pb-recover")
      assert has_element?(view, "#pb-recover-source"), "the stored template is still reachable"
      assert html =~ "unclosed", "and it is the author's own text, not a summary of it"
    end

    test "the message names the line and column the tokenizer stopped at", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div>\n  <p>one\n</div>")

      {:ok, _view, html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert html =~ "Line", "a position is the only thing that makes this actionable"
    end

    test "a page that parses is unaffected", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-recover")
      assert has_element?(view, "#pb-root")
    end

    # THE POINT OF THE SCREEN. Showing the problem without a way to fix it would leave the page just
    # as unopenable as the crash did.
    test "correcting the markup opens the editor on it", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#pb-recover-form")
               |> render_submit(%{"template" => "<div><p>mended</p></div>"})

      {:ok, opened, _html} = live(conn, to)
      _ = render_async(opened)

      refute has_element?(opened, "#pb-recover")
      assert has_element?(opened, "#pb-root")

      # The document itself lives in the canvas iframe, not in this LiveView's markup, so the tree is
      # what says the correction is the thing that opened.
      assert Serializer.serialize(editor(opened).tree) =~ "mended"
    end

    # A correction that is still broken must not throw away what was typed — a minute of somebody's
    # work — and must not pretend it worked.
    test "a correction that still does not parse keeps the text and says why", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      html =
        view
        |> element("#pb-recover-form")
        |> render_submit(%{"template" => "<section><p>still wrong</section>"})

      assert has_element?(view, "#pb-recover-error")
      assert html =~ "still wrong", "what was typed is still in the box"
    end

    # THE CORRECTION IS CODE AT THE WRITE: a deployment that turns code off while the screen is open
    # stops it, whoever holds what.
    test "a correction typed after the deployment turned code off is not stored", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: "<div><p>fine</p></div>")
        |> break_template!("<div><p>unclosed</div>")

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
      assert has_element?(view, "#pb-recover-form")

      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)

      view
      |> element("#pb-recover-form")
      |> render_submit(%{"template" => "<div><p>mended</p></div>"})

      assert has_element?(view, "#pb-recover-error")

      assert Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: site.id).template ==
               "<div><p>unclosed</div>"
    end
  end

  describe "when the palette cannot be read" do
    # An invalid site id is the cheapest real failure to provoke — `for_tenant_with_globals` refuses
    # to cast it, no mocking and no sandbox tricks.
    test "the panel says so and offers a retry", %{conn: conn, page: page} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, view, _html} =
            live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=not-a-uuid")

          html = render_async(view)

          assert html =~ "The component list could not be loaded."
          assert has_element?(view, "#pb-palette-retry")
        end)

      assert log =~ "palette read failed",
             "a failure the reader can see must also leave a trace for whoever has to explain it"
    end

    # The other half: a working site must never show the failure state, or the message means nothing.
    test "a site that reads fine shows components and no retry", %{conn: conn, page: page} do
      create_component!(name: "retryless-card")

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-comp-retryless-card")
      refute has_element?(view, "#pb-palette-retry")
    end
  end

  describe "the palette" do
    setup %{site: site} do
      %{component: create_component!(site_id: site.id, name: "hero-card")}
    end

    test "lists the site's components and filters by search", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-comp-hero-card")

      render_change(view, "palette_query", %{"value" => "zzzz"})
      refute has_element?(view, "#pb-comp-hero-card")

      render_change(view, "palette_query", %{"value" => "hero"})
      assert has_element?(view, "#pb-comp-hero-card")
    end

    # Every admin table links the editor as `?site_id=…`, so this is how a master actually arrives.
    # It used to hand that site to `:master_read`, whose `TenantContext` validation refuses a non-nil
    # tenant on a multitenancy-bypass action — the read errored and the palette rendered empty.
    test "a master arriving with ?site_id= still gets the site's components", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{site.id}")

      assert has_element?(view, "#pb-comp-hero-card")
    end

    test "?site_id= scopes the palette to that site plus the global components", %{
      conn: conn,
      page: page,
      site: site
    } do
      other = create_site!(name: "other", host: "other.test", active: true)
      create_component!(site_id: other.id, name: "foreign-card")
      create_component!(name: "global-card")

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{site.id}")

      assert has_element?(view, "#pb-comp-hero-card")
      assert has_element?(view, "#pb-comp-global-card")
      refute has_element?(view, "#pb-comp-foreign-card")
    end

    # A component names its own palette glyph in `extra.icon`. Nothing else may override that — it is
    # the authored answer, and the suggestion below exists only for rows that have none.
    test "a component's own extra.icon is the glyph the palette draws", %{conn: conn, page: page} do
      create_component!(name: "kit-thing", extra: %{"icon" => "gallery"})

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-thing")) == :gallery
    end

    test "an unknown icon name falls back rather than rendering nothing", %{
      conn: conn,
      page: page
    } do
      create_component!(name: "kit-odd", extra: %{"icon" => "not-an-icon"})

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-odd")) == :box
    end

    # 183 components will not all be annotated by hand, so the palette suggests from the name.
    test "a component with no icon gets one suggested from its name", %{conn: conn, page: page} do
      for name <-
            ~w(kit-password-field kit-mega-menu kit-heading-two kit-image-block kit-data-table) do
        create_component!(name: name)
      end

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-password-field")) == :lock
      assert Panels.entry_icon(entry(view, "kit-mega-menu")) == :nav
      assert Panels.entry_icon(entry(view, "kit-heading-two")) == :head
      assert Panels.entry_icon(entry(view, "kit-image-block")) == :img
      assert Panels.entry_icon(entry(view, "kit-data-table")) == :table
    end

    test "a name that suggests nothing falls back to the component's category", %{
      conn: conn,
      page: page
    } do
      create_component!(name: "kit-zzz", type: "media")

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-zzz")) == :image
    end

    # Every card is the same box whatever its name is; one wrapping label must not make its row grow.
    test "every palette card is the same fixed height", %{conn: conn, page: page} do
      create_component!(name: "kit-x")
      create_component!(name: "kit-with-a-very-long-name-that-wraps-twice")

      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      [short, long] =
        for name <- ~w(kit-x kit-with-a-very-long-name-that-wraps-twice) do
          [_before, after_id] = String.split(html, ~s(id="pb-comp-#{name}"), parts: 2)
          [tag, _rest] = String.split(after_id, ">", parts: 2)
          tag =~ "h-[86px]"
        end

      assert short
      assert long
      assert html =~ "line-clamp-2"
    end

    # The kit's own name is on every one of its components, so printing it on every card spends the
    # label on the one word that never varies and pushes the part that does off the card.
    test "a kit prefix is dropped from the card label but kept everywhere else", %{
      conn: conn,
      page: page
    } do
      for name <- ~w(acme-alert acme-toast acme-banner solo-widget) do
        create_component!(name: name)
      end

      {:ok, view, _html} = open_builder(conn, page)
      entries = editor(view) |> Map.fetch!(:components)
      prefixes = Panels.kit_prefixes(entries)

      assert Panels.short_label(entry(view, "acme-alert"), prefixes) == "Alert"
      assert Panels.short_label(entry(view, "acme-banner"), prefixes) == "Banner"

      # Used three times, "acme" is a kit; "solo" is used once and stays.
      assert Panels.short_label(entry(view, "solo-widget"), prefixes) == "Solo Widget"

      # The full name is still what the card is titled with and what it inserts.
      assert view |> element("#pb-comp-acme-alert") |> render() =~ "acme-alert"
    end

    test "picking a component arms placement, and placing inserts it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-hero-card") |> render_click()
      assert render(view) =~ "Placing hero-card"

      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert inserted.tag == ".component"
      assert MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(inserted) == "hero-card"
      refute render(view) =~ "Placing hero-card"
    end

    # The click that places happens inside the CANVAS, which is a different LiveView — so an
    # arming flag kept in the chrome's own assigns left the browser selecting elements while the hint
    # said "click the canvas". This drives the two the way a person does.
    test "arming in the chrome and clicking IN THE CANVAS places the component", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-hero-card") |> render_click()
      section = node_with_tag(view, "section")
      render_click(canvas, "select", %{"id" => section.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert placed
      # Inside the clicked container, as its last child — and the arming is spent.
      assert placed.parent_id == section.id
      refute render(view) =~ "Placing hero-card"
    end

    # Clicking a component that declares no slot is someone pointing at WHERE they want the new
    # element, not a request to nest it there. The browser answered that with a red
    # "does not declare a slot" toast and placed nothing.
    test "clicking an element that cannot hold children places after it", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-leaf", nil, "<hr/>")
      create_component!(name: "pb-leaf")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><.component component_name="pb-leaf" site="Global" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      leaf =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(canvas, "select", %{"id" => leaf.id})

      tree = view |> editor() |> Map.fetch!(:tree)
      placed = tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "hero-card"))

      assert placed
      # A sibling of the leaf, not a child of it.
      assert placed.parent_id == leaf.parent_id
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, leaf.id) + 1
    end

    test "a canvas click with nothing armed still selects", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      section = node_with_tag(view, "section")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(canvas, "select", %{"id" => section.id})

      assert view |> editor() |> Map.fetch!(:selection) == section.id
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "a click on no element places at the end of the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(canvas, "select", %{})

      tree = view |> editor() |> Map.fetch!(:tree)
      assert tree |> Tree.get(List.last(tree.roots)) |> Map.fetch!(:kind) == :component
    end

    # Dropping a global component onto a site's page has to render it. The palette used to bind every
    # card to the page's site, which for a global component named a module nobody ever built.
    test "placing a GLOBAL component from the palette renders it on the canvas", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-drop-footer", nil, "<footer>dropped global footer</footer>")
      create_component!(name: "pb-drop-footer")

      page = create_page!(site_id: site.id, template: ~s(<div id="root"></div>))
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-pb-drop-footer") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "0"})

      assert editor_html(view) =~ ~s(site="Global")

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ "dropped global footer"
      refute html =~ "failed to render"
    end

    test "selecting a placed component shows its properties as real controls", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "fancy-box",
        attrs: [
          %{"name" => "color", "type" => "string", "opts" => %{}},
          %{"name" => "variant", "type" => "string", "opts" => %{}},
          %{"name" => "disabled", "type" => "boolean", "opts" => %{}},
          %{"name" => "title", "type" => "string", "opts" => %{"required" => true}}
        ],
        helpers: [
          %{
            "name" => "color_class",
            "args" => "color",
            "code" => "defp color_class(_), do: \"\"",
            "discriminators" => [
              %{"axis" => "color", "values" => ~w(primary secondary danger warning info light)},
              %{"axis" => "variant", "values" => ~w(base filled)}
            ]
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-fancy-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # EVERY declared property is on the form, each as its own typed control. A component's option
      # surface is what the author opened the inspector for; showing only the ones already set meant
      # alert's seventeen properties arrived as two.
      html = render(view)
      assert html =~ "Title"
      assert html =~ "Required"
      assert html =~ "Variant"
      assert html =~ "Color"
      assert html =~ "Disabled"

      # …and they are sectioned, not one flat column.
      assert html =~ "Appearance"

      # The preset rides in the button's OWN `value`, not `phx-value-value`: LiveView overwrites the
      # latter with `el.value`, which on a button is empty, so the preset arrived blank.
      assert html =~ ~s(value="filled")
      refute html =~ ~s(phx-value-value=)

      # A six-value list is a select, a two-value list is segmented, a boolean is a switch.
      assert html =~ "<select"
      assert html =~ ~s(<option value="secondary")
      assert html =~ ~s(role="switch")

      # A required property keeps its delete control, disabled — an absent one would read as
      # "look somewhere else".
      assert view |> element("#pb-attr-clear-#{placed.id}-title") |> render() =~ "disabled"
    end

    # A component's own properties open; the chrome under a long panel does not. Sixteen rows of
    # properties with the state pills wedged above them is the layout the fold exists to fix, and a
    # plain element with no properties at all keeps its chrome open. The BREAKPOINT strip is exempt:
    # it is what tells a reader which device the settings below belong to, and a fold that hides that
    # is how someone edits Mobile believing they are editing Desktop.
    test "on a component with many properties the chrome starts folded and the properties do not",
         %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: site.id,
        name: "wide-box",
        attrs:
          Enum.map(~w(a b c d e f g h i j), &%{"name" => &1, "type" => "string", "opts" => %{}})
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-wide-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      assert html =~ "pb-attr-#{placed.id}-a"
      refute html =~ "pb-state-hover", "State starts folded behind a long property panel"

      # The breakpoint tabs are always on screen — they name the scope of everything under them.
      assert html =~ "pb-bp-tablet"

      # …and the folded chrome opens on the reader's say-so, because the heading tells the server
      # which state it is in rather than making the toggle guess at the default.
      assert view |> element("#pb-section-state") |> render_click() =~ "pb-state-hover"
    end

    # "Layout" names both a property group of a component and a section of the style panel. They were
    # one key and one DOM id, so folding either folded both — and duplicate ids break DOM patching.
    test "folding a component's Layout group leaves the style panel's Layout alone", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "gap-box",
        attrs: [%{"name" => "padding", "type" => "string", "opts" => %{}}]
      )

      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-gap-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # The two "Layout"s are different things — a property group of the COMPONENT and a section of
      # the style panel — and they keep separate fold state. The style one is open on selection, so
      # the claim is that toggling either leaves the other exactly as it was.
      assert render(view) =~ "pb-style-form-base-gap"

      assert view |> element("#pb-prop-layout") |> render_click() =~ "pb-style-form-base-gap"
      assert view |> element("#pb-prop-layout") |> render_click() =~ "pb-style-form-base-gap"

      # And back the other way: closing the style section does not close the component's group.
      view |> element("#pb-section-layout") |> render_click()
      html = view |> element("#pb-prop-layout") |> render_click()

      assert html =~ "pb-attr-#{placed.id}-padding"
      refute html =~ "pb-style-form-base-gap"
    end

    # A component that declares a property as required will not render without it, so a page missing
    # one is already broken — publishing it just puts the breakage in front of visitors. A DRAFT is
    # allowed to be half-finished; that is what a draft is.
    test "a missing required property blocks the save and names itself", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "needs-title",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{"required" => true}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-needs-title") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      html = publish!(view)
      assert html =~ "Not saved"
      assert html =~ "needs-title.title"

      # Fill it and the save goes through.
      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "title",
        "value" => "Real title"
      })

      assert save!(view) =~ "saved"
    end

    # Blurring a field you only clicked into must not wipe the component's default.
    test "leaving an untouched property alone keeps the default", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "defaulted",
        attrs: [%{"name" => "message", "type" => "string", "opts" => %{"default" => "Hello"}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-defaulted") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # What a blur with nothing typed sends.
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "message",
        "value" => ""
      })

      # The attribute is gone, so the component renders its own default again rather than an empty
      # string that overrides it.
      node = view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id)
      assert Node.attr_text(node, "message") == nil
    end

    test "editing a prop writes the attribute and clearing it removes it", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "plain-box")
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-plain-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "variant",
        "value" => "filled"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id) |> Node.attr("variant") ==
               {:string, "filled"}

      render_click(view, "op", %{
        "kind" => "delete_attr",
        "node_id" => placed.id,
        "name" => "variant"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id) |> Node.attr("variant") ==
               nil
    end

    test "a placed component serializes in the form the compilers read", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(component_name="hero-card")
      assert reloaded.template =~ "<.component"
    end
  end

  # THE SHEET, through the LiveView that opens it. The template's own suite proves what a row looks
  # like; this proves the sheet is wired to the log at all — which is the part that was broken in
  # three different ways, each of them silent.
  describe "the editing history sheet" do
    test "a site admin sees its own people's edits by email and a master's as Master", %{
      conn: conn,
      page: page,
      site: site
    } do
      master =
        User |> Ash.Query.filter(email == "boss@example.com") |> Ash.read_one!(authorize?: false)

      tenant = create_admin("history-tenant@example.com", site.id)
      by_master = record_change(page, master, "By the master")
      by_tenant = record_change(page, tenant, "By the site")

      {:ok, theirs, _html} = open_builder(log_in(build_conn_for_host(), tenant), page)
      render_click(theirs, "open_sheet", %{"sheet" => "history"})
      render_async(theirs)

      assert history_author(theirs, by_master) == "Master"
      assert history_author(theirs, by_tenant) == "history-tenant@example.com"
      refute render(theirs) =~ "boss@example.com"
      refute render(theirs) =~ ">boss<"

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "history"})
      render_async(view)

      assert history_author(view, by_master) == "boss@example.com"
      assert history_author(view, by_tenant) == "history-tenant@example.com"
    end

    test "a site admin sees an assistant's change a master annotated as annotated by Master", %{
      conn: conn,
      page: page,
      site: site
    } do
      master =
        User |> Ash.Query.filter(email == "boss@example.com") |> Ash.read_one!(authorize?: false)

      tenant = create_admin("history-annotated@example.com", site.id)

      row =
        page
        |> record_assistant_change(tenant, "Added social proof")
        |> Ash.Changeset.for_update(:annotate, %{note: "Checked on a phone."},
          tenant: site.id,
          actor: master,
          authorize?: false
        )
        |> Ash.update!()

      {:ok, theirs, _html} = open_builder(log_in(build_conn_for_host(), tenant), page)
      render_click(theirs, "open_sheet", %{"sheet" => "history"})
      render_async(theirs)

      assert history_author(theirs, row) == "Assistant · annotated by Master"
      refute render(theirs) =~ "boss@example.com"
      refute render(theirs) =~ ">boss<"

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_sheet", %{"sheet" => "history"})
      render_async(view)

      assert history_author(view, row) == "Assistant · annotated by boss@example.com"
    end

    test "an edit reaches the log, with the person who made it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => node_with_tag(view, "h1").id,
        "text" => "Talk to us"
      })

      _flushed = render_async(view)

      assert [row | _] = history_rows(page)
      assert row.op == :set_text
      assert row.source_type == :page
      assert row.site_id == page.site_id
      assert row.author_id == :sys.get_state(view.pid).socket.assigns.current_user.id
    end

    test "the sheet lists what the log holds", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => node_with_tag(view, "h1").id,
        "text" => "Talk to us"
      })

      _flushed = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "history"})
      html = render_async(view)

      assert html =~ "Edited text"
      assert html =~ "history_revert"
    end

    # The empty-state line is always in the markup — it is shown by CSS when it is the only child —
    # so its presence proves nothing. What proves the list is empty is that no row is offering to
    # restore anything.
    # THE URL SAYS "error-page", THE LOG SAYS `:error_page`. Converting the address form crashed
    # mount for that one section, so the editor would not open on an error page at all — and it did
    # so before anything was rendered, which is why it read as a dead route rather than a bad sheet.
    test "the sheet opens on every section, including the one spelled two ways", %{
      conn: conn,
      site: site
    } do
      error_page = create_error_page!(site_id: site.id, status: 404)

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "history"})

      assert render_async(view) =~ "No changes recorded yet"
    end

    test "a page with no history offers nothing to restore", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_sheet", %{"sheet" => "history"})
      html = render_async(view)

      assert html =~ "No changes recorded yet"
      refute html =~ "history_revert"
    end

    test "reverting puts the document back and records that it did", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => node_with_tag(view, "h1").id,
        "text" => "Talk to us"
      })

      _flushed = render_async(view)
      [row] = history_rows(page)

      render_click(view, "history_revert", %{"id" => row.id})
      _reverted = render_async(view)

      # THE "RESTORED" ROW IS A SECOND TASK'S. The revert's task only puts the tree back; the editor
      # hears the session change and starts the flush that writes the row — after the wait above
      # listed the tasks it would wait for, but before it returned. So one more wait covers it.
      _recorded = render_async(view)

      assert Serializer.serialize(editor(view).tree) =~ "Contact Us"
      assert Enum.any?(history_rows(page), &(&1.op == :restore))
    end

    # THE CHROME USED TO DECIDE "did the document move?" by measuring the undo stack, which was capped
    # at fifty — so from the fifty-first change of a sitting the measurement never moved again and
    # this stopped writing rows, and stopped autosaving the draft, for the rest of the afternoon.
    #
    # Both halves of that are gone now: the chrome counts revisions, and the stack is bounded by
    # memory rather than by fifty. Fifty-five changes is past where the old cap sat, so it still
    # exercises the case that broke.
    test "a long sitting keeps being recorded, and keeps every step", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      for n <- 1..55 do
        render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => h1.id,
          "name" => "data-n#{n}",
          "value" => to_string(n)
        })
      end

      _flushed = render_async(view)

      assert length(editor(view).past) == 55,
             "a step was dropped; the budget should be nowhere near"

      assert length(history_rows(page)) == 55

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => h1.id,
        "text" => "still recorded"
      })

      _flushed = render_async(view)

      assert Enum.any?(history_rows(page), &(&1.op == :set_text)),
             "the change after the cap was not recorded"
    end

    test "a restore clears its own in-flight flag", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => node_with_tag(view, "h1").id,
        "text" => "Talk to us"
      })

      _flushed = render_async(view)
      [row] = history_rows(page)

      render_click(view, "history_revert", %{"id" => row.id})
      _restored = render_async(view)

      refute :sys.get_state(view.pid).socket.assigns.history_reverting?
    end

    test "clearing takes the whole page's history", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => node_with_tag(view, "h1").id,
        "text" => "Talk to us"
      })

      _flushed = render_async(view)
      refute history_rows(page) == []

      render_click(view, "history_clear", %{})
      _cleared = render_async(view)

      assert history_rows(page) == []
    end

    # THE SHEET DOES NOT RE-READ ITSELF. A publish takes the payload out from under every row below
    # it, and a sheet left open across one kept drawing Restore buttons over documents that were
    # already gone — the press fails safe, but the offer should never have been on screen.
    #
    # The published stage, so the sitting holds no draft: with one, the branch the sheet is reading
    # changes at the publish and the table re-reads for that reason instead of this one.
    test "a sheet open across a publish stops offering what the publish swept", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_stage", %{"stage" => "published"})

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => node_with_tag(view, "h1").id,
        "text" => "Talk to us"
      })

      _flushed = render_async(view)
      render_click(view, "open_sheet", %{"sheet" => "history"})
      assert render_async(view) =~ "history_revert"

      render_click(view, "apply_stage", %{})
      _collected = render_async(view)

      refute render_async(view) =~ "history_revert"
    end
  end

  # A CSS BODY IS AUTHORED TEXT, AND THE CANVAS PUTS IT IN A `<style>` TAG. `</style>` ends that tag
  # wherever it appears, so the browser stops reading CSS and starts reading markup: the rest of the
  # body becomes elements in the canvas document. Every body the canvas styles with is authored —
  # an element's own box, a site's stylesheet row — so the sequence can arrive.
  describe "a CSS body that tries to close the style tag" do
    setup %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><p>hello</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      %{view: view, conn: conn, node: node}
    end

    defp canvas_html(conn, view) do
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      html
    end

    test "cannot close it", %{conn: conn, view: view, node: node} do
      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => ~s|color: red;\n/* </style><span id="escaped">out</span> */|
      })

      html = canvas_html(conn, view)

      refute html =~ ~s(</style><span id="escaped")
      assert html =~ "<\\/style"
    end

    test "and neither can a shouted one", %{conn: conn, view: view, node: node} do
      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => ~s|color: red;\n/* </STYLE><span id="shouted">out</span> */|
      })

      refute canvas_html(conn, view) =~ ~s(</STYLE><span id="shouted")
    end

    # The escape belongs at the boundary, not in storage: the same body is served as a real
    # stylesheet, where the sequence is unremarkable and has to survive untouched.
    test "while what is stored is exactly what was written", %{view: view, node: node} do
      body = ~s|color: red;\n/* </style> */|

      render_click(view, "save_element_css", %{"node_id" => node.id, "css" => body})

      stored = :sys.get_state(view.pid).socket.assigns.element_css_rules

      assert stored |> Map.values() |> Enum.join() =~ "</style>"
    end
  end

  # The advice was computed only when Apply was pressed, so a bad selector saved yesterday was silent
  # when the panel was opened on it today — the case where an author is most likely to be wondering
  # why their CSS does nothing.
  describe "advice about a stored body" do
    test "shows when the panel is opened on CSS that was already saved", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<div id="root"><p>hello</p></div>))

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => "main { color: red }"
      })

      render_click(view, "select", %{"id" => node.id})

      assert :sys.get_state(view.pid).socket.assigns.element_css_advice =~ "INSIDE this element"
    end

    test "and says nothing about a body that is only declarations", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<div id="root"><p>hello</p></div>))

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      render_click(view, "save_element_css", %{"node_id" => node.id, "css" => "color: red;"})
      render_click(view, "select", %{"id" => node.id})

      assert :sys.get_state(view.pid).socket.assigns.element_css_advice == nil
    end
  end

  # A FIELD JOINS A FORM, spec 4.4. Two forms on a page, fields three levels down (card > grid >
  # column): Phoenix's own with its Send in the card footer, and a raw `<form>` that does not work.
  describe "a field joining a form" do
    @joining ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit">) <>
               ~s(<div id="c-card" class="card"><div id="c-grid" class="grid"><div id="c-col"><input id="name-box" name={f[:name].name} /></div>) <>
               ~s(<div id="c-col-2"><label id="agree-label"><input type="hidden" name={f[:agree].name} value="false" /><input id="agree-box" type="checkbox" name={f[:agree].name} value="true" />I agree</label></div></div>) <>
               ~s(<footer id="c-foot"><button id="c-send" type="submit">Send</button></footer></div></.form>) <>
               ~s(<.form :let={g} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">) <>
               ~s(<div class="card"><div class="grid"><div id="n-col"><input id="news-email" name={g[:email].name} /></div></div></div><button id="n-send" type="submit">Join</button></.form>) <>
               ~s(<form id="raw-form"><input name="q" /></form><section id="band"><div id="loose"></div></section></div>)

    defp joining(conn, site) do
      page = create_page!(site_id: site.id, template: @joining)
      {:ok, view, _html} = open_builder(conn, page)
      view
    end

    defp dom(view, id),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "id") == id))

    test "the canvas marks each form with its people name and where a field at its end lands", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(
               canvas,
               ~s([data-node-id="#{dom(view, "contact-form").id}"][data-pb-form="Contact"])
             )

      assert has_element?(
               canvas,
               ~s([data-node-id="#{dom(view, "news-form").id}"][data-pb-form="News"])
             )

      assert has_element?(
               canvas,
               ~s([data-node-id="#{dom(view, "raw-form").id}"][data-pb-form=""])
             )

      assert has_element?(canvas, ~s([data-node-id="#{dom(view, "c-send").id}"][data-pb-send]))
      assert has_element?(canvas, ~s([data-node-id="#{dom(view, "n-send").id}"][data-pb-send]))
      refute has_element?(canvas, ~s([data-node-id="#{dom(view, "c-col").id}"][data-pb-form]))
      assert render(canvas) =~ "html[data-pb-field-drag] [data-pb-form]"
    end

    # A kit form declares `for` with no default, like Chelekom's Form Wrapper: wired, it names a page
    # assign the canvas does not have, and the canvas still has to draw it.
    test "a kit form that arrived working is drawn on the canvas", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "acme-lends",
        attrs: [
          %{"name" => "for", "type" => "any", "opts" => %{}},
          %{"name" => "as", "type" => "any", "opts" => %{}},
          %{"name" => "id", "type" => "string", "opts" => %{}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ],
        slots: [%{"name" => "inner_block"}],
        template:
          ~S|<.form :let={f} for={@for} as={@as} id={@id} {@rest}>{render_slot(@inner_block, f)}</.form>|
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="acme-lends" site="localhost" :let={f} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><input id="news-email" name={f[:email].name} /></.component></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute render(canvas) =~ "could not render"
      refute render(canvas) =~ "failed to render"
      assert has_element?(canvas, ~s([data-pb-form="News"] form input#news-email))
    end

    test "a drag start says whether a field is being dragged, from either surface", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      for surface <- [view, canvas] do
        render_click(surface, "drag_start", %{"template" => ~s(<input name="phone" />)})
        assert_push_event(surface, "pb:drop-hints", %{field: true, accepts: %{}})

        render_click(surface, "drag_start", %{"node_id" => dom(view, "agree-box").id})
        assert_push_event(surface, "pb:drop-hints", %{field: true})

        render_click(surface, "drag_start", %{"template" => "<section></section>"})
        assert_push_event(surface, "pb:drop-hints", %{field: false})
      end
    end

    test "a field dropped on a form's bottom edge joins it before the Send in its card footer", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      form = dom(view, "contact-form")

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="phone" />),
        "parent_id" => dom(view, "root").id,
        "index" => "1",
        "anchor_id" => form.id,
        "anchor_before" => false
      })

      assert flashes(view) =~ "Added it to the Contact form."
      footer = dom(view, "c-foot")
      [phone, send] = view |> editor() |> Map.fetch!(:tree) |> Tree.children(footer.id)
      assert Node.attr_text(phone, "name") == "f[:phone].name"
      assert Node.attr_text(send, "id") == "c-send"
    end

    test "a field dropped outside every form starts one with a Send button", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="phone" />),
        "parent_id" => dom(view, "loose").id,
        "index" => "0"
      })

      assert flashes(view) =~ "Started a new form with a Send button."
      assert flashes(view) =~ "choose it under In form in the Inspector"

      specs =
        view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() |> PageForms.declared()

      assert Enum.map(specs, & &1.as) == ~w(contact news form)
    end

    test "a form made by a drop is announced on builder:form:after_create", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      view = joining(conn, site)

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="phone" />),
        "parent_id" => dom(view, "loose").id,
        "index" => "0"
      })

      assert_receive {FormCreatedProbe, summary}
      assert summary.how == :started
      assert summary.seed == "form"
      assert summary.token =~ ~r/^[a-z2-7]{5}$/
      assert PageForms.form?(view |> editor() |> Map.fetch!(:tree) |> Tree.get(summary.node_id))

      render_click(view, "drop", %{
        "template" => ~s(<input type="tel" name="fax" />),
        "parent_id" => dom(view, "n-col").id,
        "index" => "0"
      })

      refute_receive {FormCreatedProbe, _joined}, 200
    end

    test "a form made by a drop placed beside a locked column is announced too", %{
      conn: conn,
      site: site
    } do
      renamed_forms!(site)
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<section id="band">),
              ~s(<div class="card"><div class="grid"><div id="l-col"><p>Here</p></div></div></div><section id="band">)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _locked} = EditorSession.toggle_lock(token(view), dom(view, "l-col").id)

      for {template, how} <- [
            {~s(<input type="tel" name="phone" />), :started},
            {~s(<.component component_name="acme-wrapper" site="localhost" for={%{}}><input type="email" name="email" /></.component>),
             :wired}
          ] do
        render_click(view, "drop", %{
          "template" => template,
          "parent_id" => dom(view, "l-col").id,
          "index" => "0"
        })

        assert flashes(view) =~ "That element is locked."
        assert_receive {FormCreatedProbe, %{how: ^how, node_id: id}}

        assert Tree.get(view |> editor() |> Map.fetch!(:tree), id).parent_id !=
                 dom(view, "l-col").id
      end
    end

    test "a form the audit's Fix puts around a field deep in a card is announced as fixed", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<div id="loose"></div>),
              ~s(<div class="card"><div class="grid"><div id="l-col"><input id="stray" name="phone" /></div></div></div>)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()
      view |> element(~s([data-rule="field-no-form"])) |> render_click()

      assert_receive {FormCreatedProbe, %{how: :fixed, seed: "form", node_id: id}}
      tree = view |> editor() |> Map.fetch!(:tree)
      assert PageForms.form?(Tree.get(tree, id))
      assert Tree.get(tree, id).parent_id == dom(view, "l-col").id

      assert tree
             |> Tree.descendant_ids(id)
             |> Enum.any?(&(Node.attr_text(Tree.get(tree, &1), "name") == "f[:phone].name"))

      refute_receive {FormCreatedProbe, _another}, 200
    end

    test "a form the audit's Fix makes work is announced as fixed, a renamed one is not", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<div id="loose"></div>),
              ~s(<div class="card"><div class="grid"><div id="l-col">) <>
                ~s(<.form :let={h} id="bare-form" as={:bare} phx-change="bare-q2w3e-validate" phx-submit="bare-q2w3e-submit"><input name={h[:note].name} /><button type="submit">Send</button></.form>) <>
                ~s(<.form :let={k} id="twin-form" as={:news} for={assigns[:twin_form]} phx-change="news-r4t5y-validate" phx-submit="news-r4t5y-submit"><input name={k[:code].name} /><button type="submit">Send</button></.form>) <>
                ~s(</div></div></div>)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-rail-audit") |> render_click()

      view
      |> element(~s([data-rule="form-no-source"][phx-value-id="#{dom(view, "bare-form").id}"]))
      |> render_click()

      assert_receive {FormCreatedProbe, %{how: :fixed, seed: "bare", node_id: id}}
      assert id == dom(view, "bare-form").id

      view
      |> element(~s([data-rule="form-duplicate-seed"]))
      |> render_click()

      assert view |> declared_forms() |> Enum.map(& &1.as) |> Enum.sort() ==
               ~w(bare contact news news_2)

      refute_receive {FormCreatedProbe, _renamed}, 200
    end

    test "the Validation note names each form the way Layers does", %{conn: conn, site: site} do
      renamed_forms!(site)

      page =
        create_page!(
          site_id: site.id,
          template:
            String.replace(
              @joining,
              ~s(<div id="loose"></div>),
              ~s(<div id="loose"></div><.component component_name="acme-wrapper" site="localhost" :let={w} id="kit-form" as={:contact_us} for={assigns[:contact_us_form]} phx-change="contact_us-z2x3c-validate" phx-submit="contact_us-z2x3c-submit">) <>
                ~s(<div class="card"><div class="grid"><div id="k-col"><input id="kit-email" name={w[:email].name} /></div></div></div></.component>)
            )
        )

      {:ok, view, _html} = open_builder(conn, page)

      for {name, parent} <- [{"phone", "loose"}, {"fax", "band"}] do
        render_click(view, "drop", %{
          "template" => ~s(<input type="text" name="#{name}" />),
          "parent_id" => dom(view, parent).id,
          "index" => "0"
        })
      end

      bound = fn key ->
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "name") == "f[:#{key}].name"))
      end

      for {node, sentence} <- [
            {bound.("phone"), "phone in Form 1."},
            {bound.("fax"), "fax in Form 2."},
            {dom(view, "name-box"), "name in the Contact form."},
            {dom(view, "kit-email"), "email in the Contact us form."}
          ] do
        render_click(view, "select", %{"id" => node.id})
        view |> element("#pb-lefttab-inspector") |> render_click()

        assert has_element?(view, "#pb-rule-note", sentence), sentence
        refute render(element(view, "#pb-rule-note")) =~ ~r/form form|form_2|contact_us/
      end
    end

    test "a field moved into a new form from In form is announced as moved", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      view = joining(conn, site)
      field_in(view, "agree-box")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => dom(view, "news-form").id})

      refute_receive {FormCreatedProbe, _joined}, 200

      field_in(view, "agree-box")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => FormPlacement.new_target()})

      assert_receive {FormCreatedProbe, %{how: :moved, seed: "form", node_id: id}}
      tree = view |> editor() |> Map.fetch!(:tree)
      assert Tree.descendant?(tree, id, dom(view, "agree-label").id)

      render_click(view, "drop", %{
        "node_id" => dom(view, "name-box").id,
        "parent_id" => dom(view, "loose").id,
        "index" => "0"
      })

      assert_receive {FormCreatedProbe, %{how: :moved, seed: "form_2", node_id: dragged}}
      tree = view |> editor() |> Map.fetch!(:tree)
      assert Tree.descendant?(tree, dragged, dom(view, "name-box").id)
    end

    defp field_in(view, id) do
      render_click(view, "select", %{"id" => dom(view, id).id})
      view |> element("#pb-lefttab-inspector") |> render_click()
    end

    test "a field's Inspector says which form sends it, by people name", %{conn: conn, site: site} do
      view = joining(conn, site)
      field_in(view, "agree-box")

      assert has_element?(view, "#pb-section-in-form", "In form")

      assert has_element?(
               view,
               ~s(#pb-field-form option[value="#{dom(view, "contact-form").id}"][selected]),
               "Contact"
             )

      assert has_element?(
               view,
               ~s(#pb-field-form option[value="#{dom(view, "news-form").id}"]),
               "News"
             )

      assert has_element?(
               view,
               ~s(#pb-field-form option[value="#{FormPlacement.new_target()}"]),
               "A new form"
             )

      refute has_element?(view, ~s(#pb-field-form option[value="#{dom(view, "raw-form").id}"]))

      field_in(view, "c-grid")
      refute has_element?(view, "#pb-field-form")
    end

    test "choosing another form moves the checkbox unit there, as one undo step", %{
      conn: conn,
      site: site
    } do
      view = joining(conn, site)
      before = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()
      label = dom(view, "agree-label")
      field_in(view, "agree-box")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => dom(view, "news-form").id})

      assert flashes(view) =~ "Moved it to the News form."
      moved = view |> editor() |> Map.fetch!(:tree)
      assert Tree.get(moved, label.id).parent_id == dom(view, "c-col-2").id
      assert Tree.get(moved, dom(view, "c-col-2").id).parent_id == dom(view, "news-form").id

      assert Serializer.serialize(moved) =~
               ~s(<input type="hidden" name={g[:agree].name} value="false")

      assert Serializer.serialize(moved) =~ ~s(name={g[:agree].name} value="true")

      {:ok, undone} = EditorSession.undo(token(view))
      assert Serializer.serialize(undone.tree) == before
    end

    test "a form's last field moved away takes the empty form with it", %{conn: conn, site: site} do
      view = joining(conn, site)
      field_in(view, "news-email")

      view
      |> element("#pb-field-form-form")
      |> render_change(%{"form" => dom(view, "contact-form").id})

      assert flashes(view) =~ "Moved it to the Contact form. The empty form was removed."
      assert dom(view, "news-form") == nil
    end

    test "a selected form offers Move its fields into, as one step", %{conn: conn, site: site} do
      view = joining(conn, site)
      field_in(view, "contact-form")

      assert has_element?(
               view,
               ~s(#pb-form-merge option[value="#{dom(view, "news-form").id}"]),
               "News"
             )

      refute has_element?(
               view,
               ~s(#pb-form-merge option[value="#{dom(view, "contact-form").id}"])
             )

      view
      |> element("#pb-form-merge-form")
      |> render_change(%{"form" => dom(view, "news-form").id})

      assert flashes(view) =~ "Moved its fields to the News form. The empty form was removed."

      specs =
        view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() |> PageForms.declared()

      assert [%{as: "news", fields: fields}] = specs
      assert Enum.map(fields, & &1.key) == [:email, :name, :agree]
    end

    test "Layers and the crumb bar call a form by its people name", %{conn: conn, site: site} do
      view = joining(conn, site)

      assert has_element?(view, "#pb-layer-form-#{dom(view, "contact-form").id}", "Contact")
      assert has_element?(view, "#pb-layer-form-#{dom(view, "news-form").id}", "News")
      refute has_element?(view, "#pb-layer-form-#{dom(view, "raw-form").id}")

      render_click(view, "select", %{"id" => dom(view, "name-box").id})
      assert has_element?(view, ~s([data-role="pb-crumbs"] button), "Contact")
    end
  end

  # The Inspector's Form panel, on the two deep forms: Phoenix's `<.form>` and Chelekom's Form
  # Wrapper wired as a page form, each field and Send button in a column of a grid in a card.
  describe "the Form panel" do
    defp nodes_in(view, form_id, pick),
      do:
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> then(fn tree ->
          tree |> Tree.descendant_ids(form_id) |> Enum.map(&Tree.get(tree, &1))
        end)
        |> Enum.filter(pick)

    defp buttons_in(view, form_id), do: nodes_in(view, form_id, &(&1.tag == "button"))

    defp html_of(view), do: view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()

    test "How it works: as they type takes out the Send button and keeps phx-submit; Send puts it back",
         %{conn: conn, site: site} do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_setting")
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for {dom_id, seed} <- [{"contact-form", "contact"}, {"news-form", "news"}] do
        form = with_dom_id(view, dom_id)
        before = html_of(view)
        inspecting(view, form)

        assert has_element?(
                 view,
                 ~s(#pb-section-form ~ div #pb-form-how #pb-rule-how-send[aria-pressed="true"])
               )

        view |> element("#pb-rule-how-typing") |> render_click()

        typed = node_again(view, form.id)
        assert PageForms.as_typed?(typed)
        assert Node.attr_text(typed, "phx-submit") == Node.attr_text(form, "phx-submit")
        assert buttons_in(view, form.id) == []
        assert has_element?(view, ~s(#pb-form-how #pb-rule-how-typing[aria-pressed="true"]))
        assert has_element?(view, "#pb-form-how", "in a form with a single box it still sends")
        refute has_element?(view, "#pb-form-how", "Enter sends nothing")
        assert_receive {FormCreatedProbe, %{setting: :how, value: :typing, seed: ^seed}}

        view |> element("#pb-rule-how-send") |> render_click()

        [send] = buttons_in(view, form.id)
        refute view |> node_again(form.id) |> PageForms.as_typed?()
        assert editor(view).selection == form.id
        assert has_element?(view, ~s(#pb-form-how #pb-rule-how-send[aria-pressed="true"]))
        assert send.parent_id == form.id
        assert Node.attr_text(send, "phx-disable-with") == "Sending…"
        assert_receive {FormCreatedProbe, %{setting: :how, value: :send, seed: ^seed}}

        undo!(view)
        assert view |> node_again(form.id) |> PageForms.as_typed?()
        undo!(view)
        assert html_of(view) == before
      end
    end

    test "a form whose Send was deleted offers both fixes, and As they type clears the finding",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      form = with_dom_id(view, "news-form")
      [send] = buttons_in(view, form.id)

      render_click(view, "op", %{"kind" => "delete", "node_id" => send.id})
      open_audit(view)

      assert has_element?(view, "#pb-audit-fix-form-no-submit-#{form.id}", "Add a Send button")

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-submit-#{form.id}-typing",
               "Make it work as they type"
             )

      view |> element("#pb-audit-fix-form-no-submit-#{form.id}-typing") |> render_click()

      assert view |> node_again(form.id) |> PageForms.as_typed?()
      refute has_element?(view, "#pb-audit-fix-form-no-submit-#{form.id}")

      refute has_element?(
               view,
               "#pb-audit-fix-form-no-submit-#{with_dom_id(view, "contact-form").id}"
             )

      undo!(view)
      refute view |> node_again(form.id) |> PageForms.as_typed?()

      view |> element("#pb-audit-fix-form-no-submit-#{form.id}") |> render_click()
      assert [_send] = buttons_in(view, form.id)
    end

    test "a working kit form that cannot carry As they type is offered only the Send button",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper chelekom-simple-form)))

      template =
        ~s(<div id="root">) <>
          ~s(<.component component_name="chelekom-simple-form" site="localhost" :let={s} id="lead-form" as={:lead} for={assigns[:lead_form]} phx-change="lead-m4r2q-validate" phx-submit="lead-m4r2q-submit"><div class="card"><div class="grid"><div id="lead-col"><input name={s[:email].name} /></div></div></div></.component>) <>
          ~s(<.component component_name="chelekom-form-wrapper" site="localhost" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div id="news-col"><input name={w[:email].name} /></div></div></div></.component></div>)

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))
      lead = with_dom_id(view, "lead-form")
      news = with_dom_id(view, "news-form")
      open_audit(view)

      assert has_element?(view, "#pb-audit-fix-form-no-submit-#{lead.id}", "Add a Send button")
      refute has_element?(view, "#pb-audit-fix-form-no-submit-#{lead.id}-typing")
      assert has_element?(view, "#pb-audit-fix-form-no-submit-#{news.id}-typing")

      render_click(view, "audit_fix", %{
        "rule" => "form-no-submit",
        "id" => lead.id,
        "fix" => "typing"
      })

      refute view |> node_again(lead.id) |> PageForms.as_typed?()

      inspecting(view, lead)
      refute has_element?(view, "#pb-form-how")
      inspecting(view, news)
      assert has_element?(view, "#pb-form-how")
    end

    test "the Form name and Success message speak plainly", %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      inspecting(view, with_dom_id(view, "news-form"))

      assert has_element?(view, "#pb-rule-control-seed", "What this form is called.")
      assert has_element?(view, ~s(#pb-rule-success[placeholder="Sent. Thank you."]))

      for id <- ~w(#pb-rule-control-seed #pb-rule-control-success #pb-form-how) do
        text = view |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
        refute text =~ ~r/params|assign|event|phx-/, id
      end
    end

    defp phoenix_open(view) do
      view |> element("#pb-section-form-phoenix") |> render_click()
    end

    test "Form · Phoenix starts folded, then shows the names read-only and each option the form forwards",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)

      assert has_element?(view, "#pb-form-phoenix")
      refute has_element?(view, "#pb-form-names")

      phoenix_open(view)

      assert has_element?(
               view,
               ~s(#pb-form-names [data-name="phx-submit"]),
               "contact-k7m2q-submit"
             )

      assert has_element?(view, ~s(#pb-form-names [data-name=":let"]), "f")
      refute has_element?(view, "#pb-form-names input")

      for key <- ~w(novalidate autocomplete auto_recover target) do
        assert has_element?(view, "#pb-form-phoenix #pb-rule-control-#{key}"), key
      end

      assert has_element?(view, ~s(#pb-form-files[data-on="false"]))
      assert has_element?(view, "#pb-form-address")

      view |> element("#pb-rule-autocomplete-off") |> render_click()
      assert Node.attr_text(node_again(view, contact.id), "autocomplete") == "off"

      inspecting(view, field_at(view, "contact-col"))
      assert has_element?(view, ~s(#pb-rule-field_autocomplete[placeholder="Default: off"]))
      inspecting(view, contact)

      view |> element("#pb-rule-autocomplete-on") |> render_click()
      assert Node.attr(node_again(view, contact.id), "autocomplete") == nil

      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      assert has_element?(view, "#pb-form-phoenix #pb-rule-control-auto_recover")

      for key <- ~w(novalidate autocomplete target) do
        refute has_element?(view, "#pb-rule-control-#{key}"), key
      end

      refute has_element?(view, "#pb-form-address")
      refute has_element?(view, "#pb-form-files")

      view |> element("#pb-rule-auto_recover") |> render_click()
      assert Node.attr_text(node_again(view, news.id), "phx-auto-recover") == "ignore"
      view |> element("#pb-rule-auto_recover") |> render_click()
      assert Node.attr(node_again(view, news.id), "phx-auto-recover") == nil
    end

    test "a file field put in a form turns on Can send files, in the same step, wherever it comes from",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      news = with_dom_id(view, "news-form")
      before = html_of(view)

      render_click(view, "drop", %{
        "template" => ~s(<input type="file" name="cv" />),
        "parent_id" => with_dom_id(view, "contact-col").id,
        "index" => "0"
      })

      assert Node.attr(node_again(view, contact.id), "multipart") == {:expr, "true"}

      inspecting(view, contact)
      phoenix_open(view)

      assert has_element?(
               view,
               ~s(#pb-form-files[data-on="true"]),
               "On, because a file field is inside this form."
             )

      undo!(view)
      assert html_of(view) == before

      render_click(view, "drop", %{
        "template" => ~s(<input type="file" name="cv" />),
        "parent_id" => with_dom_id(view, "news-col").id,
        "index" => "0"
      })

      assert Node.attr(node_again(view, news.id), "multipart") == nil

      file =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.attr_text(&1, "type") == "file"))

      inspecting(view, file)

      view |> element("#pb-field-form-form") |> render_change(%{"form" => contact.id})

      assert Node.attr(node_again(view, contact.id), "multipart") == {:expr, "true"}
    end

    test "a form that already held a file field says Off until an address turns it on",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      template =
        String.replace(
          @two_deep_forms,
          ~s(<div id="contact-col">),
          ~s(<div id="contact-col"><input type="file" name="cv" />)
        )

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)
      phoenix_open(view)

      assert has_element?(view, ~s(#pb-form-files[data-on="false"]), "Off.")

      view
      |> element("#pb-form-address-form")
      |> render_change(%{"value" => "https://jobs.example.com/apply"})

      assert Node.attr(node_again(view, contact.id), "multipart") == {:expr, "true"}
      assert has_element?(view, ~s(#pb-form-files[data-on="true"]))
    end

    test "Send to another address writes the four together, a rename carries them, and empty removes them",
         %{conn: conn, site: site} do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_setting")
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      contact = with_dom_id(view, "contact-form")
      inspecting(view, contact)
      phoenix_open(view)

      view |> element("#pb-rule-target-_blank") |> render_click()
      assert Node.attr_text(node_again(view, contact.id), "target") == "_blank"

      view
      |> element("#pb-form-address-form")
      |> render_change(%{"value" => "https://pay.example.com/checkout"})

      sent = node_again(view, contact.id)
      assert Node.attr(sent, "target") == nil
      refute has_element?(view, "#pb-form-phoenix #pb-rule-control-target")
      assert has_element?(view, "#pb-form-address", "opens in this same tab")
      assert PageForms.address(sent) == "https://pay.example.com/checkout"
      assert Node.attr_text(sent, "method") == "post"
      assert Node.attr(sent, "csrf_token") == {:expr, "false"}
      assert Node.attr(sent, "phx-trigger-action") == {:expr, "assigns[:contact_send]"}
      assert Node.attr_text(sent, "phx-submit") == "contact-k7m2q-submit"

      assert_receive {FormCreatedProbe,
                      %{
                        setting: :address,
                        value: "https://pay.example.com/checkout",
                        seed: "contact"
                      }}

      open_audit(view)
      refute has_element?(view, "#pb-audit-fix-form-no-destination-#{contact.id}")

      assert has_element?(
               view,
               "#pb-audit-fix-form-no-destination-#{with_dom_id(view, "news-form").id}"
             )

      inspecting(view, contact)
      view |> element("#pb-rule-form-seed") |> render_change(%{"value" => "Payment"})

      renamed = node_again(view, contact.id)
      assert PageForms.param_name(renamed) == "payment"
      assert Node.attr(renamed, "phx-trigger-action") == {:expr, "assigns[:payment_send]"}
      assert PageForms.address(renamed) == "https://pay.example.com/checkout"

      view
      |> element("#pb-form-address-form")
      |> render_change(%{"value" => "http://pay.example.com"})

      assert flashes(view) =~ "starts with https://"
      assert PageForms.address(node_again(view, contact.id)) == "https://pay.example.com/checkout"

      view |> element("#pb-form-address-form") |> render_change(%{"value" => ""})
      cleared = node_again(view, contact.id)

      for name <- ~w(action method csrf_token phx-trigger-action) do
        assert Node.attr(cleared, name) == nil, name
      end

      assert Node.attr_text(cleared, "phx-submit") == "payment-k7m2q-submit"
    end

    test "Props and Advanced leave a working kit form's names to the Form panel", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      assert has_element?(view, "#pb-attr-#{news.id}-color")

      for name <- ~w(for as id) do
        refute has_element?(view, "#pb-attr-#{news.id}-#{name}"), name
      end

      for name <- ~w(phx-change phx-submit :let) do
        refute has_element?(view, ~s([id="pb-extra-row-#{name}"])), name
      end
    end

    test "on a layout, where there is no Form panel, Props and Advanced still show a form's names",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      layout =
        create_layout!(
          name: "shell",
          site_id: site.id,
          template:
            ~s(<div id="shell"><div class="card"><div class="grid"><div class="col">) <>
              ~s(<.component component_name="chelekom-form-wrapper" site="localhost" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div id="news-col"><input name={w[:email].name} /></div></div></div></.component>) <>
              ~s(</div></div></div>{@inner_content}</div>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      _settled = render_async(view)
      news = with_dom_id(view, "news-form")
      inspecting(view, news)

      refute has_element?(view, "#pb-section-form")

      for name <- ~w(for as id) do
        assert has_element?(view, "#pb-attr-#{news.id}-#{name}"), name
      end

      for name <- ~w(phx-change phx-submit :let) do
        assert has_element?(view, ~s([id="pb-extra-row-#{name}"])), name
      end
    end

    defp field_at(view, col), do: node_again(view, hd(with_dom_id(view, col).children))

    defp selection(view), do: view |> editor() |> Map.fetch!(:selection)

    @plain_fields ~w(debounce throttle field_autocomplete placeholder readonly disabled autofocus)

    test "Field options deep in both forms: Check while typing, and Form settings leads to the form",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for {col, form_id} <- [{"contact-col", "contact-form"}, {"news-col", "news-form"}] do
        input = field_at(view, col)
        inspecting(view, input)

        assert has_element?(
                 view,
                 ~s(#pb-field-debounce button[aria-pressed="true"]),
                 "As they type"
               )

        view |> element("#pb-rule-debounce-blur") |> render_click()
        assert Node.attr_text(node_again(view, input.id), "phx-debounce") == "blur"

        view |> element("#pb-rule-form-debounce") |> render_change(%{"value" => "500"})
        assert Node.attr_text(node_again(view, input.id), "phx-debounce") == "500"
        assert has_element?(view, ~s(#pb-rule-debounce-number[value="500"]))

        view |> element("#pb-rule-readonly") |> render_click()
        assert Node.attr(node_again(view, input.id), "readonly") == :boolean

        view
        |> element("#pb-rule-form-placeholder")
        |> render_change(%{"value" => "you@example.com"})

        assert Node.attr_text(node_again(view, input.id), "placeholder") == "you@example.com"

        view |> element("#pb-rule-note ~ #pb-form-settings-link") |> render_click()

        assert selection(view) == with_dom_id(view, form_id).id
        assert has_element?(view, "#pb-form-how")
      end
    end

    test "the Send button deep in both forms: text while sending, and a type that stops it sending",
         %{conn: conn, site: site} do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))

      for form_id <- ~w(contact-form news-form) do
        form = with_dom_id(view, form_id)
        [send] = buttons_in(view, form.id)
        inspecting(view, send)

        assert has_element?(view, "#pb-send-disable-with #pb-rule-disable_with")
        refute has_element?(view, "#pb-send-disable-with #pb-rule-disable_with[placeholder]")
        assert has_element?(view, "#pb-send-disable-with", "Empty keeps its own words.")

        refute has_element?(view, "#pb-send-type-warning")

        view |> element("#pb-rule-form-disable_with") |> render_change(%{"value" => "Paying…"})
        assert Node.attr_text(node_again(view, send.id), "phx-disable-with") == "Paying…"

        view |> element("#pb-rule-button_type-button") |> render_click()

        assert Node.attr_text(node_again(view, send.id), "type") == "button"
        assert has_element?(view, "#pb-send-type-warning", "does not send the form")
        refute has_element?(view, "#pb-send-disable-with")

        view |> element("#pb-rule-button_type-submit") |> render_click()
        assert Node.attr_text(node_again(view, send.id), "type") == "submit"

        view |> element("#pb-form-settings-link") |> render_click()
        assert selection(view) == form.id
      end
    end

    test "a link and a helper button deep in both forms: no Send options for the link, a plain warning for the helper",
         %{conn: conn, site: site} do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      extra =
        ~s(<.button id="back-link" navigate="/back">Back</.button><button type="button" phx-click="toggle">More</button>)

      template =
        @two_deep_forms
        |> String.replace(~s(<div id="contact-col">), ~s(<div id="contact-col">) <> extra)
        |> String.replace(
          ~s(<div id="news-col">),
          ~s(<div id="news-col">) <> String.replace(extra, "back-link", "news-back")
        )

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))

      for {form_id, link_id} <- [{"contact-form", "back-link"}, {"news-form", "news-back"}] do
        inspecting(view, with_dom_id(view, link_id))

        refute has_element?(view, "#pb-rule-control-button_type"), form_id
        refute has_element?(view, "#pb-send-type-warning"), form_id

        helper =
          view
          |> buttons_in(with_dom_id(view, form_id).id)
          |> Enum.find(&(Node.attr_text(&1, "type") == "button"))

        inspecting(view, helper)

        assert has_element?(view, "#pb-send-type-warning", "does not send the form"), form_id
        refute has_element?(view, "#pb-send-type-warning", "any more"), form_id
      end
    end

    test "a code author gets the three event bindings and the way to Code", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      input = field_at(view, "news-col")
      inspecting(view, input)

      for key <- ~w(on_focus on_blur on_keyup) do
        assert has_element?(view, "#pb-rule-control-#{key}"), key
      end

      assert has_element?(view, "#pb-field-code-link")

      view |> element("#pb-rule-form-on_blur") |> render_change(%{"value" => "email_left"})
      assert Node.attr_text(node_again(view, input.id), "phx-blur") == "email_left"
    end

    test "where this deployment takes no code, a field reads plain words and gets no code rows",
         %{
           conn: conn,
           site: site
         } do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)

      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      input = field_at(view, "contact-col")
      inspecting(view, input)

      for key <- @plain_fields do
        id = (key == "debounce" && "#pb-field-debounce") || "#pb-rule-control-#{key}"

        text =
          view
          |> element(id)
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.text()

        refute text =~ ~r/params|assign|event|handler|phx-/, key
      end

      for key <- ~w(on_focus on_blur on_keyup) do
        refute has_element?(view, "#pb-rule-control-#{key}"), key
      end

      refute has_element?(view, "#pb-field-code-link")

      render_click(view, "set_rule", %{
        "key" => "on_focus",
        "node_id" => input.id,
        "value" => "sneaky"
      })

      assert Node.attr(node_again(view, input.id), "phx-focus") == nil

      [send] = buttons_in(view, with_dom_id(view, "contact-form").id)
      inspecting(view, send)

      for id <- ~w(#pb-rule-control-button_type #pb-send-disable-with) do
        text = view |> element(id) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
        refute text =~ ~r/params|assign|event|phx-/, id
      end
    end

    # A form that does not work yet, deep in a card on a page with a working one.
    @idle_forms ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div class="col"><input name={f[:email].name} /></div></div></div><button type="submit">Send</button></.form>) <>
                  ~s(<div class="card"><div class="grid"><div class="col">) <>
                  ~s(<.component component_name="chelekom-form-wrapper" site="localhost" id="idle-form" for={%{}}><div class="card"><div class="grid"><div id="idle-col"><input name="nick" /></div></div></div><button type="submit">Join</button></.component>) <>
                  ~s(<form id="raw-form" class="stack gap-2"><div class="card"><div class="grid"><div id="raw-col"><input name="q" /></div></div></div></form>) <>
                  ~s(<form id="post-form" action="https://search.example.com"><input name="q" /></form>) <>
                  ~s(<.form for={%{}} id="search-form" action="https://search.example.com" method="get"><div class="card"><div class="grid"><div id="search-col"><input name="q" /></div></div></div></.form>) <>
                  ~s(<.component component_name="chelekom-form-wrapper" site="localhost" id="away-form" for={%{}} action="https://away.example.com"><div class="card"><div class="grid"><div id="away-col"><input name="nick" /></div></div></div></.component>) <>
                  ~s(</div></div></div></div>)

    defp idle_page!(site) do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))
      create_page!(site_id: site.id, template: @idle_forms)
    end

    test "Make it a working form wires a kit form deep in a card, as one undo step", %{
      conn: conn,
      site: site
    } do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      {:ok, view, _html} = open_builder(conn, idle_page!(site))
      before = html_of(view)
      idle = with_dom_id(view, "idle-form")
      inspecting(view, idle)

      assert has_element?(
               view,
               "#pb-form-idle",
               "This is a form, but it does not work yet. Fields in it are not checked or sent."
             )

      refute has_element?(view, "#pb-form-how")

      view |> element("#pb-form-wire") |> render_click()

      wired = node_again(view, idle.id)
      assert PageForms.form?(wired)
      assert PageForms.let_var(wired) == :f
      assert Node.attr_text(field_at(view, "idle-col"), "name") == "f[:nick].name"
      assert_receive {FormCreatedProbe, %{how: :wired, node_id: id}}
      assert id == idle.id
      refute has_element?(view, "#pb-form-idle")
      assert has_element?(view, "#pb-form-how")

      undo!(view)
      assert html_of(view) == before
    end

    test "a plain HTML form becomes a working form, keeping its look and fields; one that posts away stays",
         %{conn: conn, site: site} do
      Process.register(self(), FormCreatedProbe.waiter())
      register_plugin(FormCreatedProbe, "builder:form:after_create")
      {:ok, view, _html} = open_builder(conn, idle_page!(site))
      before = html_of(view)
      inspecting(view, with_dom_id(view, "raw-form"))

      view |> element("#pb-form-wire") |> render_click()

      [replaced] =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.filter(&(&1.tag == ".form" and Node.attr_text(&1, "class") == "stack gap-2"))

      assert PageForms.form?(replaced)
      assert with_dom_id(view, "raw-form").id == replaced.id
      assert PageForms.param_name(replaced) == "raw"
      assert Node.attr_text(field_at(view, "raw-col"), "name") == "f[:q].name"
      assert_receive {FormCreatedProbe, %{how: :wired, node_id: id}}
      assert id == replaced.id

      undo!(view)
      assert html_of(view) == before

      for id <- ~w(post-form search-form away-form) do
        form = with_dom_id(view, id)
        inspecting(view, form)
        assert has_element?(view, "#pb-form-idle"), id
        assert has_element?(view, "#pb-form-idle-why"), id
        assert has_element?(view, "#pb-form-idle-state", "to its own web address"), id
        refute has_element?(view, "#pb-form-idle", "does not work yet"), id
        refute has_element?(view, "#pb-form-wire"), id

        render_click(view, "wire_form", %{"node_id" => form.id})
        assert Node.attr(node_again(view, form.id), "phx-submit") == nil, id
        refute PageForms.form?(node_again(view, form.id)), id
      end
    end

    test "a plain HTML form made a working one keeps its own id, so what points at it still does",
         %{
           conn: conn,
           site: site
         } do
      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      template =
        String.replace(
          @idle_forms,
          ~s(<form id="post-form"),
          ~s(<a href="#signup">Sign up</a><form id="signup"><div class="card"><div class="grid"><div id="signup-col"><input name="email" /></div></div></div></form>) <>
            ~s(<form id="newsletter-signup-form"><div class="card"><div class="grid"><div id="letter-col"><input name="email" /></div></div></div></form><form id="post-form")
        )

      {:ok, view, _html} = open_builder(conn, create_page!(site_id: site.id, template: template))

      for id <- ~w(signup newsletter-signup-form) do
        inspecting(view, with_dom_id(view, id))
        view |> element("#pb-form-wire") |> render_click()

        kept = with_dom_id(view, id)
        assert kept.tag == ".form", id
        assert PageForms.form?(kept), id
      end
    end

    test "a plain form the page's own code answers says so, and keeps the names its fields send",
         %{conn: conn, site: site} do
      handled =
        String.replace(
          @idle_forms,
          ~s(<form id="post-form"),
          ~s(<form id="lead-form" phx-submit="save"><div class="card"><div class="grid"><div id="lead-col"><input type="email" name="email" /></div></div></div><button type="submit">Go</button></form><form id="post-form")
        )

      kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))

      page =
        create_page!(
          site_id: site.id,
          template: handled,
          events: [%{name: "save", code: "{:noreply, socket}"}]
        )

      {:ok, view, _html} = open_builder(conn, page)
      inspecting(view, with_dom_id(view, "lead-form"))

      assert has_element?(
               view,
               ~s(#pb-form-idle-state[data-handled="true"]),
               "Your own code handles this form"
             )

      refute has_element?(view, "#pb-form-idle", "does not work yet")

      view |> element("#pb-form-wire") |> render_click()

      assert Enum.any?(
               view |> editor() |> Map.fetch!(:tree) |> Tree.walk(),
               &(&1.tag == ".form" and PageForms.form?(&1) and
                   Node.attr_text(&1, "phx-submit") == "save")
             )

      assert Node.attr_text(field_at(view, "lead-col"), "name") == "email"

      inspecting(view, with_dom_id(view, "raw-form"))
      assert has_element?(view, ~s(#pb-form-idle-state[data-handled="false"]))
    end

    test "the canvas toolbar's Form reaches the form from anything deep inside it", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      for {col, form_id} <- [{"contact-col", "contact-form"}, {"news-col", "news-form"}] do
        form = with_dom_id(view, form_id)
        [send] = buttons_in(view, form.id)

        for inside <- [field_at(view, col), send, with_dom_id(view, col)] do
          render_click(canvas, "select", %{"id" => inside.id})
          assert has_element?(canvas, "#pb-toolbar-form"), form_id

          canvas |> element("#pb-toolbar-form") |> render_click()
          assert selection(view) == form.id
        end
      end

      render_click(canvas, "select", %{"id" => node_with_tag(view, "h1").id})
      refute has_element?(canvas, "#pb-toolbar-form")
    end

    test "a drop refused on a form is placed after it, and the toast calls it by its people name",
         %{
           conn: conn,
           site: site
         } do
      {:ok, view, _html} = open_builder(conn, deep_forms_page!(site))
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      render_click(canvas, "drop", %{
        "template" => Elements.get("el-form").template,
        "parent_id" => with_dom_id(view, "news-form").id,
        "index" => "0"
      })

      assert_push_event(canvas, "pb:drop-moved", %{message: message})
      assert message =~ "Placed after the News form instead."
      refute message =~ "chelekom"
    end
  end

  describe "hidden from visitors" do
    test "the right-click menu hides an element; the layers chip and the Inspector say so and show it",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute has_element?(canvas, "#pb-eltb-visibility"), "the element toolbar has no second eye"

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => h1.id})

      assert Visibility.hidden?(node_with_tag(view, "h1"))
      assert has_element?(canvas, ~s([data-node-id="#{h1.id}"][data-pb-hidden]))

      view |> element("#pb-layer-hidden-#{h1.id}") |> render_click()
      refute Visibility.hidden?(node_with_tag(view, "h1"))
      refute has_element?(view, "#pb-layer-hidden-#{h1.id}")

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => h1.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      assert has_element?(view, "#pb-insp-hidden")

      view |> element("#pb-insp-show") |> render_click()

      refute Visibility.hidden?(node_with_tag(view, "h1"))
      refute has_element?(view, "#pb-insp-hidden")
      refute has_element?(canvas, "[data-pb-hidden]")
    end

    test "an element inside a hidden one points at it, and is not shown on its own",
         %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section data-pb-hidden><h1>Contact Us</h1></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      assert has_element?(view, "#pb-layer-hidden-#{section.id}")
      refute has_element?(view, "#pb-layer-hidden-#{h1.id}"), "the chip marks the one hidden"

      view |> element("#pb-lefttab-inspector") |> render_click()
      assert has_element?(view, "#pb-insp-hidden")
      refute has_element?(view, "#pb-insp-show")

      render_click(view, "toggle_visibility", %{})
      assert flashes(view) =~ "It is hidden with the element around it."
      assert Visibility.hidden_by(editor(view).tree, h1.id).id == section.id

      view |> element("#pb-insp-select-hider") |> render_click()
      assert editor(view).selection == section.id
      assert has_element?(view, "#pb-insp-show")
    end

    test "the right-click menu, the keyboard and the palette each toggle it as one undoable step",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")

      render_click(view, "shortcut", %{"key" => "visibility"})
      assert flashes(view) =~ "Select an element on the page first."

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => p.id})
      assert Visibility.hidden?(node_with_tag(view, "p"))
      assert %{label: "Hidden from visitors"} = hd(editor(view).past)

      render_click(view, "select", %{"id" => p.id})
      render_click(view, "shortcut", %{"key" => "visibility"})
      refute Visibility.hidden?(node_with_tag(view, "p"))
      assert %{label: "Shown to visitors"} = hd(editor(view).past)

      render_click(view, "shortcut", %{"key" => "command"})
      view |> element("#pb-cmd-toggle_visibility") |> render_click()
      assert Visibility.hidden?(node_with_tag(view, "p"))

      undo!(view)
      refute Visibility.hidden?(node_with_tag(view, "p"))
    end

    test "preview draws nothing of a hidden element, editing draws it dimmed",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "h1").id
      })

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us"
      assert canvas |> element("#pb-canvas-chrome") |> render() =~ "[data-pb-hidden]"

      view |> element("#pb-preview") |> render_click()

      refute render(canvas) =~ "Contact Us"
      assert render(canvas) =~ "Reach out any time."
    end

    test "publishing keeps it in the page, leaves it out of what visitors get, and says so",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "h1").id
      })

      publish!(view)

      assert flashes(view) =~ "Page published. 1 hidden element was left out."

      stored =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert stored.template =~ "<h1 data-pb-hidden>Contact Us</h1>"

      html = LiveViewCompiler.render_template(stored.template, %{})
      refute html =~ "Contact Us"
      assert html =~ "Reach out any time."
    end
  end
end
