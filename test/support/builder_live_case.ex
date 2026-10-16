# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.BuilderLiveCase do
  @moduledoc """
  End-to-end tests for the visual page builder, driven through the real LiveView.

  Everything here is asserted by stable `pb-*` DOM id, which is the house rule and also the thing
  that makes this suite survive a restyle. The React editor had no test of this kind at any level,
  which is how it shipped with a save endpoint that was never routed.

  The tests live in `test/mishka_cms_core_web/live/builder_live/`, one module per topic, so a
  partitioned run spreads them. `use MishkaCmsCore.BuilderLiveCase` gives each of them
  `MishkaCmsCore.ConnCase`, the shared imports, aliases and module attributes, and a setup that
  signs `boss@example.com` in as a `*` admin of a cached `localhost` master site with one page —
  `%{conn: conn, site: site, page: page}`. The helpers below are imported into every one of them.
  """
  use ExUnit.CaseTemplate

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.BuilderBlockPlugin, as: BlockPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderPageStarterPlugin, as: PageStarterPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderFormCreatedProbe, as: FormCreatedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderFormCustomizedProbe, as: FormCustomizedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderFormRenamedProbe, as: FormRenamedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarInvokedProbe, as: ToolbarInvokedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarProbe, as: ToolbarProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @endpoint MishkaCmsCore.TestEndpoint

  @password "Password123!"

  # Two forms, each with its field and Send button in a column of a grid in a card: Phoenix's own
  # `<.form>`, and Chelekom's Form Wrapper wired as a page form.
  @two_deep_forms ~s(<div id="root"><h1>Hi</h1>) <>
                    ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div id="contact-col"><input name={f[:email].name} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>) <>
                    ~s(<.component component_name="chelekom-form-wrapper" site="localhost" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div id="news-col"><input name={w[:email].name} /></div><div class="col"><button type="submit">Join</button></div></div></div></.component></div>)

  using do
    quote do
      use MishkaCmsCore.ConnCase

      import Phoenix.LiveViewTest
      import MishkaCmsCore.Test.Factory
      import MishkaCmsCore.BuilderLiveCase

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

      @template ~s(<section id="hero"><h1>Contact Us</h1><p>Reach out any time.</p></section>)

      @bound_form ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /><input name="loose" /></.form></div>)

      @two_forms ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /></.form><.form :let={g} id="signup-form" as={:signup} for={assigns[:signup_form]} phx-change="signup_validate" phx-submit="signup_submit"><input name={g[:email].name} /></.form></div>)

      @strip ~s(data-role="pb-bptabs")

      @two_deep_forms unquote(@two_deep_forms)

      @deep_events ~w(contact-k7m2q-validate contact-k7m2q-submit news-p3xa6-validate news-p3xa6-submit)

      # The deep forms as a page saved before tags carries them: untagged event names.
      @legacy_deep_forms @two_deep_forms
                         |> String.replace("contact-k7m2q-", "contact_")
                         |> String.replace("news-p3xa6-", "news_")

      # THE ROW USED TO CORRUPT WHAT IT SHOWED. An expression's braces belong to the markup around the
      # value, not to the value, and drawing them inside an editable box put them back into the document
      # the moment the row was touched. `phx-click={{JS…}}` is a one-tuple, which raises
      # `Protocol.UndefinedError` where the page renders; `:if={{assigns[:current_user]}}` is a one-tuple
      # too, and truthy, so an element hidden from signed-out visitors came back for everyone. Nothing
      # downstream takes braces off, so each re-edit added another pair.
      @click_source ~S|JS.toggle_class("is-open", to: ".pb-1")|
      @condition_source "assigns[:current_user]"

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
    end
  end

  @doc false
  def cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  @doc false
  def permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  @doc false
  def create_admin(email, site_id \\ nil, permissions \\ ["*"]) do
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
  @doc false
  def create_user_without_permissions(email) do
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
  @doc false
  def build_conn_for_host(host \\ "localhost") do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  @doc false
  def log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Save moved off the top bar into the ••• menu when the header was matched to the prototype: the
  # editor autosaves, so the bar has a stage control where the prototype has one and nothing else.
  @doc false
  def save!(view), do: more!(view, "#pb-save")

  # Writing the live record is Publish, and Publish is two gestures: the stage is chosen, then the
  # button beside it carries it out.
  @doc false
  def publish!(view) do
    render_click(view, "set_stage", %{"stage" => "published"})
    render_click(view, "apply_stage", %{})
  end

  # THE MODAL OPENS BEFORE ITS EXAMPLES ARE CURATED (`assign_async(:examples, …)` in
  # `show_examples`), so a test that inserts, picks or reads a variant straight after the click is
  # racing that read — and on a busy run loses it: `insert_example` finds no example at its index and
  # quietly inserts nothing. Awaited once, here.
  @doc false
  def show_examples!(view, name) do
    render_click(view, "show_examples", %{"name" => name})
    render_async(view)
  end

  @doc false
  def undo!(view), do: more!(view, "#pb-undo")

  @doc false
  def redo!(view), do: more!(view, "#pb-redo")

  # The ••• button TOGGLES, so opening an already-open menu closes it — two menu actions in a row
  # then fail to find the second item.
  @doc false
  def more!(view, id) do
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
  @doc false
  def colleague(conn) do
    email = "colleague#{System.unique_integer([:positive])}@example.com"
    log_in(conn, create_admin(email))
  end

  @doc false
  def open_builder(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    {:ok, view, render_async(view)}
  end

  # THE STUDIO'S OWN ASYNC STARTS WHEN THE SHEET OPENS, which is after `open_builder/2` has already
  # awaited the editor's. The token list is a Gervaz table and the generated export is built from an
  # assign that lands with it, so a test that reads either of them straight after the click is
  # reading a skeleton — and whether it passes depends on how warm the run is. Three of the tests
  # below passed in a full run of this file and failed on their own.
  @doc false
  def open_studio(conn, page) do
    {:ok, view, _html} = open_builder(conn, page)
    view |> element("#pb-studio") |> render_click()
    _settled = render_async(view)
    view
  end

  # THE ROW AS IT REALLY IS, read back through the same actor the editor writes with. Reading it
  # with `nil` answers `%{}` whatever is in the database — which makes "the rule is gone" pass for
  # the wrong reason, and is how the first version of these two tests fooled itself.
  @doc false
  def stored_element_css(view, page) do
    actor = :sys.get_state(view.pid).socket.assigns.current_user
    ElementCss.all(actor, page.site_id, "page-#{page.id}")
  end

  # Autosave is a no-op while nothing has changed, so there has to be an edit for it to write.
  @doc false
  def autosave!(view) do
    render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "h1").id})
    _written = render_async(view)
    editor(view).draft_id
  end

  # A DRAFT WRITE HELD OPEN, so a test can put an edit between the write starting and its answer and
  # have that order every run rather than on a slow machine. The plugin passes every write through
  # until this process is the one registered to be told about them.
  @doc false
  def pause_draft_writes do
    Process.register(self(), MishkaCmsCore.Test.Plugins.BuilderDraftPausePlugin.waiter())

    register_plugin(
      MishkaCmsCore.Test.Plugins.BuilderDraftPausePlugin,
      "builder:draft:before_save"
    )
  end

  # EVERY DRAFT WRITE REFUSED AT THE GATE, which is the state the tests using this are about: what
  # the editor does with a draft an extension would not let it write.
  @doc false
  def refuse_draft_writes,
    do:
      register_plugin(
        MishkaCmsCore.Test.Plugins.BuilderDraftGatePlugin,
        "builder:draft:before_save"
      )

  # And the announcement on the other side of the write, sent here because it is made in the
  # LiveView's process rather than this one.
  @doc false
  def watch_draft_announcements do
    Process.register(self(), MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe.waiter())

    register_plugin(
      MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe,
      "builder:draft:after_save"
    )
  end

  # A plugin registered for the length of one test, exactly as an extension registers one.
  @doc false
  def register_plugin(module, event) do
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
  @doc false
  def resumable_session(conn, page) do
    {:ok, first, _html} = open_builder(conn, page)
    autosave_id = autosave!(first)
    EditorSession.close(token(first))

    {:ok, view, _html} = open_builder(conn, page)
    {autosave_id, view}
  end

  # The canvas renders a runtime component by resolving the module the compilers WOULD have built for
  # it — a name hashed from the component name plus its site. Putting a module at that hashed name by
  # hand keeps these tests about the resolution itself, without booting the whole compile pipeline.
  @doc false
  def history_rows(page) do
    MishkaCmsCore.Runtime.PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(source_id == ^page.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  # A change on the live page's own branch, written as `actor` the way the editor writes one.
  @doc false
  def record_change(page, actor, label) do
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
  @doc false
  def record_assistant_change(page, actor, label) do
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
  @doc false
  def avatars(view),
    do:
      view
      |> element("#pb-avatars")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pb-avatars > span")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  @doc false
  def history_author(view, row),
    do:
      view
      |> element("#pb-history-author-#{row.id}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  @doc false
  def snapshots do
    MishkaCmsCore.Runtime.PageBuilderSnapshot
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.read!(authorize?: false)
  end

  @doc false
  def token(view), do: :sys.get_state(view.pid).socket.assigns.token

  @doc false
  def example_path(token, name, index),
    do: "/admin/dashboard/runtime/builder-canvas/#{token}/example/#{name}/#{index}"

  @doc false
  def editor_messages(view), do: :sys.get_state(view.pid).socket.assigns.ai_messages

  # An element's own opening tag, for asserting on ITS classes rather than its children's.
  @doc false
  def opening_tag(html), do: html |> String.split(">", parts: 2) |> hd()

  # A palette entry as the panel sees it, for asserting on what the card would draw.
  @doc false
  def entry(view, name) do
    view |> editor() |> Map.fetch!(:components) |> Enum.find(&(&1.name == name))
  end

  @doc false
  def editor(view), do: elem(EditorSession.fetch(token(view)), 1)

  # THE ON-CLICK FORM AND NOTHING ELSE. `render(view)` is the whole editor, where `value="is-open"`
  # appears in the Attributes list too — an assertion against the whole page passes for the wrong
  # reason and keeps passing when the box it is about has gone.
  @doc false
  def inspector_html(view) do
    case view |> render() |> String.split(~s(id="pb-act-form-), parts: 2) do
      [_before, rest] -> rest |> String.split("</form>", parts: 2) |> hd()
      [_none] -> ""
    end
  end

  # A component that declares one required property and one required slot, and one optional property
  # beside them — the smallest shape that can tell the marked apart from the unmarked.
  @doc false
  def needy(site) do
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

  @doc false
  def needful_node(view),
    do:
      view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :component))

  # OPEN, NOT TOGGLED. `default_expanded/1` already opens the roots and the level below them, so a
  # page whose only root is the component under test starts open — and `toggle_expand` would shut it.
  @doc false
  def expand!(view, id) do
    open? = view |> element(~s([data-layer-row="#{id}"])) |> render() =~ ~s(data-open="true")
    unless open?, do: render_click(view, "toggle_expand", %{"id" => id})
    :ok
  end

  # Every row the layers rail offers as a drop target, by the id a drop would resolve to.
  @doc false
  def rail_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter("[data-layer-row]")
    |> LazyHTML.attribute("data-layer-row")
    |> Enum.uniq()
  end

  # Which width the frame is showing. Session state on the LiveView rather than in the document, so
  # it is read the same way the canvas hrefs are.
  @doc false
  def device(view), do: :sys.get_state(view.pid).socket.assigns.device

  @doc false
  def breakpoint(view), do: :sys.get_state(view.pid).socket.assigns.breakpoint

  # The compiled bundles the frame is served. Read off the LiveView rather than out of its HTML,
  # because the `<link>` is rendered by the root layout — see the canvas tests for why it moved.
  @doc false
  def css_hrefs(view), do: :sys.get_state(view.pid).socket.assigns.canvas_css_hrefs

  @doc false
  def newest_history_row(page) do
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
  @doc false
  def filter_history(view, kind) do
    view
    |> element("#pb-history-table_page_builder_events-filter")
    |> render_change(%{"kind" => kind})

    render_async(view)
  end

  # The page's code fragments live on the LiveView rather than in the editing session: they are Page
  # attributes, not part of the tree, and they ride the page's own Save.
  @doc false
  def fragments(view), do: :sys.get_state(view.pid).socket.assigns.fragments

  # The palette stays mounted and hides, so "is the palette showing?" is a class question rather than
  # an existence one — see the `hidden` attr on `Panels.palette/1`.
  @doc false
  def palette_hidden?(view) do
    assert has_element?(view, "#pb-palette"), "the palette stays mounted"
    has_element?(view, ~s(#pb-palette[data-showing="false"]))
  end

  # The signed-in user as the LiveView holds it — what `Drafts` needs to read the same rows the
  # editor does. Read BEFORE an action that navigates away, because the process goes with it.
  @doc false
  def actor(view), do: :sys.get_state(view.pid).socket.assigns.current_user

  # A REFRESH, not a second tab. The editing session lives in ETS and deliberately outlives the
  # LiveView, so reopening while the first one is still mounted models TWO editors on one document —
  # both of them autosaving — rather than one person pressing reload. Stopping the process first is
  # what a closed tab does: `terminate/2` announces the close and leaves the session alone.
  @doc false
  def reopen(view, conn, page) do
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
  @doc false
  def component_versions(site) do
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

  @doc false
  def site_component_names(site) do
    site_id = site.id

    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(page: [limit: 500])
    |> Map.fetch!(:results)
    |> Enum.map(& &1.name)
  end

  @doc false
  def saved_snippets(site, record) do
    MishkaCmsCore.Runtime.PageBuilder.Snippets.list(%{
      site_id: site.id,
      section: :page,
      document_id: record.id,
      actor: create_user_with_permissions!(["*"])
    })
  end

  @doc false
  def editor_html(view) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize()
  end

  @doc false
  def component_node(view, name) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> Tree.walk()
    |> Enum.find(&(Node.component_name(&1) == name))
  end

  @doc false
  def headings(nodes), do: Enum.count(nodes, &(&1.tag == "h1"))

  @doc false
  def node_parent(view, id),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id) |> Map.fetch!(:parent_id)

  # The `{@inner_content}` chip — a layout's one obligation, and the node most of these tests act on.
  @doc false
  def expression_node(view),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :eex))

  @doc false
  def node_with_tag(view, tag) do
    view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.tag == tag))
  end

  @doc false
  def node_count(view), do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

  # WHATEVER IS ON SCREEN, both notices at once: a flash is the only place a refused command speaks
  # to the author, and which of the two it picks is not the point of the assertions below. The tags
  # come off first — Tailwind writes `hover:bg-white` into the class list, which reads exactly like
  # an inspected atom to anything looking for one.
  @doc false
  def flashes(view) do
    ["#flash-info", "#flash-error"]
    |> Enum.filter(&has_element?(view, &1))
    |> Enum.map_join(" ", &(view |> element(&1) |> render() |> String.replace(~r/<[^>]*>/, "")))
    |> String.trim()
  end

  # A flash is set, never unset: nothing on the server clears one, and the hook that pushes
  # `lv:clear-flash` after the fade does not run here — so a stale sentence would answer for the
  # next command and hide a handler that went silent.
  @doc false
  def clear_flashes(view) do
    for key <- ~w(info error), do: render_click(view, "lv:clear-flash", %{"key" => key})
    view
  end

  # AN INSPECTED TERM WHERE A SENTENCE BELONGS: a map, a tuple, or a bare atom reason. Every one of
  # them is an internal the author has no word for, and all three read the same way in a flash.
  @doc false
  def internals?(text), do: text =~ ~r/%\{|\{:|:[a-z_]/

  # How an attribute is HELD, which is what a row that shows it can corrupt: `{:expr, source}` is a
  # binding, `{:string, text}` is words, `:boolean` is a bare attribute.
  @doc false
  def attr_of(view, id, name),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id) |> Node.attr(name)

  # The value a box is offering — what the browser posts straight back when the author clicks into
  # the row and leaves it alone.
  @doc false
  def field_value(view, id) do
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
  @doc false
  def commit_row(view, form_id, value),
    do: view |> element(~s(form[id="#{form_id}"])) |> render_change(%{"value" => value})

  # A value the property will take, for walking the whole vocabulary. An enumerated one must be one
  # of its own; a free-form one is never validated, so any length does.
  @doc false
  def sample_style(prop), do: prop |> Styles.options() |> List.first("7px")

  # The style overrides a node actually carries — what every control in the Layout and Appearance
  # sections is a way of writing, and the only record of them there is.
  @doc false
  def styles_of(view, node_id),
    do:
      view
      |> editor()
      |> Map.fetch!(:tree)
      |> Tree.get(node_id)
      |> then(&Map.get(&1.meta, :styles, %{}))

  @doc false
  def declared_forms(view),
    do: view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() |> PageForms.declared()

  # A comment carries no tag, so it is found by kind instead.
  @doc false
  def node_with_kind(view, kind) do
    view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == kind))
  end

  # One per row in the Studio's token list: every row has an editable value field, and only rows do.
  @doc false
  def token_rows(html), do: length(String.split(html, ~s(id="pb-token-value-))) - 1

  @doc false
  def tagged(view, tag),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.filter(&(&1.tag == tag))

  # THE REAL ROWS, the way an install writes them: the kit's own template and attributes.
  @doc false
  def kit_rows!(site, rows) do
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

  @doc false
  def set_archived!(page_id, archived?) do
    MishkaCmsCore.Repo.query!(
      "UPDATE pages SET archived_at = CASE WHEN $2 THEN now() ELSE NULL END WHERE id = $1",
      [Ecto.UUID.dump!(page_id), archived?]
    )
  end

  @doc false
  def deep_forms_page!(site, events \\ [], extra \\ []) do
    kit_rows!(site, chelekom_rows(~w(chelekom-form-wrapper)))
    create_page!([site_id: site.id, template: @two_deep_forms, events: events] ++ extra)
  end

  @doc false
  def messages(count),
    do: Enum.map(1..count, &%{name: ":tick_#{&1}", code: "{:noreply, socket}"})

  @doc false
  def handlers_tab(view) do
    view |> element("#pb-code") |> render_click()
    render_click(view, "source_tab", %{"tab" => "events"})
  end

  @doc false
  def customize!(view, event, typed \\ %{}) do
    view
    |> form("#pb-code-form", typed)
    |> put_submitter("#pb-form-customize-#{event}")
    |> render_submit()
  end

  @doc false
  def open_audit(view), do: view |> element("#pb-rail-audit") |> render_click()

  @doc false
  def note_fix(view, form),
    do: view |> element("#pb-audit-fix-form-no-destination-#{form.id}") |> render_click()

  @doc false
  def written(names), do: Enum.map(names, &%{name: &1, code: "{:noreply, socket}"})

  @doc false
  def indexed(entries),
    do: entries |> Enum.with_index() |> Map.new(fn {entry, i} -> {to_string(i), entry} end)

  @doc false
  def narrow_conn(site, permissions) do
    admin =
      create_admin("n#{System.unique_integer([:positive])}@example.com", site.id, permissions)

    log_in(build_conn_for_host(), admin)
  end

  # THE FIVE SHAPES A CONTROL COMES IN. A field in a form, the picture row an enumerated layout
  # property gets, the styled-label pills the typographic ones get, a cell in the spacing box, and
  # the shadow editor's own parts. What is pinned is that the property reaches the reader — not
  # which widget it arrived in, which is a design decision and moves.
  @doc false
  def control_for?(html, prop) do
    String.contains?(html, "pb-style-form-base-#{prop}") or
      String.contains?(html, "pb-style-pics-base-#{prop}") or
      String.contains?(html, "pb-style-base-#{prop}-") or
      String.contains?(html, "pb-edge-form-base-#{prop}") or
      (prop == "shadow" and String.contains?(html, "pb-shadow-base-blur"))
  end
end
