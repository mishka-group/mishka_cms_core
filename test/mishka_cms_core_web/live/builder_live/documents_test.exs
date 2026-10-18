# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.DocumentsTest do
  @moduledoc """
  Document settings, the SEO tab, creating a document, drafts and sessions, saving and history.
  """
  use MishkaCmsCore.BuilderLiveCase

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
      register_plugin(__MODULE__.TestKinds, "runtime:page:records")

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

    test "shows the page's share card with Regenerate; a page of records leaves it to them", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, title: "Shared studio", template: @template)
      {:ok, view, _html} = open_builder(conn, page)
      open_seo(view)
      _settled = render_async(view)

      assert has_element?(view, "#pb-seo-share-card")
      assert seo_text(view, "#pb-seo-share-card") =~ "Shared studio"
      assert has_element?(view, "#pb-seo-share-card-field-regenerate")

      records =
        create_page!(
          site_id: site.id,
          path: "/notes/:slug",
          template: @template,
          extra: %{"record" => "test:note"}
        )

      {:ok, view, _html} = open_builder(conn, records)
      open_seo(view)

      refute has_element?(view, "#pb-seo-share-card")
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
      register_plugin(__MODULE__.TestKinds, "runtime:page:records")

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

      assert html =~ "must be present"
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
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

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
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

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
end
